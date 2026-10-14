import Darwin
import Foundation

public struct Resolution: Sendable {
    /// Real paths that exist and passed the guard.
    public var roots: [String] = []
    public var source: LocateSource = .none
    /// Locations a rule pointed at that the guard refused, with the reason.
    public var refused: [(path: String, reason: String)] = []
}

/// Finds where a cache really lives: ask the tool first, then environment
/// variables, then the default path.
public struct Resolver: Sendable {
    public let context: SweepContext
    public let safety: SafetyGuard
    /// How long a tool gets to answer "where is your cache".
    public var locateTimeout: TimeInterval = 15

    public init(context: SweepContext, safety: SafetyGuard) {
        self.context = context
        self.safety = safety
    }

    public func resolve(_ item: CatalogItem, scope: SafetyGuard.Scope = .cache) async -> Resolution {
        var resolution = Resolution()
        for step in item.locate {
            let (candidates, source) = await candidates(for: step)
            let existing = candidates.filter { FileManager.default.fileExists(atPath: $0) && isReachable($0) }
            guard !existing.isEmpty else { continue }
            for path in existing {
                let verdict = safety.evaluateRoot(path, scope: scope)
                if verdict.allowed {
                    if !resolution.roots.contains(verdict.resolved) { resolution.roots.append(verdict.resolved) }
                } else {
                    resolution.refused.append((path, verdict.reason ?? "refused"))
                }
            }
            resolution.source = source
            // A step that found something ends the search, even if the guard
            // refused it: falling through would hide the refusal.
            break
        }
        for path in (item.alsoPaths ?? []).flatMap({ Glob.expand(context.expand($0)) })
        where FileManager.default.fileExists(atPath: path) && isReachable(path) {
            let verdict = safety.evaluateRoot(path, scope: scope)
            if verdict.allowed {
                if !resolution.roots.contains(verdict.resolved) { resolution.roots.append(verdict.resolved) }
                if resolution.source == .none { resolution.source = .defaultPath }
            } else {
                resolution.refused.append((path, verdict.reason ?? "refused"))
            }
        }
        return resolution
    }

    /// With a fixture home, a rule may only point inside it. Rules that name
    /// absolute locations such as `/private/tmp` must never reach the real disk
    /// from a test or a fixture run.
    private func isReachable(_ path: String) -> Bool {
        guard context.isFixture else { return true }
        let real = SafetyGuard.realpath(path) ?? path
        return SafetyGuard.isSame(real, orInside: safety.home)
    }

    private func candidates(for step: LocateStep) async -> ([String], LocateSource) {
        if let command = step.command, !command.isEmpty {
            guard context.runner.locate(command[0]) != nil else { return ([], .none) }
            let result = await context.runner.run(command, timeout: locateTimeout)
            guard result.succeeded else { return ([], .none) }
            let bases = Self.parse(result.stdout, jsonKey: step.jsonKey)
            return (applyAppend(bases, step.append), .tool(command))
        }
        if let name = step.env {
            guard let value = context.environment[name], !value.isEmpty else { return ([], .none) }
            let base = context.expand(value)
            guard base.hasPrefix("/") else { return ([], .none) }
            return (applyAppend([base], step.append), .environment(name))
        }
        if let paths = step.paths {
            let expanded = paths.flatMap { Glob.expand(context.expand($0)) }
            return (applyAppend(expanded, step.append), .defaultPath)
        }
        return ([], .none)
    }

    private func applyAppend(_ bases: [String], _ suffixes: [String]?) -> [String] {
        guard let suffixes, !suffixes.isEmpty else { return bases }
        return bases.flatMap { base in suffixes.map { (base as NSString).appendingPathComponent($0) } }
    }

    /// Pulls absolute paths out of a tool's answer: a JSON key, or the last line.
    static func parse(_ output: String, jsonKey: String?) -> [String] {
        let cleaned = stripANSI(output)
        if let jsonKey {
            guard let data = cleaned.data(using: .utf8),
                  var value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
            for key in jsonKey.split(separator: ".") {
                guard let dictionary = value as? [String: Any], let next = dictionary[String(key)] else { return [] }
                value = next
            }
            if let string = value as? String { return isUsable(string) ? [string] : [] }
            if let array = value as? [String] { return array.filter(isUsable) }
            return []
        }
        let lines = cleaned.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }), isUsable(last) else { return [] }
        return [last]
    }

    private static func isUsable(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

public enum Glob {
    /// Expands `*`, `?` and `{a,b}`. A pattern without wildcards is returned as is.
    public static func expand(_ pattern: String) -> [String] {
        guard pattern.contains(where: { "*?{".contains($0) }) else { return [pattern] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, GLOB_BRACE | GLOB_NOSORT, nil, &result) == 0, let paths = result.gl_pathv else { return [] }
        var matches: [String] = []
        for index in 0..<Int(result.gl_pathc) {
            if let pointer = paths[index] { matches.append(String(cString: pointer)) }
        }
        return matches.sorted()
    }

    /// Shell-style match of a single file name.
    public static func matches(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
