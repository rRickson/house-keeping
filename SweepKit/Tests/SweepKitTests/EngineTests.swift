import Foundation
import Testing
@testable import SweepKit
import SweepTestSupport

@Suite struct CatalogTests {
    @Test func bundledCatalogHasEveryEntry() {
        let catalog = Catalog.bundled()
        #expect(catalog.warnings.isEmpty)
        #expect(catalog.items.count == 56)
        #expect(Set(catalog.items.map(\.id)).count == 56)
        for item in catalog.items {
            #expect(Catalog.validate(item) == nil, "\(item.id) is invalid")
        }
    }

    @Test func itemsTheUserPicksFromAreAskTier() {
        for item in Catalog.bundled().items where item.clean.type == .select {
            #expect(item.risk == .ask, "\(item.id) lets the user pick but is not Ask tier")
        }
    }

    @Test func userCatalogEntriesAreMerged() throws {
        let fixture = try FixtureHome()
        let directory = fixture.path("Library/Application Support/Sweep/catalog.d")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let json = """
        {"id": "mytool", "name": "My tool", "group": "other", "risk": "safe",
         "locate": [{"paths": ["~/.mytool/cache"]}], "clean": {"type": "delete"}}
        """
        try json.write(toFile: directory + "/mytool.json", atomically: true, encoding: .utf8)
        try "{ not json".write(toFile: directory + "/broken.json", atomically: true, encoding: .utf8)
        let catalog = Catalog.load(context: .fixture(home: fixture.home))
        #expect(catalog.items.count == 57)
        #expect(catalog.item("mytool")?.name == "My tool")
        #expect(catalog.warnings.count == 1)
    }
}

@Suite struct SizerTests {
    @Test func countsHardlinksOnceAndNeverFollowsLinks() throws {
        let fixture = try FixtureHome()
        let original = try fixture.write("cache/blob", bytes: 256 * 1024)
        try FileManager.default.linkItem(atPath: original, toPath: fixture.path("cache/blob-link"))
        try fixture.write("cache/nested/deep/file", bytes: 64 * 1024)
        try fixture.write("elsewhere/huge", bytes: 1024 * 1024)
        try fixture.symlink("cache/escape", to: fixture.path("elsewhere"))

        let size = try Sizer().size(of: URL(fileURLWithPath: fixture.path("cache")))
        #expect(size.bytes == 256 * 1024 + 64 * 1024)
        #expect(size.files == 4)
        #expect(size.lastModified != nil)
    }

    @Test func matchesDu() throws {
        let fixture = try FixtureHome()
        for index in 0..<40 {
            try fixture.write("tree/d\(index % 5)/f\(index)", bytes: 1000 + index * 733)
        }
        let size = try Sizer().size(of: URL(fileURLWithPath: fixture.path("tree")))
        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", fixture.path("tree")]
        let pipe = Pipe()
        du.standardOutput = pipe
        try du.run()
        du.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let kilobytes = Int64(output.split(separator: "\t").first.map(String.init) ?? "") ?? -1
        #expect(size.bytes == kilobytes * 1024)
    }
}

@Suite struct ResolverTests {
    @Test func asksTheToolBeforeTheDefaultPath() async throws {
        let fixture = try FixtureHome()
        try fixture.write("custom-npm/_cacache/blob")
        try fixture.write(".npm/_cacache/blob")
        let runner = FakeRunner()
        runner.on("npm") { _ in CommandResult(exitCode: 0, stdout: fixture.path("custom-npm") + "\n") }
        let item = Catalog.bundled().item("npm")!
        let engine = fixture.engine(items: [item], runner: runner)

        let resolution = await engine.resolver.resolve(item)
        #expect(resolution.roots == [fixture.path("custom-npm/_cacache")])
        #expect(resolution.source == .tool(["npm", "config", "get", "cache"]))
    }

    @Test func fallsBackToEnvironmentThenDefault() async throws {
        let fixture = try FixtureHome()
        try fixture.write("uv-env/blob")
        try fixture.write(".cache/uv/blob")
        let item = Catalog.bundled().item("uv")!

        let withEnv = fixture.engine(items: [item], environment: ["UV_CACHE_DIR": fixture.path("uv-env")])
        #expect(await withEnv.resolver.resolve(item).roots == [fixture.path("uv-env")])

        let plain = fixture.engine(items: [item])
        let resolution = await plain.resolver.resolve(item)
        #expect(resolution.roots == [fixture.path(".cache/uv")])
        #expect(resolution.source == .defaultPath)
    }

    @Test func ignoresNonsenseFromATool() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/Yarn/blob")
        let runner = FakeRunner()
        runner.on("yarn") { _ in CommandResult(exitCode: 0, stdout: "undefined\n") }
        let item = Catalog.bundled().item("yarn")!
        let engine = fixture.engine(items: [item], runner: runner)
        let result = await engine.scan(item)
        #expect(result.roots == [fixture.path("Library/Caches/Yarn")])
        // The tool did not report this folder, so its clean command would miss it.
        #expect(result.targets.map(\.action) == [.delete(path: fixture.path("Library/Caches/Yarn"))])
    }

    @Test func expandsBracesAndWildcards() throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Application Support/Code/Cache/a")
        try fixture.write("Library/Application Support/Cursor/logs/b")
        let pattern = fixture.path("Library/Application Support/{Code,Cursor}/{Cache,logs}")
        #expect(Glob.expand(pattern) == [
            fixture.path("Library/Application Support/Code/Cache"),
            fixture.path("Library/Application Support/Cursor/logs"),
        ])
    }
}

@Suite struct CleanTests {
    @Test func deletesExactlyTheResolvedFolder() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/node-gyp/18.0.0/node.h", bytes: 50_000)
        try fixture.write("Library/Caches/keep/data")
        let engine = fixture.engine(items: [.rule("gyp", paths: ["~/Library/Caches/node-gyp"])])

        let results = await engine.scanAllCollected()
        #expect(results[0].status == .ready)
        #expect(results[0].bytes >= 50_000)

        let operation = await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(operation.bytesFreed == results[0].bytes)
        #expect(!fixture.exists("Library/Caches/node-gyp"))
        #expect(fixture.exists("Library/Caches/keep/data"))
        #expect(engine.ledger.operations().count == 1)
        #expect(engine.ledger.operations()[0].entries[0].target == fixture.path("Library/Caches/node-gyp"))
    }

    @Test func dryRunTouchesNothing() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/node-gyp/node.h", bytes: 50_000)
        let engine = fixture.engine(items: [.rule("gyp", paths: ["~/Library/Caches/node-gyp"])])
        let before = fixture.files()
        let results = await engine.scanAllCollected()
        let operation = await engine.clean(engine.oneClickSelection(from: results), source: "test", dryRun: true)
        #expect(operation.bytesPlanned == results[0].bytes)
        #expect(operation.bytesFreed == 0)
        #expect(fixture.files() == before)
        #expect(engine.ledger.operations().isEmpty)
    }

    @Test func prefersTheToolsOwnCleanCommand() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".npm/_cacache/content/blob", bytes: 80_000)
        let cache = fixture.path(".npm")
        let runner = FakeRunner()
        runner.on("npm") { arguments in
            if arguments == ["config", "get", "cache"] { return CommandResult(exitCode: 0, stdout: cache + "\n") }
            if arguments == ["cache", "clean", "--force"] {
                try? FileManager.default.removeItem(atPath: cache + "/_cacache")
                return CommandResult(exitCode: 0)
            }
            return CommandResult(exitCode: 1)
        }
        let engine = fixture.engine(items: [Catalog.bundled().item("npm")!], runner: runner)
        let results = await engine.scanAllCollected()
        #expect(results[0].actionDescription == "npm cache clean --force")

        let operation = await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(runner.ran(["npm", "cache", "clean", "--force"]))
        #expect(operation.entries.count == 1)
        #expect(operation.entries[0].mode == "command")
        #expect(operation.bytesFreed >= 80_000)
    }

    @Test func pruneCommandsAreMarkedAsUpperBounds() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".cache/uv/archive/blob", bytes: 30_000)
        let cache = fixture.path(".cache/uv")
        let runner = FakeRunner()
        runner.on("uv") { arguments in arguments == ["cache", "dir"] ? CommandResult(exitCode: 0, stdout: cache) : CommandResult(exitCode: 0) }
        let item = Catalog.bundled().item("uv")!

        let pruning = await fixture.engine(items: [item], runner: runner).scanAllCollected()
        #expect(pruning[0].isUpperBound)
        // Without the tool the folder is deleted outright, so the size is exact.
        let deleting = await fixture.engine(items: [item]).scanAllCollected()
        #expect(!deleting[0].isUpperBound)

        var settings = SweepSettings()
        settings.uvFullClean = true
        let full = await fixture.engine(items: [item], runner: runner, settings: settings).scanAllCollected()
        #expect(!full[0].isUpperBound)
        #expect(full[0].actionDescription == "uv cache clean")
    }

    @Test func reportsAFailedCommandAndKeepsGoing() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".npm/_cacache/blob", bytes: 10_000)
        try fixture.write("Library/Caches/node-gyp/node.h", bytes: 10_000)
        let cache = fixture.path(".npm")
        let runner = FakeRunner()
        runner.on("npm") { arguments in
            arguments.first == "config" ? CommandResult(exitCode: 0, stdout: cache) : CommandResult(exitCode: 1, stderr: "npm ERR! EACCES")
        }
        let engine = fixture.engine(items: [Catalog.bundled().item("npm")!, .rule("gyp", paths: ["~/Library/Caches/node-gyp"])], runner: runner)
        let results = await engine.scanAllCollected()
        let operation = await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(operation.failures.count == 1)
        #expect(operation.failures[0].reason?.contains("EACCES") == true)
        #expect(!fixture.exists("Library/Caches/node-gyp"))
    }

    @Test func deleteChildrenLeavesExcludedEntries() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/pypoetry/cache/a.whl", bytes: 20_000)
        try fixture.write("Library/Caches/pypoetry/artifacts/b.whl", bytes: 20_000)
        try fixture.write("Library/Caches/pypoetry/virtualenvs/proj-py3.12/pyvenv.cfg")
        let engine = fixture.engine(items: [Catalog.bundled().item("poetry")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.count == 2)
        await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(!fixture.exists("Library/Caches/pypoetry/cache"))
        #expect(fixture.exists("Library/Caches/pypoetry/virtualenvs/proj-py3.12/pyvenv.cfg"))
        #expect(fixture.exists("Library/Caches/pypoetry"))
    }

    @Test func askTierIsNeverCleanedInOneClick() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".cache/huggingface/hub/models--org--big/blob", bytes: 30_000)
        try fixture.write(".cache/huggingface/hub/models--org--small/blob", bytes: 10_000)
        let engine = fixture.engine(items: [Catalog.bundled().item("huggingface")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].selectable)
        #expect(engine.oneClickSelection(from: results).isEmpty)

        // Even asked directly, nothing goes without an explicit selection.
        let blind = await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(blind.bytesFreed == 0)
        #expect(fixture.exists(".cache/huggingface/hub/models--org--big/blob"))

        let picked = fixture.path(".cache/huggingface/hub/models--org--small")
        await engine.clean([CleanSelection(results[0], targetIDs: [picked])], source: "test")
        #expect(!fixture.exists(".cache/huggingface/hub/models--org--small"))
        #expect(fixture.exists(".cache/huggingface/hub/models--org--big/blob"))
    }

    @Test func cautionTierIsOffUnlessEnabled() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".m2/repository/a.jar", bytes: 10_000)
        let item = Catalog.bundled().item("maven")!
        let engine = fixture.engine(items: [item])
        let results = await engine.scanAllCollected()
        #expect(engine.oneClickSelection(from: results).isEmpty)

        var settings = SweepSettings()
        settings.oneClickTiers = [.safe, .caution]
        let permissive = fixture.engine(items: [item], settings: settings)
        #expect(permissive.oneClickSelection(from: results).count == 1)
    }

    @Test func trashModeMovesInsteadOfDeleting() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/node-gyp/node.h")
        let engine = fixture.engine(items: [.rule("gyp", paths: ["~/Library/Caches/node-gyp"])])
        let results = await engine.scanAllCollected()
        await engine.clean(engine.oneClickSelection(from: results), source: "test", mode: .trash)
        #expect(!fixture.exists("Library/Caches/node-gyp"))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash"))
        #expect(trashed.count == 1)
    }

    @Test func removesReadOnlyTrees() async throws {
        let fixture = try FixtureHome()
        try fixture.write("go/pkg/mod/example.com/pkg@v1/file.go")
        chmod(fixture.path("go/pkg/mod/example.com/pkg@v1"), 0o555)
        chmod(fixture.path("go/pkg/mod/example.com"), 0o555)
        // Go is not installed in the fixture, so the rule falls back to deleting.
        let engine = fixture.engine(items: [Catalog.bundled().item("go-mod")!])
        let results = await engine.scanAllCollected()
        let operation = await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(operation.failures.isEmpty)
        #expect(!fixture.exists("go/pkg/mod"))
    }

    @Test func exclusionsAreRespected() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/node-gyp/node.h")
        try fixture.write("Library/Caches/electron/electron.zip")
        var settings = SweepSettings()
        settings.exclusions = ["gyp", "~/Library/Caches/electron"]
        let engine = fixture.engine(items: [
            .rule("gyp", paths: ["~/Library/Caches/node-gyp"]),
            .rule("electron", paths: ["~/Library/Caches/electron"]),
        ], settings: settings)
        let results = await engine.scanAllCollected()
        #expect(results.allSatisfy { $0.status == .blocked("Excluded in Settings") })
        await engine.clean(results.map { CleanSelection($0) }, source: "test")
        #expect(fixture.exists("Library/Caches/node-gyp/node.h"))
        #expect(fixture.exists("Library/Caches/electron/electron.zip"))
    }
}

@Suite struct GuardTests {
    @Test func derivedDataIsSkippedWhileXcodeRuns() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Developer/Xcode/DerivedData/App-abc/Build/app.o", bytes: 40_000)
        let item = Catalog.bundled().item("xcode-deriveddata")!

        let running = fixture.engine(items: [item], processes: ["Xcode"])
        let blocked = await running.scanAllCollected()
        #expect(blocked[0].status == .blocked("Xcode is running"))
        #expect(running.oneClickSelection(from: blocked).isEmpty)

        // Xcode starts between the scan and the clean: the re-check still catches it.
        let idle = fixture.engine(items: [item])
        let ready = await idle.scanAllCollected()
        #expect(ready[0].status == .ready)
        let operation = await running.clean([CleanSelection(ready[0])], source: "test")
        #expect(operation.bytesFreed == 0)
        #expect(operation.skipped.first?.reason == "Xcode is running")
        #expect(fixture.exists("Library/Developer/Xcode/DerivedData/App-abc/Build/app.o"))

        await idle.clean([CleanSelection(ready[0])], source: "test")
        #expect(!fixture.exists("Library/Developer/Xcode/DerivedData/App-abc"))
        #expect(fixture.exists("Library/Developer/Xcode/DerivedData"))
    }

    @Test func aCacheFolderLinkingToDocumentsIsRefused() async throws {
        let fixture = try FixtureHome()
        try fixture.symlink("Library/Caches/trap", to: fixture.path("Documents"))
        let engine = fixture.engine(items: [.rule("trap", paths: ["~/Library/Caches/trap"])])
        let results = await engine.scanAllCollected()
        #expect(results[0].roots.isEmpty)
        if case .blocked(let reason) = results[0].status {
            #expect(reason.contains("Refused"))
        } else {
            Issue.record("expected the trap to be refused, got \(results[0].status)")
        }
        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func aLinkInsideACacheIsUnlinkedNotFollowed() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/tool/data", bytes: 10_000)
        try fixture.symlink("Library/Caches/tool/docs", to: fixture.path("Documents"))
        let engine = fixture.engine(items: [.rule("tool", paths: ["~/Library/Caches/tool"])])
        let results = await engine.scanAllCollected()
        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(!fixture.exists("Library/Caches/tool"))
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func aLinkInsideACacheIsNeverOfferedOrFollowed() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/tool/real/data")
        try fixture.symlink("Library/Caches/tool/docs", to: fixture.path("Documents"))
        try fixture.symlink("Library/Caches/tool/latest", to: fixture.path("Library/Caches/tool/gone.txt"))
        let engine = fixture.engine(items: [.rule("tool", paths: ["~/Library/Caches/tool"], clean: CleanStrategy(type: .deleteChildren))])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.map(\.label) == ["real"])
        let operation = await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(operation.failures.isEmpty)
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(!fixture.exists("Library/Caches/tool/real"))

        // Handed to the remover directly, a link is still refused.
        let link = fixture.path("Library/Caches/tool/docs")
        let outcome = engine.remover.remove(link, allowedRoots: [fixture.path("Library/Caches/tool")], scope: .cache,
                                            fingerprint: nil, mode: .permanent, dryRun: false)
        #expect(outcome == .refused("is a symbolic link"))
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func aFolderSwappedAfterTheScanIsSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/tool/data")
        let engine = fixture.engine(items: [.rule("tool", paths: ["~/Library/Caches/tool"])])
        let results = await engine.scanAllCollected()
        // Replace the scanned folder with a different one of the same name.
        try FileManager.default.moveItem(atPath: fixture.path("Library/Caches/tool"), toPath: fixture.path("Library/Caches/old"))
        try fixture.write("Library/Caches/tool/precious")
        let operation = await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(operation.skipped.first?.reason == "changed since the scan")
        #expect(fixture.exists("Library/Caches/tool/precious"))
    }

    @Test func protectedLocationsAreDenied() throws {
        let fixture = try FixtureHome()
        let safety = SafetyGuard(home: fixture.home)
        let home = fixture.home.path
        let denied = [
            "/", "/System/Library/Caches", "/usr/bin", "/bin", "/sbin", "/Applications", "/Applications/Safari.app",
            home, "\(home)/Documents", "\(home)/Documents/work/cache", "\(home)/Desktop", "\(home)/Pictures/x",
            "\(home)/Movies", "\(home)/Music/iTunes", "\(home)/Library/Mobile Documents/com~apple~CloudDocs",
            "\(home)/.ssh", "\(home)/.ssh/known_hosts", "\(home)/.gnupg", "\(home)/Library/Keychains/login.keychain-db",
            "\(home)/code/app/.git", "\(home)/code/app/.git/objects", "\(home)/Library", "\(home)/Library/Caches",
            "/Users", "/Library",
        ]
        for path in denied {
            #expect(safety.denyReason(for: path, scope: .cache) != nil, "\(path) should be denied")
        }
        let allowed = ["\(home)/Library/Caches/Homebrew", "\(home)/.npm/_cacache", "\(home)/.cache/uv", "/usr/local/Caches/x"]
        for path in allowed {
            #expect(safety.denyReason(for: path, scope: .cache) == nil, "\(path) should be allowed")
        }
        // Only Uninstall may go inside /Applications, and never the folder itself.
        #expect(safety.denyReason(for: "/Applications/Foo.app", scope: .uninstall) == nil)
        #expect(safety.denyReason(for: "/Applications", scope: .uninstall) != nil)
        // Build artifacts inside a project under ~/Documents are allowed; the folder itself is not.
        #expect(safety.denyReason(for: "\(home)/Documents/code/app/node_modules", scope: .projectArtifact) == nil)
        #expect(safety.denyReason(for: "\(home)/Documents/node_modules", scope: .projectArtifact) != nil)
    }

    @Test func nothingOutsideTheAllowlistPasses() throws {
        let fixture = try FixtureHome()
        try fixture.write("Library/Caches/tool/data")
        try fixture.write("Library/Caches/other/data")
        let safety = SafetyGuard(home: fixture.home)
        let root = fixture.path("Library/Caches/tool")
        #expect(safety.evaluate(fixture.path("Library/Caches/tool/data"), allowedRoots: [root], scope: .cache).allowed)
        #expect(safety.evaluate(root, allowedRoots: [root], scope: .cache).allowed)
        #expect(!safety.evaluate(fixture.path("Library/Caches/other/data"), allowedRoots: [root], scope: .cache).allowed)
        #expect(!safety.evaluate(fixture.path("Library/Caches/tool/../other/data"), allowedRoots: [root], scope: .cache).allowed)
        #expect(!safety.evaluate(fixture.path("Library/Caches/toolbox"), allowedRoots: [root], scope: .cache).allowed)
        #expect(!safety.evaluate(root, allowedRoots: [], scope: .cache).allowed)
    }
}

@Suite struct LedgerTests {
    @Test func appendsOneLinePerOperation() throws {
        let fixture = try FixtureHome()
        let ledger = Ledger(directory: fixture.home.appendingPathComponent("Library/Logs/Sweep"))
        for index in 0..<3 {
            ledger.append(SweepOperation(kind: .devCaches, source: "test", entries: [
                OperationEntry(itemID: "npm", itemName: "npm", target: "/tmp/\(index)", bytes: 1000, mode: "permanent", result: .removed),
            ]))
        }
        ledger.append(SweepOperation(kind: .devCaches, source: "test", dryRun: true, entries: [
            OperationEntry(itemID: "npm", itemName: "npm", target: "/tmp/x", bytes: 1, mode: "permanent", result: .dryRun),
        ]))
        let text = try String(contentsOf: ledger.fileURL, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
        let operations = ledger.operations()
        #expect(operations.count == 3)
        #expect(operations[0].entries[0].target == "/tmp/2")
        #expect(ledger.weeklyTotals(weeks: 4).last?.bytes == 3000)
    }
}

@Suite struct FormatTests {
    @Test func parsesToolSizes() {
        #expect(ByteFormat.parse("1.5GB") == 1_500_000_000)
        #expect(ByteFormat.parse("512 MB") == 512_000_000)
        #expect(ByteFormat.parse("12.3kB (40%)") == 12_300)
        #expect(ByteFormat.parse("0B") == 0)
        #expect(ByteFormat.parse("4.7 GiB") == Int64(4.7 * 1_073_741_824))
        #expect(ByteFormat.parse("n/a") == nil)
    }

    @Test func formatsSizesInOneStyle() {
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(ByteFormat.string(18_400_000_000) == "18\(separator)4 GB")
        #expect(ByteFormat.string(374_000_000) == "374 MB")
        #expect(ByteFormat.string(999_999_999) == "1\(separator)0 GB")
        #expect(ByteFormat.string(4_096) == "4 KB")
        #expect(ByteFormat.string(0) == "0 bytes")
    }

    @Test func settingsSurviveMissingKeys() throws {
        let partial = #"{"oneClickTiers": ["safe", "caution", "ask"], "recentProjectDays": 3}"#
        let settings = try JSONDecoder().decode(SweepSettings.self, from: Data(partial.utf8))
        #expect(settings.oneClickTiers == [.safe, .caution])
        #expect(settings.recentProjectDays == 3)
        #expect(settings.cacheDeleteMode == .permanent)
        #expect(settings.projectDeleteMode == .trash)
    }
}

@Suite struct HandlerTests {
    @Test func jetBrainsOnlyOffersVersionsThatAreNotInstalled() async throws {
        let fixture = try FixtureHome()
        for name in ["IntelliJIdea2025.3", "IntelliJIdea2026.2", "PyCharm2025.1", "Daemon", "acp-agents"] {
            try fixture.write("Library/Caches/JetBrains/\(name)/index", bytes: 8_000)
        }
        try fixture.write("Library/Caches/Google/AndroidStudio2025.3.3/index")
        try fixture.write("Library/Caches/Google/AndroidStudio2025.3.4/index")
        try fixture.write("Library/Caches/Google/Chrome/Default/Cache/data")
        // Installed: IntelliJ IDEA 2026.2 (current format) and Android Studio 2025.3.4.
        try #"{"dataDirectoryName": "IntelliJIdea2026.2"}"#.write(
            toFile: try fixture.write("Applications/IntelliJ IDEA.app/Contents/Resources/product-info.json"), atomically: true, encoding: .utf8)
        try #"{"dataDirectoryName": "AndroidStudio2025.3.4"}"#.write(
            toFile: try fixture.write("Applications/Android Studio.app/Contents/Resources/product-info.json"), atomically: true, encoding: .utf8)

        let engine = fixture.engine(items: [Catalog.bundled().item("jetbrains")!])
        let results = await engine.scanAllCollected()
        #expect(Set(results[0].targets.map(\.label)) == ["IntelliJIdea2025.3", "PyCharm2025.1", "AndroidStudio2025.3.3"])

        await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(!fixture.exists("Library/Caches/JetBrains/IntelliJIdea2025.3"))
        #expect(fixture.exists("Library/Caches/JetBrains/IntelliJIdea2026.2/index"))
        #expect(fixture.exists("Library/Caches/JetBrains/Daemon/index"))
        #expect(fixture.exists("Library/Caches/Google/AndroidStudio2025.3.4/index"))
        #expect(fixture.exists("Library/Caches/Google/Chrome/Default/Cache/data"))
    }

    @Test func deviceSupportKeepsTheNewestVersion() async throws {
        let fixture = try FixtureHome()
        for version in ["17.4 (21E213)", "18.1 (22B83)", "iPhone15,2 18.0 (22A3354)", "9.3 (13E230)"] {
            try fixture.write("Library/Developer/Xcode/iOS DeviceSupport/\(version)/Symbols/dyld", bytes: 5_000)
        }
        try fixture.write("Library/Developer/Xcode/watchOS DeviceSupport/10.0 (21R355)/Symbols/dyld")
        let engine = fixture.engine(items: [Catalog.bundled().item("device-support")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.count == 3)
        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(fixture.exists("Library/Developer/Xcode/iOS DeviceSupport/18.1 (22B83)/Symbols/dyld"))
        #expect(!fixture.exists("Library/Developer/Xcode/iOS DeviceSupport/17.4 (21E213)"))
        #expect(!fixture.exists("Library/Developer/Xcode/iOS DeviceSupport/9.3 (13E230)"))
        #expect(fixture.exists("Library/Developer/Xcode/watchOS DeviceSupport/10.0 (21R355)/Symbols/dyld"))
    }

    @Test func dockerReportsReclaimableAndMeasuresWhatWasFreed() async throws {
        let fixture = try FixtureHome()
        let pruned = Locked(false)
        let runner = FakeRunner()
        runner.on("docker") { arguments in
            if arguments.starts(with: ["system", "df"]) {
                let cache = pruned.get() ? "0B" : "20.64GB"
                return CommandResult(exitCode: 0, stdout: """
                {"Reclaimable":"3.87GB (21%)","Size":"18.01GB","Type":"Images"}
                {"Reclaimable":"\(cache)","Size":"29.9GB","Type":"Build Cache"}
                """)
            }
            if arguments == ["builder", "prune", "-f"] {
                pruned.set(true)
                return CommandResult(exitCode: 0)
            }
            return CommandResult(exitCode: 1)
        }
        let engine = fixture.engine(items: [Catalog.bundled().item("docker-build-cache")!], runner: runner)
        let results = await engine.scanAllCollected()
        #expect(results[0].bytes == 20_640_000_000)
        let operation = await engine.clean(engine.oneClickSelection(from: results), source: "test")
        #expect(operation.bytesFreed == 20_640_000_000)
    }

    @Test func dockerThatIsNotRunningIsBlocked() async throws {
        let fixture = try FixtureHome()
        let runner = FakeRunner()
        runner.on("docker") { _ in CommandResult(exitCode: 1, stderr: "Cannot connect to the Docker daemon") }
        let engine = fixture.engine(items: [Catalog.bundled().item("docker-build-cache")!], runner: runner)
        let results = await engine.scanAllCollected()
        #expect(results[0].status == .blocked("Docker is not running"))
    }
}

@Suite struct OldSessionTests {
    /// Makes a path and everything inside it look untouched for `days` days.
    private func age(_ fixture: FixtureHome, _ relative: String, days: Int) throws {
        let date = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let root = fixture.path(relative)
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let child as String in enumerator {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root + "/" + child)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root)
    }

    @Test func onlySessionsUntouchedLongEnoughAreOffered() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".claude/file-history/old-session/a.txt@v1", bytes: 9_000)
        try fixture.write(".claude/file-history/live-session/b.txt@v1", bytes: 9_000)
        // An old folder with one fresh file inside is a session that is still in use.
        try fixture.write(".claude/file-history/resumed-session/old.txt@v1")
        try age(fixture, ".claude/file-history/old-session", days: 45)
        try age(fixture, ".claude/file-history/resumed-session", days: 45)
        try fixture.write(".claude/file-history/resumed-session/new.txt@v1")

        let engine = fixture.engine(items: [Catalog.bundled().item("claude-file-history")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.map(\.label) == ["old-session"])
        #expect(results[0].actionDescription == "Delete entries untouched for 30 days")

        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(!fixture.exists(".claude/file-history/old-session"))
        #expect(fixture.exists(".claude/file-history/live-session/b.txt@v1"))
        #expect(fixture.exists(".claude/file-history/resumed-session/old.txt@v1"))
    }

    @Test func theSettingDecidesHowOldAgentHistoryMustBe() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".codex/sessions/2026/10/01/rollout-a.jsonl")
        try age(fixture, ".codex/sessions/2026/10/01", days: 10)
        try fixture.write(".codex/shell_snapshots/snap.sh")
        try age(fixture, ".codex/shell_snapshots/snap.sh", days: 2)
        let items = [Catalog.bundled().item("codex-sessions")!, Catalog.bundled().item("codex-leftovers")!]

        let standard = await fixture.engine(items: items).scanAllCollected()
        #expect(standard[0].targets.isEmpty)

        var settings = SweepSettings()
        settings.oldSessionDays = 7
        let eager = await fixture.engine(items: items, settings: settings).scanAllCollected()
        #expect(eager[0].targets.count == 1)
        #expect(eager[0].actionDescription == "Delete entries untouched for 7 days")
        // Temp files keep the age their own rule gives them.
        #expect(eager[1].targets.isEmpty)
    }

    @Test func aSessionResumedAfterTheScanIsSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".codex/shell_snapshots/snap-1.sh")
        try age(fixture, ".codex/shell_snapshots/snap-1.sh", days: 20)
        let engine = fixture.engine(items: [Catalog.bundled().item("codex-leftovers")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.count == 1)

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fixture.path(".codex/shell_snapshots/snap-1.sh"))
        let operation = await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(operation.skipped.first?.reason == "used since the scan")
        #expect(fixture.exists(".codex/shell_snapshots/snap-1.sh"))
    }

    @Test func transcriptsGoButProjectMemoryStays() async throws {
        let fixture = try FixtureHome()
        let project = ".claude/projects/-Users-me-code-app"
        let session = "0a1b2c3d-1111-2222-3333-444455556666"
        try fixture.write("\(project)/\(session).jsonl", bytes: 12_000)
        try fixture.write("\(project)/\(session)/subagents/agent.jsonl")
        try fixture.write("\(project)/memory/MEMORY.md")
        try fixture.write("\(project)/sessions-index.json")
        try fixture.write("\(project)/9f9f9f9f-aaaa-bbbb-cccc-ddddeeeeffff.jsonl")
        for name in ["\(session).jsonl", session, "memory", "sessions-index.json"] {
            try age(fixture, "\(project)/\(name)", days: 60)
        }

        let engine = fixture.engine(items: [Catalog.bundled().item("claude-transcripts")!])
        let results = await engine.scanAllCollected()
        #expect(Set(results[0].targets.map(\.label)) == [session, "\(session).jsonl"])
        // Caution tier: never part of the one-click clean by default.
        #expect(engine.oneClickSelection(from: results).isEmpty)

        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(!fixture.exists("\(project)/\(session).jsonl"))
        #expect(!fixture.exists("\(project)/\(session)"))
        #expect(fixture.exists("\(project)/memory/MEMORY.md"))
        #expect(fixture.exists("\(project)/sessions-index.json"))
        #expect(fixture.exists("\(project)/9f9f9f9f-aaaa-bbbb-cccc-ddddeeeeffff.jsonl"))
    }

    @Test func codexSessionsAreJudgedPerDay() async throws {
        let fixture = try FixtureHome()
        try fixture.write(".codex/sessions/2026/08/02/rollout-a.jsonl", bytes: 7_000)
        try fixture.write(".codex/sessions/2026/10/12/rollout-b.jsonl", bytes: 7_000)
        try age(fixture, ".codex/sessions/2026/08/02", days: 70)
        let engine = fixture.engine(items: [Catalog.bundled().item("codex-sessions")!])
        let results = await engine.scanAllCollected()
        #expect(results[0].targets.map(\.label) == ["08/02"])
        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(!fixture.exists(".codex/sessions/2026/08/02"))
        #expect(fixture.exists(".codex/sessions/2026/10/12/rollout-b.jsonl"))
    }

    @Test func aFixtureHomeNeverReachesTheRealDisk() async throws {
        let fixture = try FixtureHome()
        // A folder outside the fixture home stands in for /private/tmp on the real disk.
        let outside = fixture.root.appendingPathComponent("outside/claude-501/project/session")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: outside.appendingPathComponent("scratch.txt"))
        try age(fixture, "../outside/claude-501/project/session", days: 30)

        let rule = CatalogItem.rule("tmp", paths: [fixture.root.path + "/outside/claude-*/*"],
                                    clean: CleanStrategy(type: .deleteChildren, olderThanDays: 3))
        let engine = fixture.engine(items: [rule, Catalog.bundled().item("claude-tmp")!])
        let results = await engine.scanAllCollected()
        #expect(results.allSatisfy { $0.roots.isEmpty && $0.status == .missing })
        await engine.clean(results.map { CleanSelection($0) }, source: "test")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("scratch.txt").path))
    }

    @Test func dockerUnusedImagesUsesImagePruneAll() async throws {
        let fixture = try FixtureHome()
        let runner = FakeRunner()
        runner.on("docker") { arguments in
            if arguments.starts(with: ["system", "df"]) {
                return CommandResult(exitCode: 0, stdout: #"{"Reclaimable":"3.87GB (21%)","Size":"18.01GB","Type":"Images"}"#)
            }
            return CommandResult(exitCode: arguments == ["image", "prune", "-a", "-f"] ? 0 : 1)
        }
        let engine = fixture.engine(items: [Catalog.bundled().item("docker-images")!], runner: runner)
        let results = await engine.scanAllCollected()
        #expect(results[0].bytes == 3_870_000_000)
        #expect(results[0].item.risk == .caution)
        #expect(engine.oneClickSelection(from: results).isEmpty)
        await engine.clean([CleanSelection(results[0])], source: "test")
        #expect(runner.ran(["docker", "image", "prune", "-a", "-f"]))
    }
}
