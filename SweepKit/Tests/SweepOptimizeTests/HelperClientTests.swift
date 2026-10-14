import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepOptimize

@Suite struct HelperClientTests {
    /// A runner in which `osascript` exists and answers with `report`.
    private func scripted(_ report: String = "", exitCode: Int32 = 0) -> FakeRunner {
        let runner = FakeRunner()
        runner.on(SystemTool.osascript) { _ in CommandResult(exitCode: exitCode, stdout: report) }
        return runner
    }

    @Test func fixtureModeIsUnavailableAndDoesNothing() async throws {
        let fixture = try FixtureHome()
        let tools = scripted("flushDNS\tok\n")
        let transport = FakeTransport()
        let client = HelperClient(
            context: .fixture(home: fixture.home, runner: tools),
            registration: FakeRegistration(current: .enabled), transport: transport, root: fixture.systemRoot)

        #expect(await client.availability == .unavailable)
        for task in PrivilegedTask.allCases {
            let result = await client.run(task, argument: task == .removeApplication ? "com.acme.editor" : nil)
            #expect(!result.succeeded)
        }
        #expect(await client.run(batch: [.flushDNS, .reindexSpotlight]).values.allSatisfy { !$0.succeeded })
        #expect(tools.log.isEmpty)
        #expect(transport.log.isEmpty)
    }

    @Test func registeredHelperGetsOnlyTheTaskName() async throws {
        let fixture = try FixtureHome()
        let tools = scripted()
        let transport = FakeTransport()
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .enabled), transport: transport, root: fixture.systemRoot)

        #expect(await client.availability == .helper)
        let result = await client.run(.flushDNS, argument: nil)
        #expect(result == PrivilegedResult(succeeded: true, message: "helper"))
        _ = await client.run(.removeApplication, argument: "com.acme.editor")
        #expect(transport.log == [["flushDNS", nil], ["removeApplication", "com.acme.editor"]])
        // No password prompt when the helper answers.
        #expect(tools.log.isEmpty)
    }

    @Test func withoutTheHelperThePasswordPromptRunsTableCommands() async throws {
        let fixture = try FixtureHome()
        let tools = scripted("flushDNS\tok\n")
        let transport = FakeTransport()
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .notRegistered), transport: transport, root: fixture.systemRoot)

        #expect(await client.availability == .passwordPrompt)
        #expect(await client.run(.flushDNS, argument: nil).succeeded)

        #expect(transport.log.isEmpty)
        let call = try #require(tools.log.first)
        #expect(tools.log.count == 1)
        #expect(call.first == "/usr/bin/osascript")
        #expect(Array(call.dropFirst()) == AdminScript.build([AdminScript.Request(.flushDNS)], root: fixture.systemRoot.path).osascriptArguments)
        #expect(call.contains("do shell script \"'/usr/bin/dscacheutil' '-flushcache'\" with administrator privileges"))
    }

    @Test(arguments: [HelperStatus.requiresApproval, .notFound, .notRegistered])
    func helperThatIsNotEnabledIsNeverContacted(_ status: HelperStatus) async throws {
        let fixture = try FixtureHome()
        let transport = FakeTransport()
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: scripted("reindexSpotlight\tok\n")),
            registration: FakeRegistration(current: status), transport: transport, root: fixture.systemRoot)
        #expect(await client.availability == .passwordPrompt)
        #expect(await client.run(.reindexSpotlight, argument: nil).succeeded)
        #expect(transport.log.isEmpty)
    }

    @Test func helperThatDoesNotAnswerFallsBackToThePrompt() async throws {
        let fixture = try FixtureHome()
        let tools = scripted("flushDNS\tok\n")
        // Registered, but nothing answers the version check (as with a signature macOS will not launch).
        let silent = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .enabled), transport: FakeTransport(version: nil), root: fixture.systemRoot)
        #expect(await silent.availability == .passwordPrompt)
        #expect(await silent.run(.flushDNS, argument: nil).succeeded)
        #expect(tools.log.count == 1)

        // Answers the version check, then drops the connection mid-task.
        let dropping = FakeTransport(reply: .unreachable("connection interrupted"))
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .enabled), transport: dropping, root: fixture.systemRoot)
        #expect(await client.run(.flushDNS, argument: nil).succeeded)
        #expect(dropping.log.count == 1)
        #expect(tools.log.count == 2)
    }

    @Test func helperRefusalIsNotRetriedWithThePrompt() async throws {
        let fixture = try FixtureHome()
        let tools = scripted("removeApplication\tok\n")
        let refusing = FakeTransport(reply: .result(PrivilegedResult(succeeded: false, message: "The app is running")))
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .enabled), transport: refusing, root: fixture.systemRoot)
        let result = await client.run(.removeApplication, argument: "com.acme.editor")
        #expect(result == PrivilegedResult(succeeded: false, message: "The app is running"))
        #expect(tools.log.isEmpty)
    }

    @Test(arguments: ["x; rm -rf /", "../../etc", "/Applications/Acme Editor.app", "com.apple.Safari", "$(reboot)", "com.acme.editor' ; '"])
    func hostileArgumentsReachNeitherTheHelperNorAShell(_ argument: String) async throws {
        let fixture = try FixtureHome()
        try fixture.makeApp("Applications/Acme Editor.app", bundleID: "com.acme.editor")
        for status in [HelperStatus.enabled, .notRegistered] {
            let tools = scripted("removeApplication\tok\nflushDNS\tok\n")
            let transport = FakeTransport()
            let client = HelperClient(
                context: fixture.unmarkedContext(runner: tools),
                registration: FakeRegistration(current: status), transport: transport, root: fixture.systemRoot)

            #expect(!(await client.run(.removeApplication, argument: argument)).succeeded)
            // A task that takes no argument refuses one outright.
            #expect(!(await client.run(.flushDNS, argument: argument)).succeeded)
            #expect(tools.log.isEmpty)
            #expect(transport.log.isEmpty)
        }
        #expect(fixture.systemExists("Applications/Acme Editor.app/Contents/Info.plist"))
    }

    @Test func promptRemovalUsesPathsItFoundItself() async throws {
        let fixture = try FixtureHome()
        let app = try fixture.makeApp("Applications/Acme \"Editor\" $HOME.app", bundleID: "com.acme.editor")
        let daemon = try fixture.writeSystem("Library/LaunchDaemons/com.acme.editor.helper.plist")
        try fixture.writeSystem("Library/LaunchDaemons/com.acme.editorial.plist")
        try fixture.makeApp("Applications/Other.app", bundleID: "com.other.app")

        // Stands in for the privileged `rm`: removes exactly what it was handed, inside the fixture.
        let tools = FakeRunner()
        let prefix = fixture.systemRoot.path + "/"
        tools.on(SystemTool.osascript) { arguments in
            for path in arguments where path.hasPrefix(prefix) { try? FileManager.default.removeItem(atPath: path) }
            return CommandResult(exitCode: 0, stdout: "removeApplication\tok\n")
        }
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)

        let result = await client.run(.removeApplication, argument: "com.acme.editor")

        #expect(result.succeeded)
        #expect(result.bytesFreed >= 16_384)
        let call = try #require(tools.log.first)
        // The paths are the last arguments; the script text before them never mentions them.
        #expect(Array(call.suffix(2)) == [app, daemon])
        let scriptText = call.dropLast(2).joined(separator: "\n")
        #expect(!scriptText.contains("Acme") && !scriptText.contains("com.acme.editor"))
        #expect(scriptText.contains("quoted form of (item 1 of argv)") && scriptText.contains("quoted form of (item 2 of argv)"))
        #expect(!fixture.systemExists("Applications/Acme \"Editor\" $HOME.app"))
        #expect(fixture.systemExists("Applications/Other.app"))
        #expect(fixture.systemExists("Library/LaunchDaemons/com.acme.editorial.plist"))
    }

    @Test func promptRemovalReportsAnAppThatIsStillThere() async throws {
        let fixture = try FixtureHome()
        try fixture.makeApp("Applications/Acme Editor.app", bundleID: "com.acme.editor")
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: scripted("removeApplication\tok\n")),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)
        let result = await client.run(.removeApplication, argument: "com.acme.editor")
        #expect(!result.succeeded)

        // An identifier that matches nothing never reaches the prompt.
        let tools = scripted("removeApplication\tok\n")
        let other = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)
        #expect(!(await other.run(.removeApplication, argument: "com.missing.app")).succeeded)
        #expect(tools.log.isEmpty)
    }

    @Test func promptCacheCleanMeasuresWhatWasFreed() async throws {
        let fixture = try FixtureHome()
        let blob = try fixture.writeSystem("Library/Caches/com.vendor.app/blob.bin", bytes: 40_000)
        let tools = FakeRunner()
        tools.on(SystemTool.osascript) { _ in
            try? FileManager.default.removeItem(atPath: blob)
            return CommandResult(exitCode: 0, stdout: "cleanSystemCaches\tok\n")
        }
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)
        let result = await client.run(.cleanSystemCaches, argument: nil)
        #expect(result.succeeded)
        #expect(result.bytesFreed >= 40_000)
        #expect(tools.log.first?.contains { $0.contains("'/usr/bin/find' '\(fixture.systemPath("Library/Caches"))'") } == true)
    }

    @Test func batchAsksOnce() async throws {
        let fixture = try FixtureHome()
        let tools = scripted("flushDNS\tok\nreindexSpotlight\terror\t1\tmdutil failed\n")
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: tools),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)

        let results = await client.run(batch: [.flushDNS, .reindexSpotlight, .flushDNS, .removeApplication])

        #expect(tools.log.count == 1)
        #expect(results[.flushDNS] == PrivilegedResult(succeeded: true))
        #expect(results[.reindexSpotlight] == PrivilegedResult(succeeded: false, message: "mdutil failed"))
        // A batch carries no arguments, so the one task that needs one is refused.
        #expect(results[.removeApplication]?.succeeded == false)
    }

    @Test func cancelledPromptFailsWithAPlainReason() async throws {
        let fixture = try FixtureHome()
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: scripted("flushDNS\terror\t-128\tUser canceled.\n")),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)
        #expect(await client.run(.flushDNS, argument: nil) == PrivilegedResult(succeeded: false, message: "Password prompt was cancelled"))
    }

    @Test func noOsascriptMeansUnavailable() async throws {
        let fixture = try FixtureHome()
        let client = HelperClient(
            context: fixture.unmarkedContext(runner: FakeRunner()),
            registration: FakeRegistration(current: .notRegistered), transport: FakeTransport(), root: fixture.systemRoot)
        #expect(await client.availability == .unavailable)
        #expect(!(await client.run(.flushDNS, argument: nil)).succeeded)
    }
}

@Suite struct HelperBundleTests {
    @Test func namesAgree() {
        #expect(HelperConstants.appIdentifier == "com.rickson.sweep")
        #expect(HelperConstants.machServiceName == "com.rickson.sweep.helper")
        #expect(HelperConstants.daemonPlistName == "com.rickson.sweep.helper.plist")
    }

    /// The launchd property list that ships next to the helper's sources.
    @Test func launchdPlistMatchesTheConstants() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Launchd/\(HelperConstants.daemonPlistName)")
        let data = try Data(contentsOf: plist)
        let values = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(values["Label"] as? String == HelperConstants.helperIdentifier)
        #expect(values["BundleProgram"] as? String == "Contents/MacOS/SweepHelper")
        #expect((values["MachServices"] as? [String: Any])?[HelperConstants.machServiceName] as? Bool == true)
        #expect(values["AssociatedBundleIdentifiers"] as? [String] == [HelperConstants.appIdentifier])
        // On demand only: nothing keeps a root process alive in the background.
        #expect(values["KeepAlive"] == nil && values["RunAtLoad"] == nil)
        #expect(values["Program"] == nil && values["ProgramArguments"] == nil)
    }
}
