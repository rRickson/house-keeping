import Foundation
import SweepKit

/// A command with a fixed executable and fixed arguments. Nothing a caller
/// supplies can change either.
public struct FixedCommand: Sendable, Hashable {
    /// Absolute path of the executable.
    public let executable: String
    public let arguments: [String]
    /// The command may fail without failing its task.
    public let allowFailure: Bool
    /// The command takes one more argument: a path that passed
    /// `PrivilegedTaskRunner`'s own validation. Only `removeApplication` has one.
    public let takesValidatedPath: Bool

    public init(_ executable: String, _ arguments: [String], allowFailure: Bool = false, takesValidatedPath: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.allowFailure = allowFailure
        self.takesValidatedPath = takesValidatedPath
    }

    public var argv: [String] { [executable] + arguments }
}

/// The complete table of what runs as root, keyed by task. The helper runs
/// these with `Process`; the password-prompt fallback renders them into an
/// AppleScript. There is no other source of privileged commands.
public enum PrivilegedCommandTable {
    /// - Parameter root: prefix of the system folders, `/` outside of tests.
    public static func commands(for task: PrivilegedTask, root: String = "/") -> [FixedCommand] {
        switch task {
        case .flushDNS:
            return [
                FixedCommand(SystemTool.dscacheutil, ["-flushcache"]),
                FixedCommand(SystemTool.killall, ["-HUP", "mDNSResponder"]),
            ]
        case .reindexSpotlight:
            return [FixedCommand(SystemTool.mdutil, ["-E", "/"])]
        case .rebuildFontCaches:
            return [FixedCommand(SystemTool.atsutil, ["databases", "-remove"])]
        case .rebuildLaunchServices:
            return [
                FixedCommand(SystemTool.lsregister, ["-f", "-all", "system,local"]),
                FixedCommand(SystemTool.lsregister, ["-gc"], allowFailure: true),
            ]
        case .clearARPCache:
            return [FixedCommand(SystemTool.arp, ["-a", "-d"])]
        case .cleanSystemCaches:
            // Used by the password-prompt fallback only; the helper walks the
            // folder itself so it can also skip entries that are in use. The
            // fallback cannot tell, so it leaves every Apple entry alone.
            return [
                FixedCommand(
                    SystemTool.find,
                    [systemPath("/Library/Caches", root: root), "-mindepth", "1", "-maxdepth", "1",
                     "!", "-name", "com.apple.*", "!", "-type", "l", "-exec", SystemTool.rm, "-rf", "--", "{}", "+"],
                    allowFailure: true
                ),
            ]
        case .removeApplication:
            return [FixedCommand(SystemTool.rm, ["-rf", "--"], takesValidatedPath: true)]
        }
    }

    /// Whether a task accepts an argument at all.
    public static func takesArgument(_ task: PrivilegedTask) -> Bool {
        task == .removeApplication
    }

    static func systemPath(_ path: String, root: String) -> String {
        let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
        return trimmed + path
    }
}

public enum ShellQuote {
    /// Wraps a word in single quotes for `/bin/sh`. Inside single quotes nothing is special.
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func line(_ command: FixedCommand) -> String {
        command.argv.map(quote).joined(separator: " ")
    }
}

/// Builds the AppleScript the password-prompt fallback hands to `osascript`.
///
/// The script text is made only of table commands. The one variable piece, a
/// validated path, never becomes script or shell text: it is passed to
/// `osascript` as a separate argument and reaches the shell through
/// AppleScript's `quoted form of`.
public enum AdminScript {
    public struct Request: Sendable, Equatable {
        public var task: PrivilegedTask
        /// Paths for the command that takes one; empty for every other task.
        public var validatedPaths: [String]

        public init(_ task: PrivilegedTask, validatedPaths: [String] = []) {
            self.task = task
            self.validatedPaths = validatedPaths
        }
    }

    public struct Script: Sendable, Equatable {
        /// One AppleScript line per element.
        public var lines: [String]
        /// Arguments for the script's `on run argv`.
        public var arguments: [String]

        /// The argument array for `/usr/bin/osascript`.
        public var osascriptArguments: [String] {
            lines.flatMap { ["-e", $0] } + arguments
        }

        public var source: String { lines.joined(separator: "\n") }
    }

    /// An AppleScript string literal.
    public static func stringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    static let userCancelled = -128

    /// One script for all requests, so macOS asks for the password once.
    /// Each task reports its own line: `name<TAB>ok` or `name<TAB>error<TAB>code<TAB>text`.
    public static func build(_ requests: [Request], root: String = "/") -> Script {
        var lines = ["on run argv", "set sweepReport to \"\""]
        var arguments: [String] = []
        for request in requests {
            let name = stringLiteral(request.task.rawValue)
            lines.append("try")
            for command in PrivilegedCommandTable.commands(for: request.task, root: root) {
                let shell = stringLiteral(ShellQuote.line(command))
                var statements: [String] = []
                if command.takesValidatedPath {
                    for path in request.validatedPaths {
                        arguments.append(path)
                        statements.append("do shell script \(stringLiteral(ShellQuote.line(command) + " ")) & quoted form of (item \(arguments.count) of argv) with administrator privileges")
                    }
                } else {
                    statements.append("do shell script \(shell) with administrator privileges")
                }
                for statement in statements {
                    if command.allowFailure {
                        // The command may fail, but declining the password still stops the run.
                        lines.append(contentsOf: [
                            "try", statement, "on error number sweepInner",
                            "if sweepInner is \(userCancelled) then error number \(userCancelled)", "end try",
                        ])
                    } else {
                        lines.append(statement)
                    }
                }
            }
            lines.append(contentsOf: [
                "set sweepReport to sweepReport & \(name) & tab & \"ok\" & linefeed",
                "on error sweepText number sweepCode",
                "set sweepReport to sweepReport & \(name) & tab & \"error\" & tab & (sweepCode as text) & tab & sweepText & linefeed",
                "if sweepCode is \(userCancelled) then return sweepReport",
                "end try",
            ])
        }
        lines.append(contentsOf: ["return sweepReport", "end run"])
        return Script(lines: lines, arguments: arguments)
    }

    /// Reads the report the script printed. A task with no line never ran.
    public static func parse(_ output: String, tasks: [PrivilegedTask]) -> [PrivilegedTask: PrivilegedResult] {
        var results: [PrivilegedTask: PrivilegedResult] = [:]
        var last: PrivilegedTask?
        var cancelled = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 2, let task = PrivilegedTask(rawValue: fields[0]), tasks.contains(task), results[task] == nil {
                if fields[1] == "ok" {
                    results[task] = PrivilegedResult(succeeded: true)
                    last = nil
                    continue
                }
                if fields[1] == "error" {
                    let code = fields.count > 2 ? Int(fields[2]) : nil
                    let text = fields.count > 3 ? fields[3] : ""
                    if code == userCancelled { cancelled = true }
                    results[task] = PrivilegedResult(succeeded: false, message: code == userCancelled ? "Password prompt was cancelled" : tidy(text))
                    last = task
                    continue
                }
            }
            // A failed command's output can span lines; keep the first one only.
            if let last, results[last]?.message.isEmpty == true { results[last]?.message = tidy(String(line)) }
        }
        for task in tasks where results[task] == nil {
            results[task] = PrivilegedResult(succeeded: false, message: cancelled ? "Password prompt was cancelled" : "Did not run")
        }
        return results
    }

    private static func tidy(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}
