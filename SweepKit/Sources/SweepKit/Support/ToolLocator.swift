import Foundation

/// Finds developer tools on disk. A GUI app starts with a bare PATH, so the
/// locator merges the process PATH, the login shell's PATH and the usual
/// install locations of version managers.
public final class ToolLocator: @unchecked Sendable {
    private let home: URL
    private let environment: [String: String]
    private let queryLoginShell: Bool
    private let lock = NSLock()
    private var directories: [String]?
    private var cache: [String: URL?] = [:]

    public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment, queryLoginShell: Bool = true) {
        self.home = home
        self.environment = environment
        self.queryLoginShell = queryLoginShell
    }

    /// The PATH handed to every tool Sweep runs.
    public var searchPath: String { searchDirectories().joined(separator: ":") }

    public func locate(_ tool: String) -> URL? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil
        }
        lock.lock()
        if let cached = cache[tool] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var found: URL?
        for directory in searchDirectories() {
            let candidate = directory + "/" + tool
            // Without developer tools, these are stubs that open an install dialog.
            if directory == "/usr/bin", Self.developerShims.contains(tool), !Self.hasDeveloperTools { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                found = URL(fileURLWithPath: candidate)
                break
            }
        }
        lock.lock()
        cache[tool] = .some(found)
        lock.unlock()
        return found
    }

    private static let developerShims: Set<String> = ["git", "python3", "pip3", "xcrun", "xcodebuild", "swift", "make", "clang", "gcc"]

    private static let hasDeveloperTools: Bool = {
        FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin")
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) != nil
    }()

    /// Forgets cached lookups, so a tool installed while Sweep is open is found on the next scan.
    public func reset() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func searchDirectories() -> [String] {
        lock.lock()
        if let directories {
            lock.unlock()
            return directories
        }
        lock.unlock()

        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, path.hasPrefix("/"), seen.insert(path).inserted else { return }
            ordered.append(path)
        }
        (environment["PATH"] ?? "").split(separator: ":").forEach { add(String($0)) }
        if queryLoginShell {
            loginShellPath().split(separator: ":").forEach { add(String($0)) }
        }
        wellKnownDirectories().forEach(add)

        lock.lock()
        directories = ordered
        lock.unlock()
        return ordered
    }

    private func wellKnownDirectories() -> [String] {
        let h = home.path
        var list = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(h)/.local/bin", "\(h)/.cargo/bin", "\(h)/.bun/bin", "\(h)/.deno/bin",
            "\(h)/.pyenv/shims", "\(h)/.pyenv/bin", "\(h)/.rbenv/shims", "\(h)/.asdf/shims",
            "\(h)/.local/share/mise/shims", "\(h)/.volta/bin", "\(h)/Library/pnpm", "\(h)/.local/share/pnpm",
            "\(h)/.yarn/bin", "\(h)/go/bin", "/usr/local/go/bin", "\(h)/.docker/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "\(h)/miniconda3/bin", "\(h)/anaconda3/bin", "\(h)/miniforge3/bin", "/opt/homebrew/Caskroom/miniconda/base/bin",
            "\(h)/Library/Application Support/pypoetry/venv/bin", "\(h)/.composer/vendor/bin",
        ]
        // nvm keeps one bin folder per Node version; prefer the newest.
        let nvm = "\(h)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            list.append(contentsOf: sorted.map { "\(nvm)/\($0)/bin" })
        }
        return list
    }

    private func loginShellPath() -> String {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return "" }
        let begin = "__SWEEP_PATH_BEGIN__"
        let end = "__SWEEP_PATH_END__"
        let job = ProcessJob(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-l", "-i", "-c", "printf '%s%s%s' '\(begin)' \"$PATH\" '\(end)'"],
            environment: environment,
            timeout: 5
        )
        let output = job.runBlocking().stdout
        guard let start = output.range(of: begin), let stop = output.range(of: end, range: start.upperBound..<output.endIndex) else {
            return ""
        }
        return String(output[start.upperBound..<stop.lowerBound])
    }
}
