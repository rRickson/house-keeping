import Foundation
import Testing
@testable import SweepKit
import SweepTestSupport

@Suite struct ProjectTests {
    private func scanner(_ fixture: FixtureHome, runner: any CommandRunning = GitOnlyRunner(), processes: [String] = []) -> ProjectScanner {
        var settings = SweepSettings()
        settings.projectRoots = ["~/code"]
        return ProjectScanner(engine: fixture.engine(items: [], runner: runner, processes: processes, settings: settings))
    }

    @Test func findsArtifactsOnlyNextToTheirMarker() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/web/package.json")
        try fixture.write("code/web/node_modules/left-pad/index.js", bytes: 30_000)
        try fixture.write("code/web/node_modules/nested/node_modules/x.js")
        try fixture.write("code/web/.next/cache/blob", bytes: 10_000)
        try fixture.write("code/web/src/index.js")
        // No marker: these are just folders.
        try fixture.write("code/notes/node_modules/readme.txt")
        try fixture.write("code/notes/target/keep.txt")
        try fixture.write("code/notes/env/settings.txt")
        // Python.
        try fixture.write("code/api/pyproject.toml")
        try fixture.write("code/api/.venv/pyvenv.cfg")
        try fixture.write("code/api/.venv/lib/site.py", bytes: 20_000)
        try fixture.write("code/api/app/main.py")
        try fixture.write("code/api/app/__pycache__/main.cpython-312.pyc")
        // Rust.
        try fixture.write("code/tool/Cargo.toml")
        try fixture.write("code/tool/target/debug/tool", bytes: 40_000)

        let projects = await scanner(fixture).scan()
        let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["web", "api", "tool"])
        #expect(Set(byName["web"]!.artifacts.map(\.relativePath)) == ["node_modules", ".next"])
        #expect(Set(byName["api"]!.artifacts.map(\.relativePath)) == [".venv", "app/__pycache__"])
        #expect(byName["tool"]!.artifacts.map(\.relativePath) == ["target"])
        #expect(byName["web"]!.bytes >= 40_000)
    }

    @Test func gitTrackedFoldersAreNeverDeleted() async throws {
        let fixture = try FixtureHome()
        let git = GitOnlyRunner()
        try #require(git.locate("git") != nil, "git is needed for this test")
        let repo = fixture.path("code/app")
        try fixture.write("code/app/package.json")
        try fixture.write("code/app/build/committed.js")       // tracked on purpose
        try fixture.write("code/app/dist/bundle.js", bytes: 20_000) // ignored
        try fixture.write("code/app/node_modules/dep/index.js", bytes: 20_000) // ignored
        try fixture.write("code/app/vendor-build/build/out.o")  // not ignored, not tracked
        try "dist/\nnode_modules/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        await git.git("init", "-q", in: repo)
        await git.git("add", "package.json", ".gitignore", "build/committed.js", in: repo)
        let commit = await git.git("commit", "-q", "-m", "init", in: repo)
        try #require(commit.succeeded, "git commit failed: \(commit.stderr)")

        let scanner = scanner(fixture, runner: git)
        let projects = await scanner.scan()
        try #require(projects.count == 1)
        let artifacts = projects[0].artifacts
        #expect(Set(artifacts.map(\.relativePath)) == ["dist", "node_modules"])
        #expect(artifacts.allSatisfy { $0.git == .ignored })

        // Someone commits the folder after the scan: the purge asks git again and refuses.
        await git.git("add", "-f", "dist/bundle.js", in: repo)
        let operation = await scanner.purge(artifacts, source: "test", mode: .permanent)
        #expect(operation.entries.first { $0.target.hasSuffix("/dist") }?.result == .refused)
        #expect(fixture.exists("code/app/dist/bundle.js"))
        #expect(!fixture.exists("code/app/node_modules"))
        #expect(fixture.exists("code/app/build/committed.js"))
        #expect(fixture.exists("code/app/.git/HEAD"))
    }

    @Test func gitProjectsAreLeftAloneWhenGitIsMissing() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/app/package.json")
        try fixture.write("code/app/node_modules/dep/index.js")
        try fixture.write("code/app/.git/HEAD")
        let projects = await scanner(fixture, runner: NullCommandRunner()).scan()
        #expect(projects.isEmpty)
    }

    @Test func symlinkedFoldersAreSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/web/package.json")
        try fixture.write("shared/node_modules/dep/index.js")
        try fixture.symlink("code/web/node_modules", to: fixture.path("shared/node_modules"))
        try fixture.symlink("code/linked", to: fixture.path("Documents"))
        let projects = await scanner(fixture).scan()
        #expect(projects.isEmpty)
        #expect(fixture.exists("shared/node_modules/dep/index.js"))
    }

    @Test func purgeGoesToTheTrashByDefault() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/web/package.json")
        try fixture.write("code/web/node_modules/dep/index.js", bytes: 10_000)
        let scanner = scanner(fixture)
        let projects = await scanner.scan()
        let operation = await scanner.purge(projects.flatMap(\.artifacts), source: "test")
        #expect(operation.kind == .projects)
        #expect(operation.bytesFreed >= 10_000)
        #expect(!fixture.exists("code/web/node_modules"))
        #expect(fixture.exists("code/web/package.json"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash")).count == 1)
    }

    @Test func recentAndStaleProjects() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/old/package.json")
        try fixture.write("code/old/node_modules/dep/index.js")
        try fixture.write("code/new/package.json")
        try fixture.write("code/new/node_modules/dep/index.js")
        let longAgo = Date().addingTimeInterval(-90 * 86_400)
        for relative in ["code/old/package.json", "code/old/node_modules", "code/old"] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: fixture.path(relative))
        }
        let projects = await scanner(fixture).scan()
        #expect(projects.map(\.name) == ["old", "new"])
        #expect(projects[0].isStale(days: 30))
        #expect(!projects[0].isRecent(days: 7))
        #expect(projects[1].isRecent(days: 7))
    }

    @Test func derivedDataIsMatchedToItsProject() async throws {
        let fixture = try FixtureHome()
        try fixture.write("code/App/App.xcodeproj/project.pbxproj")
        try fixture.write("code/App/Sources/main.swift")
        try fixture.write("Library/Developer/Xcode/DerivedData/App-abcdef/Build/app.o", bytes: 25_000)
        try fixture.write("Library/Developer/Xcode/DerivedData/Other-123456/Build/other.o")
        let info: NSDictionary = ["WorkspacePath": fixture.path("code/App/App.xcodeproj")]
        info.write(toFile: fixture.path("Library/Developer/Xcode/DerivedData/App-abcdef/info.plist"), atomically: true)

        let idle = scanner(fixture)
        let projects = await idle.scan()
        #expect(projects.count == 1)
        #expect(projects[0].artifacts.map(\.kind) == ["Xcode DerivedData"])

        let busy = scanner(fixture, processes: ["Xcode"])
        let skipped = await busy.purge(projects[0].artifacts, source: "test")
        #expect(skipped.skipped.first?.reason == "Xcode is running")

        await idle.purge(projects[0].artifacts, source: "test", mode: .permanent)
        #expect(!fixture.exists("Library/Developer/Xcode/DerivedData/App-abcdef"))
        #expect(fixture.exists("Library/Developer/Xcode/DerivedData/Other-123456/Build/other.o"))
    }
}

/// For random rules over random trees, no file outside the allowlist is ever removed.
@Suite struct SafetyPropertyTests {
    @Test(arguments: 0..<60)
    func neverRemovesAnythingOutsideTheAllowlist(seed: Int) async throws {
        var random = SeededGenerator(seed: UInt64(seed))
        let fixture = try FixtureHome()

        // A tree of ordinary cache folders mixed with things that must survive.
        let folders = [
            "Library/Caches/alpha", "Library/Caches/beta/inner", "Library/Caches/gamma", ".cache/tool", ".cache/other/deep",
            ".npm/_cacache", "Library/Application Support/App/Cache", "Library/Developer/Xcode/DerivedData/P-1",
            "Documents/work", "Documents/work/cache", "Desktop/stuff", "Pictures/album", ".ssh/keys",
            "code/repo/.git/objects", "code/repo/src", "Movies/clips", "Library/Mobile Documents/notes",
        ]
        for folder in folders {
            for index in 0..<Int.random(in: 1...3, using: &random) {
                try fixture.write("\(folder)/file\(index)", bytes: Int.random(in: 1...4096, using: &random))
            }
        }
        // Symlink traps at random places, pointing at random folders.
        let linkSpots = ["Library/Caches/link1", "Library/Caches/alpha/link2", ".cache/link3", ".cache/tool/link4"]
        for spot in linkSpots where Bool.random(using: &random) {
            try fixture.symlink(spot, to: fixture.path(folders.randomElement(using: &random)!))
        }

        // Rules that point anywhere, including straight at protected places.
        let targets = folders.map { "~/" + $0 } + linkSpots.map { "~/" + $0 } + [
            "~", "~/Library", "~/Library/Caches", "~/Documents", "~/.ssh", "~/Desktop", "/", "~/code/repo/.git", "~/code/repo",
            "~/Library/Caches/alpha/../../../Documents", "~/Library/Caches/*", "~/.cache/{tool,other}", "~/code/*", "~/Library/*",
        ]
        let strategies: [CleanStrategy] = [.delete, CleanStrategy(type: .deleteChildren), CleanStrategy(type: .select)]
        var items: [CatalogItem] = []
        for index in 0..<Int.random(in: 3...8, using: &random) {
            let paths = (0..<Int.random(in: 1...3, using: &random)).map { _ in targets.randomElement(using: &random)! }
            items.append(.rule("rule\(index)", paths: paths, clean: strategies.randomElement(using: &random)!))
        }

        let engine = fixture.engine(items: items)
        let before = fixture.files()
        let results = await engine.scanAllCollected()
        // Select everything, including every entry of the pick-lists.
        let selections = results.map { CleanSelection($0, targetIDs: Set($0.targets.map(\.id))) }
        await engine.clean(selections, source: "property", mode: Bool.random(using: &random) ? .permanent : .trash)
        let removed = before.subtracting(fixture.files())

        let allowlist = results.flatMap(\.roots)
        let home = fixture.home.path
        let protected = ["Documents", "Desktop", "Pictures", "Movies", ".ssh", "Library/Mobile Documents"].map { "\(home)/\($0)/" }
        for file in removed {
            #expect(allowlist.contains { file.hasPrefix($0 + "/") }, "seed \(seed): \(file) was removed but no rule resolved to it")
            #expect(!protected.contains { file.hasPrefix($0) }, "seed \(seed): protected file \(file) was removed")
            #expect(!file.contains("/.git/"), "seed \(seed): \(file) is inside a .git folder")
        }
        // The roots themselves must never be protected places.
        for root in allowlist {
            #expect(engine.safety.denyReason(for: root, scope: .cache) == nil, "seed \(seed): root \(root) is protected")
        }
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(fixture.exists(".ssh/id_ed25519"))
    }

    @Test func thePropertyTestActuallyDeletesThings() async throws {
        // Guards against the property above passing because nothing ran.
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/alpha/file")
        try fixture.write(".cache/tool/file")
        let engine = fixture.engine(items: [
            .rule("a", paths: ["~/Library/Caches/*"]),
            .rule("b", paths: ["~/.cache/{tool,other}"], clean: CleanStrategy(type: .select)),
        ])
        let results = await engine.scanAllCollected()
        await engine.clean(results.map { CleanSelection($0, targetIDs: Set($0.targets.map(\.id))) }, source: "property")
        #expect(!fixture.exists("Library/Caches/alpha"))
        #expect(!fixture.exists(".cache/tool/file"))
    }
}
