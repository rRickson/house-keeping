import Darwin
import Foundation
import SweepKit

/// Which installed apps Homebrew put there.
struct CaskIndex: Sendable {
    /// Real app path → cask token, from the links Homebrew leaves in its Caskroom.
    var byPath: [String: String] = [:]
    /// Tokens `brew list --cask` reports.
    var tokens: Set<String> = []

    func token(forAppAt path: String) -> String? {
        if let token = byPath[path] { return token }
        // Casks that install from a package leave no link; fall back to the name.
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let guess = Self.normalize(name)
        return tokens.contains(guess) ? guess : nil
    }

    /// "Visual Studio Code" → "visual-studio-code", the way cask tokens are written.
    static func normalize(_ name: String) -> String {
        var result = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Read-only questions for Homebrew. The only command that changes anything,
/// `brew uninstall --zap`, is run by `AppUninstaller`.
struct HomebrewCasks: Sendable {
    let engine: SweepEngine
    let environment: UninstallEnvironment

    private var context: SweepContext { engine.context }

    /// Builds the index. Empty when Homebrew is not installed, because without
    /// `brew` there is no way to uninstall a cask properly.
    func index() async -> CaskIndex {
        guard context.runner.locate("brew") != nil else { return CaskIndex() }
        let listed = await engine.run(["brew", "list", "--cask", "-1"], timeout: 30, reuseWithin: 30)
        guard listed.succeeded else { return CaskIndex() }
        var index = CaskIndex()
        index.tokens = Set(listed.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let manager = FileManager.default
        for caskroom in environment.caskrooms {
            for token in (try? manager.contentsOfDirectory(atPath: caskroom)) ?? [] where index.tokens.contains(token) {
                let tokenFolder = caskroom + "/" + token
                for version in (try? manager.contentsOfDirectory(atPath: tokenFolder)) ?? [] where !version.hasPrefix(".") {
                    let versionFolder = tokenFolder + "/" + version
                    for entry in (try? manager.contentsOfDirectory(atPath: versionFolder)) ?? [] where entry.hasSuffix(".app") {
                        // Homebrew moves the app out and leaves a link to where it went.
                        if let real = SafetyGuard.realpath(versionFolder + "/" + entry) {
                            index.byPath[real] = token
                        }
                    }
                }
            }
        }
        return index
    }

    /// Existing paths the cask's zap stanza names, so the preview shows what Homebrew will take.
    func zapPaths(token: String) async -> [String] {
        let info = await engine.run(["brew", "info", "--cask", "--json=v2", token], timeout: 30, reuseWithin: 120)
        guard info.succeeded, let data = info.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let cask = casks.first(where: { ($0["token"] as? String) == token }) ?? casks.first,
              let artifacts = cask["artifacts"] as? [[String: Any]] else { return [] }

        var patterns: [String] = []
        for artifact in artifacts {
            guard let zap = artifact["zap"] else { continue }
            let stanzas = (zap as? [[String: Any]]) ?? (zap as? [String: Any]).map { [$0] } ?? []
            for stanza in stanzas {
                for key in ["trash", "delete"] {
                    if let one = stanza[key] as? String { patterns.append(one) }
                    if let many = stanza[key] as? [String] { patterns.append(contentsOf: many) }
                }
            }
        }

        var seen = Set<String>()
        // The real home, so the paths compare equal to what the guard resolves.
        let home = engine.safety.home
        return patterns.flatMap { Self.expand($0, home: home) }.filter { seen.insert($0).inserted }
    }

    /// Expands `~` and a wildcard in the last path component. Returns existing paths only.
    static func expand(_ pattern: String, home: String) -> [String] {
        var path = pattern
        if path == "~" { return [] }
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard let cleaned = PathText.clean(path) else { return [] }
        path = cleaned

        let wildcards = CharacterSet(charactersIn: "*?[")
        let directory = (path as NSString).deletingLastPathComponent
        let last = (path as NSString).lastPathComponent
        guard directory.rangeOfCharacter(from: wildcards) == nil else { return [] }
        if last.rangeOfCharacter(from: wildcards) == nil {
            return Fingerprint(path: path) != nil ? [path] : []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().filter { fnmatch(last, $0, 0) == 0 }.map { directory + "/" + $0 }
    }
}
