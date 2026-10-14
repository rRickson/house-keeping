import Foundation

/// The result of running an external tool.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// False when the tool could not be found or failed to launch.
    public var launched: Bool

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, launched: Bool = true) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launched = launched
    }

    public var succeeded: Bool { launched && !timedOut && exitCode == 0 }

    public static let notFound = CommandResult(exitCode: 127, stderr: "tool not found", launched: false)

    /// A one-line reason suitable for a failed row.
    public var failureReason: String {
        if !launched { return "tool not found" }
        if timedOut { return "command timed out" }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.isEmpty ? "command failed (exit \(exitCode))" : "command failed: \(line)"
    }
}

/// Runs external tools. The engine never builds shell strings: a command is
/// always an executable name plus an argument array.
public protocol CommandRunning: Sendable {
    /// The absolute location of a tool, or nil when it is not installed.
    func locate(_ tool: String) -> URL?
    func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult
}

extension CommandRunning {
    public func run(_ command: [String], timeout: TimeInterval) async -> CommandResult {
        guard let tool = command.first else { return .notFound }
        return await run(tool, Array(command.dropFirst()), timeout: timeout)
    }
}

/// A runner that knows no tools. Used when House Keeping runs against a fixture home,
/// so a real tool can never point the engine at a real cache.
public struct NullCommandRunner: CommandRunning {
    public init() {}
    public func locate(_ tool: String) -> URL? { nil }
    public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult { .notFound }
}

/// Runs real processes with a timeout.
public final class SystemCommandRunner: CommandRunning {
    private let locator: ToolLocator
    private let baseEnvironment: [String: String]

    public init(locator: ToolLocator, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.locator = locator
        self.baseEnvironment = environment
    }

    public func locate(_ tool: String) -> URL? { locator.locate(tool) }

    public func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        guard let url = locator.locate(tool) else { return .notFound }
        var environment = baseEnvironment
        environment["PATH"] = locator.searchPath
        // Tools must never wait for input or open a pager.
        environment["CI"] = environment["CI"] ?? "1"
        environment["NO_COLOR"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        let job = ProcessJob(executable: url, arguments: arguments, environment: environment, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: job.runBlocking())
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// One process launch. All state is guarded by `lock`.
final class ProcessJob: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var timedOut = false
    private var cancelled = false
    private let timeout: TimeInterval

    init(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop()
    }

    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func runBlocking() -> CommandResult {
        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { return CommandResult(exitCode: 130, stderr: "cancelled", timedOut: false, launched: false) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 126, stderr: error.localizedDescription, launched: false)
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            self.stop()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        // A grandchild can keep the pipe open after the tool exits; do not wait for it forever.
        _ = group.wait(timeout: .now() + 3)

        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: didTimeOut,
            launched: true
        )
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
