import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepOptimize

@Suite struct CatalogTests {
    @Test func coversTheSpecList() {
        let ids = Set(OptimizeCatalog.all.map(\.id))
        #expect(ids.count == OptimizeCatalog.all.count)
        for required in ["flush-dns", "rebuild-launch-services", "reset-quick-look", "rebuild-font-caches", "reindex-spotlight",
                         "vacuum-databases", "prune-notifications", "broken-launch-agents"] {
            #expect(ids.contains(required))
        }
        for task in OptimizeCatalog.all {
            #expect(!task.title.isEmpty && !task.summary.isEmpty && !task.symbol.isEmpty)
            #expect(OptimizeCatalog.task(id: task.id) == task)
        }
    }

    @Test func userStepsAreFixedArgumentArraysWithAbsoluteTools() {
        for task in OptimizeCatalog.all {
            for step in task.userSteps {
                #expect(step.argv.first?.hasPrefix("/") == true, "\(task.id) looks a tool up on PATH")
                #expect(step.argv.allSatisfy { word in word.allSatisfy { !shellMetacharacters.contains($0) } })
            }
        }
    }

    @Test func nothingOutOfBoundsIsInTheList() {
        let words = OptimizeCatalog.all.flatMap { $0.userSteps.flatMap(\.argv) }
            + PrivilegedTask.allCases.flatMap { PrivilegedCommandTable.commands(for: $0).flatMap(\.argv) }
        for banned in ["purge", "/bin/sh", "/bin/bash", "/bin/zsh", "sudo", "defaults", "spctl", "csrutil", "nvram", "pmset"] {
            #expect(!words.contains { $0 == banned || $0.hasSuffix("/" + banned) }, "\(banned) is not allowed")
        }
    }

    @Test func slowOrDisruptiveTasksStartUnticked() {
        #expect(!OptimizeCatalog.reindexSpotlight.selectedByDefault)
        #expect(!OptimizeCatalog.rebuildFontCaches.selectedByDefault)
        #expect(!OptimizeCatalog.restartDock.selectedByDefault)
        #expect(OptimizeCatalog.flushDNS.selectedByDefault)
    }
}

@Suite struct UserTaskTests {
    private func fakeTools(_ tools: [String]) -> FakeRunner {
        let runner = FakeRunner()
        for tool in tools { runner.on(tool) { _ in CommandResult(exitCode: 0) } }
        return runner
    }

    @Test func userLevelTasksRunTheExpectedArgumentArrays() async throws {
        let fixture = try FixtureHome()
        let tools = fakeTools([SystemTool.qlmanage, SystemTool.lsregister, SystemTool.killall])
        let engine = fixture.engine(items: [], runner: tools)
        let privileged = FakePrivileged()
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions())

        let operation = await runner.run([OptimizeCatalog.resetQuickLook, OptimizeCatalog.rebuildLaunchServices, OptimizeCatalog.restartDock])

        #expect(tools.log == [
            ["/usr/bin/qlmanage", "-r"],
            ["/usr/bin/qlmanage", "-r", "cache"],
            [SystemTool.lsregister, "-f", "-all", "system,local,user"],
            [SystemTool.lsregister, "-gc"],
            ["/usr/bin/killall", "Dock"],
        ])
        #expect(privileged.log.isEmpty)
        #expect(operation.entries.map(\.result) == [.removed, .removed, .removed])
    }

    @Test func adminTaskRunsItsPrivilegedStepThenItsUserStep() async throws {
        let fixture = try FixtureHome()
        let tools = fakeTools([SystemTool.atsutil])
        let engine = fixture.engine(items: [], runner: tools)
        let privileged = FakePrivileged()
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions())

        let operation = await runner.run([OptimizeCatalog.rebuildFontCaches, OptimizeCatalog.flushDNS])

        #expect(privileged.log == [.rebuildFontCaches, .flushDNS])
        #expect(tools.log == [["/usr/bin/atsutil", "databases", "-removeUser"]])
        #expect(operation.failures.isEmpty)
    }

    @Test func failedAdminStepStopsTheTaskBeforeItsUserStep() async throws {
        let fixture = try FixtureHome()
        let tools = fakeTools([SystemTool.atsutil])
        let engine = fixture.engine(items: [], runner: tools)
        let privileged = FakePrivileged { _ in PrivilegedResult(succeeded: false, message: "Password prompt was cancelled") }
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions())

        let operation = await runner.run([OptimizeCatalog.rebuildFontCaches])

        #expect(tools.log.isEmpty)
        #expect(operation.entries.first?.result == .failed)
        #expect(operation.entries.first?.reason == "Password prompt was cancelled")
    }

    @Test func requiredStepFailureIsReportedAndOptionalOneIsNot() async throws {
        let fixture = try FixtureHome()
        let tools = FakeRunner()
        tools.on(SystemTool.lsregister) { arguments in CommandResult(exitCode: arguments == ["-gc"] ? 1 : 0) }
        tools.on(SystemTool.qlmanage) { _ in CommandResult(exitCode: 1, stderr: "qlmanage: no server") }
        let engine = fixture.engine(items: [], runner: tools)
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())

        let operation = await runner.run([OptimizeCatalog.rebuildLaunchServices, OptimizeCatalog.resetQuickLook])

        #expect(operation.entries.map(\.result) == [.removed, .failed])
        #expect(operation.entries[1].reason == "command failed: qlmanage: no server")
        // The first Quick Look step failed, so the second never ran.
        #expect(!tools.ran(["/usr/bin/qlmanage", "-r", "cache"]))
    }

    @Test func runIsRecordedInTheLedger() async throws {
        let fixture = try FixtureHome()
        let tools = fakeTools([SystemTool.qlmanage])
        let engine = fixture.engine(items: [], runner: tools)
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions(SystemConditions(activeVPN: "Work")))

        await runner.run([OptimizeCatalog.resetQuickLook, OptimizeCatalog.flushDNS])

        let recorded = try #require(engine.ledger.operations().first)
        #expect(recorded.kind == .optimize)
        #expect(recorded.source == "window")
        #expect(recorded.entries.map(\.target) == ["Reset Quick Look", "Flush DNS cache"])
        #expect(recorded.entries.map(\.itemID) == ["reset-quick-look", "flush-dns"])
        #expect(recorded.entries.allSatisfy { $0.mode == "command" })
        #expect(recorded.entries.map(\.result) == [.removed, .skipped])
        #expect(engine.ledger.operations().count == 1)
    }

    @Test func eventsFollowTheTasksInOrder() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [], runner: fakeTools([SystemTool.qlmanage, SystemTool.killall]))
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())
        let seen = Locked<[String]>([])

        await runner.run([OptimizeCatalog.resetQuickLook, OptimizeCatalog.restartDock]) { event in
            switch event {
            case .authorizing: seen.mutate { $0.append("authorizing") }
            case .started(let id): seen.mutate { $0.append("start \(id)") }
            case .finished(let id, let outcome): seen.mutate { $0.append("end \(id) \(outcome.status)") }
            }
        }
        #expect(seen.get() == ["start reset-quick-look", "end reset-quick-look done", "start restart-dock", "end restart-dock done"])
    }

    @Test func severalAdminTasksShareOnePasswordPrompt() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let privileged = FakeBatchPrivileged(.passwordPrompt)
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions(SystemConditions(onBattery: true)))
        let authorizing = Locked<[[String]]>([])

        let operation = await runner.run([OptimizeCatalog.flushDNS, OptimizeCatalog.reindexSpotlight, OptimizeCatalog.clearARPCache]) { event in
            if case .authorizing(let ids) = event { authorizing.mutate { $0.append(ids) } }
        }

        // The gated task is left out of the prompt; the other two share it.
        #expect(privileged.batches == [[.flushDNS, .clearARPCache]])
        #expect(privileged.singles.isEmpty)
        #expect(authorizing.get() == [["flush-dns", "clear-arp-cache"]])
        #expect(operation.entries.map(\.result) == [.removed, .skipped, .removed])
    }

    @Test func helperModeRunsAdminTasksOneByOne() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let privileged = FakeBatchPrivileged(.helper)
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions())
        await runner.run([OptimizeCatalog.flushDNS, OptimizeCatalog.clearARPCache])
        #expect(privileged.batches.isEmpty)
        #expect(privileged.singles == [.flushDNS, .clearARPCache])
    }
}

@Suite struct BrokenLaunchAgentTests {
    private func populate(_ fixture: FixtureHome) throws -> String {
        let missing = fixture.path("Applications/Gone.app/Contents/MacOS/gone-agent")
        let present = try fixture.write("bin/still-here")
        try fixture.writeAgent("com.gone.agent.plist", ["Label": "com.gone.agent", "ProgramArguments": [missing, "--daemon"]])
        try fixture.writeAgent("com.gone.program.plist", ["Label": "com.gone.program", "Program": missing])
        try fixture.writeAgent("com.fine.agent.plist", ["Label": "com.fine.agent", "Program": present])
        try fixture.writeAgent("com.apple.fake.plist", ["Label": "com.apple.fake", "Program": missing])
        try fixture.writeAgent("com.sneaky.plist", ["Label": "com.apple.sneaky", "Program": missing])
        try fixture.writeAgent("com.bundle.agent.plist", ["Label": "com.bundle.agent", "BundleProgram": "Contents/MacOS/x"])
        try fixture.writeAgent("com.relative.plist", ["Label": "com.relative", "ProgramArguments": ["some-tool"]])
        try fixture.writeAgent("com.volume.plist", ["Label": "com.volume", "Program": "/Volumes/External/tool"])
        try fixture.write("Library/LaunchAgents/garbage.plist")
        try fixture.write("Library/LaunchAgents/notes.txt")
        // A linked plist, as some package managers install them.
        let target = try fixture.writeAgent("../Elsewhere/com.linked.plist", ["Label": "com.linked", "Program": missing])
        try fixture.symlink("Library/LaunchAgents/com.linked.plist", to: target)
        return missing
    }

    @Test func findsOnlyAgentsWhoseProgramIsCertainlyGone() throws {
        let fixture = try FixtureHome()
        let missing = try populate(fixture)
        let found = BrokenLaunchAgents(engine: fixture.engine(items: [])).find()
        #expect(found.map(\.fileName) == ["com.gone.agent.plist", "com.gone.program.plist"])
        #expect(found.map(\.label) == ["com.gone.agent", "com.gone.program"])
        #expect(found.allSatisfy { $0.program == missing })
        #expect(found.allSatisfy { $0.path.hasPrefix(fixture.path("Library/LaunchAgents/")) })
    }

    @Test func previewListsThemBeforeAnythingMoves() async throws {
        let fixture = try FixtureHome()
        _ = try populate(fixture)
        let engine = fixture.engine(items: [])
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())
        let check = await runner.check(OptimizeCatalog.removeBrokenLaunchAgents)
        #expect(check.isReady)
        #expect(check.preview.map(\.title) == ["com.gone.agent", "com.gone.program"])
        #expect(check.preview.allSatisfy { $0.detail.hasPrefix("Missing ~/Applications/Gone.app") })
        #expect(fixture.exists("Library/LaunchAgents/com.gone.agent.plist"))
    }

    @Test func movesThemToTheTrashAndLeavesTheRest() async throws {
        let fixture = try FixtureHome()
        _ = try populate(fixture)
        let tools = FakeRunner()
        tools.on(SystemTool.launchctl) { _ in CommandResult(exitCode: 0) }
        let engine = fixture.engine(items: [], runner: tools)
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())
        let thesis = try Data(contentsOf: URL(fileURLWithPath: fixture.path("Documents/thesis.txt")))

        let operation = await runner.run([OptimizeCatalog.removeBrokenLaunchAgents])

        #expect(!fixture.exists("Library/LaunchAgents/com.gone.agent.plist"))
        #expect(!fixture.exists("Library/LaunchAgents/com.gone.program.plist"))
        for kept in ["com.fine.agent.plist", "com.apple.fake.plist", "com.sneaky.plist", "com.bundle.agent.plist", "com.relative.plist",
                     "com.volume.plist", "garbage.plist", "notes.txt", "com.linked.plist"] {
            #expect(fixture.exists("Library/LaunchAgents/\(kept)"), "\(kept) should not have been touched")
        }
        #expect(fixture.exists("Library/Elsewhere/com.linked.plist"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path("Documents/thesis.txt"))) == thesis)

        // In the Trash, not deleted.
        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.path(".Trash"))
        #expect(trashed.count == 2)
        #expect(trashed.contains { $0.hasSuffix("com.gone.agent.plist") })

        // launchd is told to forget each one, by label.
        #expect(tools.log == [
            ["/bin/launchctl", "bootout", "gui/\(getuid())/com.gone.agent"],
            ["/bin/launchctl", "bootout", "gui/\(getuid())/com.gone.program"],
        ])

        // Each deletion is its own ledger line, with its path.
        #expect(operation.kind == .optimize)
        #expect(operation.entries.map(\.target) == [
            fixture.path("Library/LaunchAgents/com.gone.agent.plist"), fixture.path("Library/LaunchAgents/com.gone.program.plist"),
        ])
        #expect(operation.entries.allSatisfy { $0.mode == "trash" && $0.result == .removed })
        #expect(engine.ledger.operations().first?.entries.count == 2)
    }

    @Test func agentWhoseProgramCameBackIsLeftAlone() async throws {
        let fixture = try FixtureHome()
        let missing = try populate(fixture)
        let engine = fixture.engine(items: [])
        let finder = BrokenLaunchAgents(engine: engine)
        let found = finder.find()
        // The app is reinstalled between the preview and the run.
        try fixture.write("Applications/Gone.app/Contents/MacOS/gone-agent")
        #expect(FileManager.default.fileExists(atPath: missing))

        let entries = await finder.remove(found)
        #expect(entries.allSatisfy { $0.result == .skipped })
        #expect(fixture.exists("Library/LaunchAgents/com.gone.agent.plist"))
    }

    @Test func appleAgentsAreRefusedEvenWhenHandedInDirectly() async throws {
        let fixture = try FixtureHome()
        let path = try fixture.writeAgent("com.apple.fake.plist", ["Label": "com.apple.fake", "Program": "/nowhere/tool"])
        let engine = fixture.engine(items: [])
        let forged = BrokenLaunchAgent(path: path, label: "com.apple.fake", program: "/nowhere/tool", bytes: 1, fingerprint: try #require(Fingerprint(path: path)))
        let entries = await BrokenLaunchAgents(engine: engine).remove([forged])
        #expect(entries.map(\.result) == [.refused])
        #expect(fixture.exists("Library/LaunchAgents/com.apple.fake.plist"))
    }

    @Test func nothingFoundMeansNothingToDo() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())
        #expect(await runner.check(OptimizeCatalog.removeBrokenLaunchAgents).readiness == .nothingToDo("None found"))
        let operation = await runner.run([OptimizeCatalog.removeBrokenLaunchAgents])
        #expect(operation.entries.map(\.result) == [.skipped])
    }
}

@Suite struct DatabaseVacuumTests {
    private func sqliteTools(freePages: Int = 40, integrity: String = "ok") -> FakeRunner {
        let runner = FakeRunner()
        runner.on(SystemTool.sqlite3) { arguments in
            switch arguments.last {
            case "PRAGMA page_count; PRAGMA freelist_count;": CommandResult(exitCode: 0, stdout: "100\n\(freePages)\n")
            case "PRAGMA integrity_check;": CommandResult(exitCode: 0, stdout: integrity + "\n")
            default: CommandResult(exitCode: 0)
            }
        }
        return runner
    }

    @Test func vacuumsClosedAppsAndSkipsRunningOnes() async throws {
        let fixture = try FixtureHome()
        let mail = try fixture.writeDatabase("Library/Mail/V10/MailData/Envelope Index")
        let safari = try fixture.writeDatabase("Library/Safari/History.db")
        let chrome = try fixture.writeDatabase("Library/Application Support/Google/Chrome/Default/History")
        try fixture.write("Library/Application Support/Google/Chrome/Default/Favicons") // not a database
        let tools = sqliteTools()
        let engine = fixture.engine(items: [], runner: tools, processes: ["Safari"])
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())

        let check = await runner.check(OptimizeCatalog.vacuumDatabases)
        #expect(check.isReady)
        #expect(check.preview.map(\.path) == [mail, safari, chrome])
        #expect(check.preview[1].detail == "Safari is open")

        let operation = await runner.run([OptimizeCatalog.vacuumDatabases])

        var expected: [[String]] = []
        for path in [mail, chrome] {
            expected.append(["/usr/bin/sqlite3", "-batch", "-readonly", path, "PRAGMA page_count; PRAGMA freelist_count;"])
            expected.append(["/usr/bin/sqlite3", "-batch", "-readonly", path, "PRAGMA integrity_check;"])
            expected.append(["/usr/bin/sqlite3", "-batch", path, "VACUUM;"])
        }
        #expect(tools.log == expected)
        #expect(!tools.log.contains { $0.contains(safari) })
        #expect(operation.entries.map(\.result) == [.removed])
        #expect(operation.entries.first?.target == "Compact app databases")
    }

    @Test func everyAppOpenHoldsTheTaskBack() async throws {
        let fixture = try FixtureHome()
        try fixture.writeDatabase("Library/Mail/V10/MailData/Envelope Index")
        try fixture.writeDatabase("Library/Safari/History.db")
        let tools = sqliteTools()
        let engine = fixture.engine(items: [], runner: tools, processes: ["Safari", "Mail"])
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions())

        guard case .blocked(let reason) = await runner.check(OptimizeCatalog.vacuumDatabases).readiness else {
            Issue.record("expected the task to be held back")
            return
        }
        #expect(reason.contains("Mail") && reason.contains("Safari"))
        let operation = await runner.run([OptimizeCatalog.vacuumDatabases])
        #expect(operation.entries.map(\.result) == [.skipped])
        #expect(tools.log.isEmpty)
    }

    @Test func compactOrDamagedDatabasesAreNotRewritten() async throws {
        let fixture = try FixtureHome()
        let mail = try fixture.writeDatabase("Library/Mail/V10/MailData/Envelope Index")

        let compact = sqliteTools(freePages: 2)
        var summary = await DatabaseVacuum(context: .fixture(home: fixture.home, runner: compact)).run()
        #expect(summary.alreadyCompact == 1 && summary.compacted == 0)
        #expect(compact.log == [["/usr/bin/sqlite3", "-batch", "-readonly", mail, "PRAGMA page_count; PRAGMA freelist_count;"]])

        let damaged = sqliteTools(integrity: "*** in database main ***\nPage 7 is never used")
        summary = await DatabaseVacuum(context: .fixture(home: fixture.home, runner: damaged)).run()
        #expect(summary.compacted == 0)
        #expect(summary.skipped == ["Mail Envelope Index did not pass its integrity check"])
        #expect(!damaged.log.contains { $0.last == "VACUUM;" })
    }

    @Test func linksAndNonDatabasesAreNeverCandidates() throws {
        let fixture = try FixtureHome()
        let real = try fixture.writeDatabase("Documents/private.db")
        try fixture.symlink("Library/Safari/History.db", to: real)
        try fixture.write("Library/Mail/V10/MailData/Envelope Index")
        #expect(DatabaseVacuum(context: .fixture(home: fixture.home)).candidates().isEmpty)
    }

    @Test func nothingFoundMeansNothingToDo() async throws {
        let fixture = try FixtureHome()
        let runner = OptimizeRunner(engine: fixture.engine(items: []), privileged: FakePrivileged(), probe: StaticConditions())
        #expect(await runner.check(OptimizeCatalog.vacuumDatabases).readiness == .nothingToDo("No databases found"))
    }
}

@Suite struct NotificationHistoryTests {
    private let databasePath = "Library/Group Containers/group.com.apple.usernoted/db2/db"
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// 30 days before `now`, in seconds since 2001.
    private let cutoff = 800_000_000 - 30 * 86_400

    @Test func prunesThroughSqliteWithAFixedStatement() async throws {
        let fixture = try FixtureHome()
        let database = try fixture.writeDatabase(databasePath)
        let tools = FakeRunner()
        tools.on(SystemTool.sqlite3) { arguments in
            CommandResult(exitCode: 0, stdout: arguments.last?.hasPrefix("SELECT") == true ? "7\n" : "")
        }
        tools.on(SystemTool.killall) { _ in CommandResult(exitCode: 0) }
        let engine = fixture.engine(items: [], runner: tools)
        let fixed = now
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions(), now: { fixed })

        #expect(await runner.check(OptimizeCatalog.pruneNotifications).isReady)
        let operation = await runner.run([OptimizeCatalog.pruneNotifications])

        let filter = "WHERE delivered_date IS NOT NULL AND delivered_date > 0 AND delivered_date < \(cutoff);"
        #expect(tools.log == [
            ["/usr/bin/sqlite3", "-batch", "-readonly", database, "SELECT count(*) FROM record \(filter)"],
            ["/usr/bin/sqlite3", "-batch", database, "DELETE FROM record \(filter)"],
            ["/usr/bin/killall", "NotificationCenter"],
        ])
        #expect(operation.entries.map(\.result) == [.removed])
    }

    @Test func nothingOldMeansNothingIsDeleted() async throws {
        let fixture = try FixtureHome()
        try fixture.writeDatabase(databasePath)
        let tools = FakeRunner()
        tools.on(SystemTool.sqlite3) { _ in CommandResult(exitCode: 0, stdout: "0\n") }
        let outcome = await NotificationHistory(context: .fixture(home: fixture.home, runner: tools)).prune()
        #expect(outcome == .done("Nothing older than 30 days"))
        #expect(tools.log.count == 1)
    }

    @Test func unexpectedTableShapeChangesNothing() async throws {
        let fixture = try FixtureHome()
        try fixture.writeDatabase(databasePath)
        let tools = FakeRunner()
        tools.on(SystemTool.sqlite3) { _ in CommandResult(exitCode: 1, stderr: "Error: no such column: delivered_date") }
        let outcome = await NotificationHistory(context: .fixture(home: fixture.home, runner: tools)).prune()
        #expect(outcome.status == .failed)
        #expect(tools.log.count == 1)
        #expect(!tools.log.contains { $0.last?.hasPrefix("DELETE") == true })
    }

    @Test func missingHistoryIsNothingToDo() async throws {
        let fixture = try FixtureHome()
        let runner = OptimizeRunner(engine: fixture.engine(items: []), privileged: FakePrivileged(), probe: StaticConditions())
        #expect(await runner.check(OptimizeCatalog.pruneNotifications).readiness == .nothingToDo("No history found"))
    }
}
