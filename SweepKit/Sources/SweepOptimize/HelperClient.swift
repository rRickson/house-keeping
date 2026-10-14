import Foundation
import SweepKit

/// What came back from the helper.
public enum HelperReply: Sendable, Equatable {
    /// The helper ran (or refused) the task.
    case result(PrivilegedResult)
    /// The helper could not be reached at all.
    case unreachable(String)
}

/// The connection to the helper. Abstracted so tests never open a Mach port.
public protocol HelperTransport: Sendable {
    func run(taskName: String, argument: String?, timeout: TimeInterval) async -> HelperReply
    /// The helper's protocol version, or nil when it does not answer.
    func protocolVersion(timeout: TimeInterval) async -> String?
}

/// A privileged runner that can do several tasks under one authorisation.
/// With the password prompt that means one prompt for the whole run.
public protocol BatchPrivilegedRunning: PrivilegedRunning {
    /// Runs tasks that take no argument, in order.
    func run(batch tasks: [PrivilegedTask]) async -> [PrivilegedTask: PrivilegedResult]
}

/// Talks to the root helper over `NSXPCConnection` to its Mach service.
public struct XPCHelperTransport: HelperTransport {
    private let serviceName: String
    private let helperRequirement: String?

    /// - Parameter helperRequirement: a code-signing requirement the helper
    ///   must meet; by default, the helper identifier signed by the app's own team.
    public init(serviceName: String = HelperConstants.machServiceName, helperRequirement: String? = XPCHelperTransport.requirementFromOwnSignature()) {
        self.serviceName = serviceName
        self.helperRequirement = helperRequirement
    }

    public static func requirementFromOwnSignature() -> String? {
        guard let team = CodeRequirement.ownTeamIdentifier() else { return nil }
        return CodeRequirement.text(identifier: HelperConstants.helperIdentifier, teamIdentifier: team)
    }

    public func run(taskName: String, argument: String?, timeout: TimeInterval) async -> HelperReply {
        await call(timeout: timeout, failure: { HelperReply.unreachable($0) }) { helper, finish in
            helper.runTask(taskName, argument: argument) { succeeded, message, bytes in
                finish(.result(PrivilegedResult(succeeded: succeeded, message: message, bytesFreed: bytes)))
            }
        }
    }

    public func protocolVersion(timeout: TimeInterval) async -> String? {
        await call(timeout: timeout, failure: { _ in String?.none }) { helper, finish in
            helper.protocolVersion { finish($0) }
        }
    }

    private func call<T: Sendable>(
        timeout: TimeInterval,
        failure: @escaping @Sendable (String) -> T,
        _ body: (any HelperXPCProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        if let helperRequirement { connection.setCodeSigningRequirement(helperRequirement) }
        connection.resume()
        let pending = PendingReply<T>(connection: connection)
        return await withCheckedContinuation { continuation in
            pending.begin(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                pending.finish(failure(error.localizedDescription))
            }
            guard let helper = proxy as? any HelperXPCProtocol else {
                pending.finish(failure("The helper does not speak Sweep's protocol"))
                return
            }
            body(helper) { pending.finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                pending.finish(failure("The helper did not answer in time"))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of reply, error or timeout comes first.
private final class PendingReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func begin(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: T) {
        lock.lock()
        let waiting = continuation
        let open = connection
        continuation = nil
        connection = nil
        lock.unlock()
        guard let waiting else { return }
        waiting.resume(returning: value)
        open?.invalidate()
    }
}

/// Runs admin tasks for the app.
///
/// 1. When the helper daemon is registered and answers, the task NAME goes to
///    it over XPC.
/// 2. Otherwise `osascript` runs a script built only from
///    `PrivilegedCommandTable`, and macOS asks for the password.
/// 3. Against a fixture home nothing runs and the answer is "unavailable".
public final class HelperClient: BatchPrivilegedRunning {
    public let context: SweepContext
    public let registration: any HelperRegistering
    private let transport: any HelperTransport
    private let root: String
    private let sizer = Sizer()
    private let answered = Locked<Probe?>(nil)
    /// The helper gets this long for one task.
    private let helperTimeout: TimeInterval
    /// The password prompt waits for a person, so it gets much longer than a command.
    private let promptTimeout: TimeInterval

    private struct Probe: Sendable {
        var date: Date
        var answers: Bool
    }

    /// - Parameter root: prefix of the system folders; `/` outside of tests.
    public init(
        context: SweepContext,
        registration: (any HelperRegistering)? = nil,
        transport: any HelperTransport = XPCHelperTransport(),
        root: URL = URL(fileURLWithPath: "/"),
        helperTimeout: TimeInterval = 600,
        promptTimeout: TimeInterval = 900
    ) {
        self.context = context
        self.registration = registration ?? (context.isFixture ? NoHelperRegistration() : HelperRegistration())
        self.transport = transport
        self.root = PrivilegedTaskRunner.normalizedRoot(root)
        self.helperTimeout = helperTimeout
        self.promptTimeout = promptTimeout
    }

    // MARK: PrivilegedRunning

    public var availability: PrivilegedAvailability {
        get async {
            if context.isFixture { return .unavailable }
            if await helperAnswers() { return .helper }
            return context.runner.locate(SystemTool.osascript) != nil ? .passwordPrompt : .unavailable
        }
    }

    public func run(_ task: PrivilegedTask, argument: String?) async -> PrivilegedResult {
        let argument = argument.flatMap { $0.isEmpty ? nil : $0 }
        if let refusal = precheck(task, argument: argument) { return refusal }
        if await helperAnswers() {
            switch await transport.run(taskName: task.rawValue, argument: argument, timeout: helperTimeout) {
            case .result(let result): return result
            case .unreachable: answered.set(Probe(date: Date(), answers: false))
            }
        }
        return await runWithPassword([(task, argument)])[task] ?? Self.unavailable
    }

    public func run(batch tasks: [PrivilegedTask]) async -> [PrivilegedTask: PrivilegedResult] {
        var results: [PrivilegedTask: PrivilegedResult] = [:]
        var pending: [PrivilegedTask] = []
        for task in tasks where results[task] == nil && !pending.contains(task) {
            if let refusal = precheck(task, argument: nil) {
                results[task] = refusal
            } else if PrivilegedCommandTable.takesArgument(task) {
                results[task] = PrivilegedResult(succeeded: false, message: "This task needs an argument")
            } else {
                pending.append(task)
            }
        }
        guard !pending.isEmpty else { return results }

        if await helperAnswers() {
            var unreachable = false
            var remaining: [PrivilegedTask] = []
            for task in pending {
                if unreachable {
                    remaining.append(task)
                    continue
                }
                switch await transport.run(taskName: task.rawValue, argument: nil, timeout: helperTimeout) {
                case .result(let result): results[task] = result
                case .unreachable:
                    unreachable = true
                    answered.set(Probe(date: Date(), answers: false))
                    remaining.append(task)
                }
            }
            pending = remaining
        }
        if !pending.isEmpty {
            results.merge(await runWithPassword(pending.map { ($0, nil) })) { _, new in new }
        }
        return results
    }

    // MARK: Helper

    /// True when the helper is registered, approved and speaks this protocol version.
    private func helperAnswers() async -> Bool {
        guard !context.isFixture, registration.status() == .enabled else { return false }
        if let probe = answered.get(), Date().timeIntervalSince(probe.date) < 30 { return probe.answers }
        let version = await transport.protocolVersion(timeout: 3)
        let answers = version == HelperConstants.protocolVersion
        answered.set(Probe(date: Date(), answers: answers))
        return answers
    }

    /// Forgets what is known about the helper, after it was registered or removed.
    public func resetHelperProbe() {
        answered.set(nil)
    }

    // MARK: Registration (for Settings)

    public var helperStatus: HelperStatus { registration.status() }

    /// Registers the helper daemon with macOS, which then asks the user to
    /// approve it in System Settings → General → Login Items.
    public func registerHelper() throws {
        defer { resetHelperProbe() }
        try registration.register()
    }

    public func unregisterHelper() async throws {
        defer { resetHelperProbe() }
        try await registration.unregister()
    }

    // MARK: Checks shared by both routes

    private static let unavailable = PrivilegedResult(succeeded: false, message: "Admin tasks are not available")

    private func precheck(_ task: PrivilegedTask, argument: String?) -> PrivilegedResult? {
        if context.isFixture { return Self.unavailable }
        if PrivilegedCommandTable.takesArgument(task) {
            guard let argument, BundleIdentifier(argument) != nil else {
                return PrivilegedResult(succeeded: false, message: "Not a valid bundle identifier")
            }
        } else if argument != nil {
            return PrivilegedResult(succeeded: false, message: "This task takes no argument")
        }
        return nil
    }

    // MARK: Password prompt

    private func runWithPassword(_ items: [(task: PrivilegedTask, argument: String?)]) async -> [PrivilegedTask: PrivilegedResult] {
        guard !context.isFixture else { return Dictionary(uniqueKeysWithValues: items.map { ($0.task, Self.unavailable) }) }
        var results: [PrivilegedTask: PrivilegedResult] = [:]
        var requests: [AdminScript.Request] = []
        /// Paths whose size is compared before and after, per task.
        var measured: [PrivilegedTask: [String]] = [:]
        var applicationPath: String?

        for item in items where results[item.task] == nil && !requests.contains(where: { $0.task == item.task }) {
            switch item.task {
            case .removeApplication:
                // The same lookup the helper does: the caller's text is only ever an identifier.
                guard let argument = item.argument, let identifier = BundleIdentifier(argument) else {
                    results[item.task] = PrivilegedResult(succeeded: false, message: "Not a valid bundle identifier")
                    continue
                }
                switch PrivilegedTaskRunner(root: URL(fileURLWithPath: root.isEmpty ? "/" : root)).removalPlan(for: identifier) {
                case .failure(let refusal):
                    results[item.task] = PrivilegedResult(succeeded: false, message: refusal.reason)
                case .success(let plan):
                    guard plan.paths.allSatisfy(isExpectedSystemPath) else {
                        results[item.task] = PrivilegedResult(succeeded: false, message: "Refused an unexpected path")
                        continue
                    }
                    requests.append(AdminScript.Request(item.task, validatedPaths: plan.paths))
                    measured[item.task] = plan.paths
                    applicationPath = plan.application.path
                }
            case .cleanSystemCaches:
                requests.append(AdminScript.Request(item.task))
                measured[item.task] = [root + "/Library/Caches"]
            case .flushDNS, .reindexSpotlight, .rebuildFontCaches, .rebuildLaunchServices, .clearARPCache:
                requests.append(AdminScript.Request(item.task))
            }
        }
        guard !requests.isEmpty else { return results }

        var before: [PrivilegedTask: Int64] = [:]
        for (task, paths) in measured { before[task] = await size(of: paths) }

        let script = AdminScript.build(requests, root: root.isEmpty ? "/" : root)
        let outcome = await context.runner.run(SystemTool.osascript, script.osascriptArguments, timeout: promptTimeout)
        let tasks = requests.map(\.task)
        var parsed: [PrivilegedTask: PrivilegedResult]
        if outcome.launched, !outcome.timedOut, !(outcome.stdout.isEmpty && outcome.exitCode != 0) {
            parsed = AdminScript.parse(outcome.stdout, tasks: tasks)
        } else {
            let reason = outcome.timedOut ? "The password prompt timed out" : outcome.failureReason
            parsed = Dictionary(uniqueKeysWithValues: tasks.map { ($0, PrivilegedResult(succeeded: false, message: reason)) })
        }

        for (task, paths) in measured {
            guard var result = parsed[task] else { continue }
            let after = await size(of: paths)
            result.bytesFreed = max((before[task] ?? 0) - after, 0)
            if task == .removeApplication, let applicationPath, result.succeeded, Fingerprint(path: applicationPath) != nil {
                result = PrivilegedResult(succeeded: false, message: "The app could not be removed completely", bytesFreed: result.bytesFreed)
            }
            parsed[task] = result
        }
        return results.merging(parsed) { _, new in new }
    }

    /// A plan path must sit directly where the runner looks, nowhere else.
    private func isExpectedSystemPath(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains(".."), !path.contains("\0") else { return false }
        let folders = ["/Applications/", "/Library/LaunchDaemons/", "/Library/LaunchAgents/", "/Library/PrivilegedHelperTools/"]
        return folders.contains { path.hasPrefix(root + $0) && path.count > (root + $0).count }
    }

    private func size(of paths: [String]) async -> Int64 {
        let existing = paths.filter { Fingerprint(path: $0) != nil }.map { URL(fileURLWithPath: $0) }
        guard !existing.isEmpty else { return 0 }
        return (try? await sizer.sizeAsync(of: existing))?.bytes ?? 0
    }
}
