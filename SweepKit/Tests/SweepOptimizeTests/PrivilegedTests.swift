import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepOptimize

@Suite struct CommandTableTests {
    @Test func everyTaskHasFixedCommands() {
        for task in PrivilegedTask.allCases {
            let commands = PrivilegedCommandTable.commands(for: task)
            #expect(!commands.isEmpty, "\(task) has no entry")
            for command in commands {
                #expect(command.executable.hasPrefix("/"), "\(task): \(command.executable) is not absolute")
                #expect(!command.executable.contains(".."))
                for word in command.argv {
                    #expect(word.allSatisfy { !shellMetacharacters.contains($0) }, "\(task): \(word)")
                }
            }
            // Only the app removal takes anything from outside, and only as a validated path.
            #expect(commands.contains(where: \.takesValidatedPath) == (task == .removeApplication))
            #expect(PrivilegedCommandTable.takesArgument(task) == (task == .removeApplication))
        }
    }

    @Test func tableHoldsTheExpectedCommands() {
        #expect(PrivilegedCommandTable.commands(for: .flushDNS).map(\.argv) == [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
        #expect(PrivilegedCommandTable.commands(for: .reindexSpotlight).map(\.argv) == [["/usr/bin/mdutil", "-E", "/"]])
        #expect(PrivilegedCommandTable.commands(for: .rebuildFontCaches).map(\.argv) == [["/usr/bin/atsutil", "databases", "-remove"]])
        #expect(PrivilegedCommandTable.commands(for: .clearARPCache).map(\.argv) == [["/usr/sbin/arp", "-a", "-d"]])
        #expect(PrivilegedCommandTable.commands(for: .rebuildLaunchServices).first?.argv == [SystemTool.lsregister, "-f", "-all", "system,local"])
        #expect(PrivilegedCommandTable.commands(for: .removeApplication).map(\.argv) == [["/bin/rm", "-rf", "--"]])
        let caches = PrivilegedCommandTable.commands(for: .cleanSystemCaches)[0].argv
        #expect(caches.prefix(2) == ["/usr/bin/find", "/Library/Caches"])
        // Entries only, never the folder; Apple entries and links are left alone.
        #expect(caches.contains("-mindepth") && caches.contains("com.apple.*") && caches.contains("l"))
        #expect(PrivilegedCommandTable.commands(for: .cleanSystemCaches, root: "/tmp/x")[0].argv[1] == "/tmp/x/Library/Caches")
    }

    @Test func helperRunsTableCommandsInOrderWithoutAShell() {
        let executor = RecordingExecutor()
        let runner = PrivilegedTaskRunner(executor: executor)
        #expect(runner.run(taskName: "flushDNS", argument: nil).succeeded)
        #expect(runner.run(.reindexSpotlight, argument: nil).succeeded)
        #expect(executor.log == [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
            ["/usr/bin/mdutil", "-E", "/"],
        ])
    }

    @Test func failedCommandFailsTheTaskAndStopsIt() {
        let executor = RecordingExecutor(exitCode: 1)
        let result = PrivilegedTaskRunner(executor: executor).run(.flushDNS, argument: nil)
        #expect(!result.succeeded)
        #expect(executor.log.count == 1)
    }

    @Test func unknownTaskNamesAreRejected() {
        let executor = RecordingExecutor()
        let runner = PrivilegedTaskRunner(executor: executor)
        for name in ["", "rm -rf /", "flushDNS; reboot", "FlushDNS", "/bin/sh", "flushDNS\n", "../flushDNS"] {
            let result = runner.run(taskName: name, argument: nil)
            #expect(!result.succeeded, "accepted \(name.debugDescription)")
            #expect(result.message == "Unknown task")
        }
        #expect(executor.log.isEmpty)
    }

    @Test func tasksWithoutAnArgumentRefuseOne() {
        let executor = RecordingExecutor()
        let runner = PrivilegedTaskRunner(executor: executor)
        for task in PrivilegedTask.allCases where task != .removeApplication {
            #expect(!runner.run(task, argument: "/etc/passwd").succeeded)
            #expect(!runner.run(taskName: task.rawValue, argument: "; reboot").succeeded)
        }
        #expect(executor.log.isEmpty)
    }
}

@Suite struct BundleIdentifierTests {
    @Test func acceptsReverseDNS() {
        for good in ["com.acme.editor", "org.mozilla.firefox", "com.docker.docker", "io.github.some-user.Tool2", "com.acme"] {
            #expect(BundleIdentifier(good)?.value == good)
        }
    }

    @Test(arguments: [
        "", " ", "../", "..", "../../etc/passwd", "/", "/Applications/Acme.app", "com/acme/app", "com.acme/../x",
        "com..acme", ".com.acme", "com.acme.", "com.acme.my app", "com acme", "com.acme.\"app\"", "com.acme.'app'",
        "com.acme.app;rm", "com.acme.$(id)", "com.acme.`id`", "com.acme.app\n", "com.acme.*", "com.acme.app\0",
        "com.apple.x", "com.apple.Safari", "COM.APPLE.finder", "com.apple", "acme", "-rf.acme.app", "com.-acme.app",
        "com.acmé.app", "com.acme_inc.app", String(repeating: "a.", count: 100) + "b",
    ])
    func rejects(_ raw: String) {
        #expect(BundleIdentifier(raw) == nil, "accepted \(raw.debugDescription)")
    }

    @Test func ownsOnlyNamesOnAComponentBoundary() throws {
        let id = try #require(BundleIdentifier("com.acme.editor"))
        #expect(id.owns("com.acme.editor"))
        #expect(id.owns("com.acme.editor.helper"))
        #expect(!id.owns("com.acme.editorial"))
        #expect(!id.owns("com.acme"))
        #expect(!id.owns("com.other.editor"))
        // A vendor-wide identifier never matches by prefix.
        let vendor = try #require(BundleIdentifier("com.acme"))
        #expect(vendor.owns("com.acme"))
        #expect(!vendor.owns("com.acme.editor"))
    }
}

@Suite struct SystemCachesTests {
    @Test func removesEntriesButNeverTheFolderOrALinkTarget() throws {
        let fixture = try FixtureHome()
        try fixture.writeSystem("Library/Caches/com.vendor.app/blob.bin", bytes: 20_000)
        try fixture.writeSystem("Library/Caches/com.vendor.app/deep/er/more.bin", bytes: 8_000)
        try fixture.writeSystem("Library/Caches/loose.cache", bytes: 5_000)
        try fixture.writeSystem("Library/Caches/com.apple.thing/data.bin", bytes: 5_000)
        try fixture.writeSystem("Library/Caches/com.apple.busy/data.bin", bytes: 5_000)
        try fixture.writeSystem("Library/Caches/com.vendor.busy/data.bin", bytes: 5_000)
        // Two traps: a link at the top level and one inside a folder that is removed.
        let precious = try fixture.write("Documents/precious.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.systemPath("Library/Caches/escape"), withDestinationPath: fixture.path("Documents"))
        try FileManager.default.createSymbolicLink(atPath: fixture.systemPath("Library/Caches/com.vendor.app/inner"), withDestinationPath: fixture.path("Documents"))
        let outside = try fixture.writeSystem("Library/Preferences/keep.plist")

        let runner = PrivilegedTaskRunner(root: fixture.systemRoot, executor: RecordingExecutor(), isInUse: { $0.hasSuffix(".busy") })
        let result = runner.run(taskName: PrivilegedTask.cleanSystemCaches.rawValue, argument: nil)

        #expect(result.succeeded)
        #expect(result.bytesFreed >= 33_000)
        #expect(fixture.systemExists("Library/Caches"))
        #expect(!fixture.systemExists("Library/Caches/com.vendor.app"))
        #expect(!fixture.systemExists("Library/Caches/loose.cache"))
        // Apple's folder is emptied but stays.
        #expect(fixture.systemExists("Library/Caches/com.apple.thing"))
        #expect(!fixture.systemExists("Library/Caches/com.apple.thing/data.bin"))
        // In use: untouched, Apple or not.
        #expect(fixture.systemExists("Library/Caches/com.apple.busy/data.bin"))
        #expect(fixture.systemExists("Library/Caches/com.vendor.busy/data.bin"))
        // The link is still there and nothing behind either link was touched.
        #expect(Fingerprint(path: fixture.systemPath("Library/Caches/escape"))?.isSymlink == true)
        #expect(FileManager.default.fileExists(atPath: precious))
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test func refusesWhenCachesIsItselfALink() throws {
        let fixture = try FixtureHome()
        try fixture.mkdirSystem("Library")
        try FileManager.default.createSymbolicLink(atPath: fixture.systemPath("Library/Caches"), withDestinationPath: fixture.path("Documents"))
        let result = PrivilegedTaskRunner(root: fixture.systemRoot, executor: RecordingExecutor(), isInUse: { _ in false }).cleanSystemCaches()
        #expect(!result.succeeded)
        #expect(fixture.exists("Documents/thesis.txt"))
    }

    @Test func seesFilesHeldOpen() throws {
        let fixture = try FixtureHome()
        let held = try fixture.writeSystem("Library/Caches/com.vendor.open/held.db")
        try fixture.writeSystem("Library/Caches/com.vendor.idle/file.db")
        let handle = try #require(FileHandle(forReadingAtPath: held))
        defer { try? handle.close() }
        // Read the process table directly; `isInUse(_:)` alone reuses a recent reading.
        let open = OpenFiles.openPaths()
        #expect(open.contains(held))
        #expect(OpenFiles.isInUse(fixture.systemPath("Library/Caches/com.vendor.open"), among: open))
        #expect(!OpenFiles.isInUse(fixture.systemPath("Library/Caches/com.vendor.idle"), among: open))
        #expect(!OpenFiles.isInUse(fixture.systemPath("Library/Caches/com.vendor"), among: open))
    }
}

@Suite struct ApplicationRemovalTests {
    private func makeSystem(_ fixture: FixtureHome) throws {
        try fixture.makeApp("Applications/Acme Editor.app", bundleID: "com.acme.editor")
        try fixture.makeApp("Applications/Other.app", bundleID: "com.other.app")
        try fixture.makeApp("Applications/Vendor Suite/Nested.app", bundleID: "com.vendor.nested")
        try fixture.makeApp("Applications/Fake Apple.app", bundleID: "com.apple.Fake")
        try fixture.writeSystem("Library/LaunchDaemons/com.acme.editor.plist")
        try fixture.writeSystem("Library/LaunchDaemons/com.acme.editor.helper.plist")
        try fixture.writeSystem("Library/LaunchDaemons/com.acme.editorial.plist")
        try fixture.writeSystem("Library/LaunchDaemons/com.other.app.plist")
        try fixture.writeSystem("Library/LaunchAgents/com.acme.editor.agent.plist")
        try fixture.writeSystem("Library/LaunchAgents/com.acme.plist")
        try fixture.writeSystem("Library/PrivilegedHelperTools/com.acme.editor.helper")
        try fixture.writeSystem("Library/PrivilegedHelperTools/com.other.app.helper")
    }

    private func runner(_ fixture: FixtureHome, executor: RecordingExecutor = RecordingExecutor(), running: Bool = false) -> PrivilegedTaskRunner {
        PrivilegedTaskRunner(root: fixture.systemRoot, executor: executor, isInUse: { _ in false }, isRunning: { _ in running })
    }

    @Test func removesTheAppAndItsExactlyNamedLeftovers() throws {
        let fixture = try FixtureHome()
        try makeSystem(fixture)
        let executor = RecordingExecutor()

        let result = runner(fixture, executor: executor).run(taskName: "removeApplication", argument: "com.acme.editor")

        #expect(result.succeeded)
        #expect(result.bytesFreed >= 16_384)
        #expect(!fixture.systemExists("Applications/Acme Editor.app"))
        #expect(!fixture.systemExists("Library/LaunchDaemons/com.acme.editor.plist"))
        #expect(!fixture.systemExists("Library/LaunchDaemons/com.acme.editor.helper.plist"))
        #expect(!fixture.systemExists("Library/LaunchAgents/com.acme.editor.agent.plist"))
        #expect(!fixture.systemExists("Library/PrivilegedHelperTools/com.acme.editor.helper"))
        // Neighbours with similar names, and everything else, stay.
        #expect(fixture.systemExists("Library/LaunchDaemons/com.acme.editorial.plist"))
        #expect(fixture.systemExists("Library/LaunchDaemons/com.other.app.plist"))
        #expect(fixture.systemExists("Library/LaunchAgents/com.acme.plist"))
        #expect(fixture.systemExists("Library/PrivilegedHelperTools/com.other.app.helper"))
        #expect(fixture.systemExists("Applications/Other.app/Contents/Info.plist"))
        #expect(fixture.systemExists("Applications/Vendor Suite/Nested.app/Contents/Info.plist"))
        #expect(fixture.systemExists("Applications"))
        // Daemons are stopped by label before their files go.
        #expect(executor.log == [
            ["/bin/launchctl", "bootout", "system/com.acme.editor.helper"],
            ["/bin/launchctl", "bootout", "system/com.acme.editor"],
        ])
    }

    @Test func findsAppsOneFolderDown() throws {
        let fixture = try FixtureHome()
        try makeSystem(fixture)
        #expect(runner(fixture).removeApplication(bundleIdentifier: "com.vendor.nested").succeeded)
        #expect(!fixture.systemExists("Applications/Vendor Suite/Nested.app"))
        #expect(fixture.systemExists("Applications/Vendor Suite"))
    }

    @Test func refusesIdentifiersThatMatchNothing() throws {
        let fixture = try FixtureHome()
        try makeSystem(fixture)
        let before = fixture.files()
        let result = runner(fixture).run(.removeApplication, argument: "com.missing.app")
        #expect(!result.succeeded)
        #expect(fixture.files() == before)
    }

    @Test(arguments: ["com.apple.Fake", "../Applications/Other.app", "/Applications/Other.app", "Other.app", "com.other.app/..", "", "com.other.app ; x"])
    func refusesAppleAndPathLikeArguments(_ argument: String) throws {
        let fixture = try FixtureHome()
        try makeSystem(fixture)
        let before = fixture.files()
        let executor = RecordingExecutor()
        let result = runner(fixture, executor: executor).run(taskName: "removeApplication", argument: argument)
        #expect(!result.succeeded)
        #expect(fixture.files() == before)
        #expect(executor.log.isEmpty)
    }

    @Test func refusesARunningApp() throws {
        let fixture = try FixtureHome()
        try makeSystem(fixture)
        let result = runner(fixture, running: true).removeApplication(bundleIdentifier: "com.acme.editor")
        #expect(!result.succeeded)
        #expect(result.message == "The app is running")
        #expect(fixture.systemExists("Applications/Acme Editor.app"))
        #expect(fixture.systemExists("Library/LaunchDaemons/com.acme.editor.plist"))
    }

    @Test func neverFollowsALinkedAppOrLeftover() throws {
        let fixture = try FixtureHome()
        try fixture.mkdirSystem("Applications")
        // A real bundle outside Applications, linked into it.
        let real = try fixture.makeApp("Elsewhere/Linked.app", bundleID: "com.linked.app")
        try FileManager.default.createSymbolicLink(atPath: fixture.systemPath("Applications/Linked.app"), withDestinationPath: real)
        #expect(!runner(fixture).removeApplication(bundleIdentifier: "com.linked.app").succeeded)
        #expect(fixture.systemExists("Elsewhere/Linked.app/Contents/Info.plist"))

        // A leftover name that is really a link to something precious.
        try fixture.makeApp("Applications/Acme Editor.app", bundleID: "com.acme.editor")
        try fixture.mkdirSystem("Library/LaunchDaemons")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.systemPath("Library/LaunchDaemons/com.acme.editor.plist"), withDestinationPath: fixture.path("Documents/thesis.txt"))
        #expect(runner(fixture).removeApplication(bundleIdentifier: "com.acme.editor").succeeded)
        #expect(fixture.exists("Documents/thesis.txt"))
        #expect(Fingerprint(path: fixture.systemPath("Library/LaunchDaemons/com.acme.editor.plist"))?.isSymlink == true)
    }

    @Test func refusesWhenTwoAppsShareTheIdentifier() throws {
        let fixture = try FixtureHome()
        try fixture.makeApp("Applications/One.app", bundleID: "com.twin.app")
        try fixture.makeApp("Applications/Two.app", bundleID: "com.twin.app")
        #expect(!runner(fixture).removeApplication(bundleIdentifier: "com.twin.app").succeeded)
        #expect(fixture.systemExists("Applications/One.app") && fixture.systemExists("Applications/Two.app"))
    }
}

@Suite struct AdminScriptTests {
    @Test func quotesAwkwardText() {
        #expect(ShellQuote.quote("plain") == "'plain'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("a b;c$(d)`e`") == "'a b;c$(d)`e`'")
        #expect(AdminScript.stringLiteral("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(AdminScript.stringLiteral("back\\slash") == "\"back\\\\slash\"")
        #expect(AdminScript.stringLiteral("'/bin/rm' '-rf' '--' ") == "\"'/bin/rm' '-rf' '--' \"")
    }

    @Test func fixedTasksBecomeOneStatementPerCommand() {
        let script = AdminScript.build([AdminScript.Request(.flushDNS)])
        #expect(script.arguments.isEmpty)
        #expect(script.lines.contains("do shell script \"'/usr/bin/dscacheutil' '-flushcache'\" with administrator privileges"))
        #expect(script.lines.contains("do shell script \"'/usr/bin/killall' '-HUP' 'mDNSResponder'\" with administrator privileges"))
        #expect(script.lines.first == "on run argv" && script.lines.last == "end run")
        #expect(script.osascriptArguments.count == script.lines.count * 2)
        #expect(script.osascriptArguments.first == "-e")
    }

    @Test func awkwardPathsNeverBecomeScriptText() {
        let nasty = [
            "/Applications/My \"Best\" App.app",
            "/Applications/semi;colon $(reboot) `id` 'q' \\ back.app",
            "/Applications/new\nline & pipe | x.app",
        ]
        let script = AdminScript.build([AdminScript.Request(.removeApplication, validatedPaths: nasty)])

        // The paths travel as arguments to osascript, in order, and nowhere else.
        #expect(script.arguments == nasty)
        #expect(Array(script.osascriptArguments.suffix(nasty.count)) == nasty)
        for path in nasty {
            #expect(!script.source.contains(path))
        }
        for fragment in ["My \"Best\"", "reboot", "`id`", "pipe"] {
            #expect(!script.source.contains(fragment))
        }
        // Each reaches the shell only through `quoted form of`.
        for index in 1...nasty.count {
            #expect(script.lines.contains("do shell script \"'/bin/rm' '-rf' '--' \" & quoted form of (item \(index) of argv) with administrator privileges"))
        }
        #expect(script.lines.filter { $0.contains("do shell script") }.count == nasty.count)
    }

    @Test func oneScriptCoversSeveralTasks() {
        let script = AdminScript.build([AdminScript.Request(.flushDNS), AdminScript.Request(.reindexSpotlight), AdminScript.Request(.cleanSystemCaches)])
        #expect(script.lines.filter { $0 == "on run argv" }.count == 1)
        #expect(script.source.contains("'/usr/bin/mdutil' '-E' '/'"))
        #expect(script.source.contains("'/usr/bin/find' '/Library/Caches'"))
        // A cancelled prompt stops the rest instead of asking again.
        #expect(script.lines.contains("if sweepCode is -128 then return sweepReport"))
    }

    @Test func readsTheReport() {
        let tasks: [PrivilegedTask] = [.flushDNS, .reindexSpotlight, .clearARPCache]
        let report = "flushDNS\tok\nreindexSpotlight\terror\t1\tmdutil: could not\nsecond line\n"
        let results = AdminScript.parse(report, tasks: tasks)
        #expect(results[.flushDNS] == PrivilegedResult(succeeded: true))
        #expect(results[.reindexSpotlight] == PrivilegedResult(succeeded: false, message: "mdutil: could not"))
        #expect(results[.clearARPCache] == PrivilegedResult(succeeded: false, message: "Did not run"))
    }

    @Test func cancelledPromptFailsEverythingAfterIt() {
        let results = AdminScript.parse("flushDNS\terror\t-128\tUser canceled.\n", tasks: [.flushDNS, .reindexSpotlight])
        #expect(results[.flushDNS]?.message == "Password prompt was cancelled")
        #expect(results[.reindexSpotlight] == PrivilegedResult(succeeded: false, message: "Password prompt was cancelled"))
    }

    @Test func reportLinesForOtherTasksAreIgnored() {
        let results = AdminScript.parse("removeApplication\tok\nflushDNS\tok\n", tasks: [.flushDNS])
        #expect(results == [.flushDNS: PrivilegedResult(succeeded: true)])
    }
}

@Suite struct CallerVerifierTests {
    @Test func requirementNamesTheAppAndTheTeam() {
        #expect(CodeRequirement.text(identifier: "com.rickson.housekeeping", teamIdentifier: "AB12CD34EF")
            == "identifier \"com.rickson.housekeeping\" and anchor apple generic and certificate leaf[subject.OU] = \"AB12CD34EF\"")
    }

    @Test func oddValuesNeverReachTheRequirement() {
        #expect(CodeRequirement.text(identifier: "com.rickson.housekeeping", teamIdentifier: "X\" or anchor apple") == nil)
        #expect(CodeRequirement.text(identifier: "com.rickson.housekeeping\" or true", teamIdentifier: "AB12CD34EF") == nil)
        #expect(CodeRequirement.text(identifier: "", teamIdentifier: "AB12CD34EF") == nil)
        #expect(CodeRequirement.text(identifier: "com.rickson.housekeeping", teamIdentifier: "") == nil)
    }

    @Test func aHelperWithoutATeamTrustsNobody() {
        #expect(CallerVerifier(teamIdentifier: nil) == nil)
    }

    @Test func aProcessThatIsNotSweepIsRejected() throws {
        // The test runner is neither `com.rickson.housekeeping` nor signed by this team.
        let verifier = try #require(CallerVerifier(teamIdentifier: "AB12CD34EF"))
        #expect(verifier.requirementText.contains("\"com.rickson.housekeeping\""))
        #expect(!verifier.isTrusted(processIdentifier: getpid()))
        #expect(!verifier.isTrusted(processIdentifier: 1))
    }
}
