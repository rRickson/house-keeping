import Foundation
import SweepKit
import SweepTestSupport
import Testing
@testable import SweepOptimize

@Suite struct GateTests {
    @Test func batteryHoldsBackSpotlightReindex() {
        let task = OptimizeCatalog.reindexSpotlight
        #expect(task.gates.contains(.onACPower))
        #expect(task.blockReason(in: SystemConditions(onBattery: true)) == "On battery power")
        #expect(task.blockReason(in: SystemConditions(onBattery: false)) == nil)
    }

    @Test func openBrowserHoldsBackFontCaches() {
        let task = OptimizeCatalog.rebuildFontCaches
        #expect(task.gates.contains(.browsersClosed))
        #expect(task.blockReason(in: SystemConditions(runningBrowsers: ["Safari"])) == "Safari is open")
        let two = task.blockReason(in: SystemConditions(runningBrowsers: ["Safari", "Arc"]))
        #expect(two?.contains("Safari") == true && two?.contains("Arc") == true && two?.hasSuffix("are open") == true)
        #expect(task.blockReason(in: .clear) == nil)
    }

    @Test func vpnHoldsBackNetworkResets() {
        for task in [OptimizeCatalog.flushDNS, OptimizeCatalog.clearARPCache] {
            #expect(task.gates.contains(.vpnInactive))
            #expect(task.blockReason(in: SystemConditions(activeVPN: "Work")) == "VPN is active (Work)")
            #expect(task.blockReason(in: .clear) == nil)
        }
    }

    @Test func gatesDoNotLeakIntoOtherTasks() {
        let everything = SystemConditions(onBattery: true, runningBrowsers: ["Safari"], activeVPN: "utun4")
        for task in [OptimizeCatalog.resetQuickLook, OptimizeCatalog.rebuildLaunchServices, OptimizeCatalog.restartDock] {
            #expect(task.blockReason(in: everything) == nil)
        }
    }

    @Test func readsPowerSource() {
        let battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t81%; discharging; 5:12 remaining present: true\n"
        let wall = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n"
        #expect(PowerSource.isOnBattery(pmsetOutput: battery))
        #expect(!PowerSource.isOnBattery(pmsetOutput: wall))
        #expect(!PowerSource.isOnBattery(pmsetOutput: ""))
    }

    @Test func findsConnectedVPNService() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   11111111-2222-3333-4444-555555555555 PPP --> L2TP       "Old Office"                     [PPP:L2TP]
        * (Connected)      AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE VPN (com.wireguard.macos) "Work Tunnel"             [VPN:com.wireguard.macos]
        """
        #expect(VPNDetector.connectedService(scutilOutput: output) == "Work Tunnel")
        #expect(VPNDetector.connectedService(scutilOutput: "* (Disconnected)   X PPP \"Old Office\" [PPP:L2TP]") == nil)
        #expect(VPNDetector.connectedService(scutilOutput: "") == nil)
    }

    @Test func findsTunnelCarryingDefaultRoute() {
        let plain = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.1.1        UGScg                 en0
        127                127.0.0.1          UCS                   lo0
        192.168.1          link#14            UCS                   en0      !
        """
        #expect(VPNDetector.tunnelInterface(netstatOutput: plain) == nil)

        let fullTunnel = plain + "\ndefault            10.8.0.1           UGScg               utun4\n"
        #expect(VPNDetector.tunnelInterface(netstatOutput: fullTunnel) == "utun4")

        let wireguard = plain + "\n0/1                10.8.0.1           UGScg               utun7\n128.0/1            10.8.0.1           UGScg               utun7\n"
        #expect(VPNDetector.tunnelInterface(netstatOutput: wireguard) == "utun7")

        let ipsec = plain + "\ndefault            link#20            UCSg               ipsec0\n"
        #expect(VPNDetector.tunnelInterface(netstatOutput: ipsec) == "ipsec0")

        // A tunnel interface that only routes its own subnet is not a VPN taking over.
        let split = plain + "\n10.8.0/24          10.8.0.1           UGSc                utun4\n"
        #expect(VPNDetector.tunnelInterface(netstatOutput: split) == nil)
    }

    @Test func recognisesBrowsersByNameBundleAndHelperPath() {
        let processes = [
            RunningProcess(pid: 1, name: "Finder"),
            RunningProcess(pid: 2, name: "Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper"),
            RunningProcess(pid: 3, name: "stub", bundleID: "com.apple.Safari"),
            RunningProcess(pid: 4, name: "firefox"),
        ]
        #expect(Browsers.running(in: processes) == ["Safari", "Chrome", "Firefox"])
        #expect(Browsers.running(in: [RunningProcess(pid: 1, name: "Finder")]).isEmpty)
    }

    @Test func probeReadsEverythingThroughTheContext() async throws {
        let fixture = try FixtureHome()
        let runner = FakeRunner()
        runner.on(SystemTool.pmset) { _ in CommandResult(exitCode: 0, stdout: "Now drawing from 'Battery Power'\n") }
        runner.on(SystemTool.scutil) { _ in CommandResult(exitCode: 0, stdout: "Available network connection services\n") }
        runner.on(SystemTool.netstat) { _ in CommandResult(exitCode: 0, stdout: "default   10.0.0.1   UGScg   utun3\n") }
        let context = SweepContext.fixture(home: fixture.home, runner: runner, processes: StaticProcessList(names: ["Safari"]))

        let conditions = await SystemConditionProbe(context: context).conditions()
        #expect(conditions == SystemConditions(onBattery: true, runningBrowsers: ["Safari"], activeVPN: "utun3"))
        #expect(runner.ran([SystemTool.pmset, "-g", "batt"]))
        #expect(runner.ran([SystemTool.scutil, "--nc", "list"]))
        #expect(runner.ran([SystemTool.netstat, "-rn", "-f", "inet"]))
    }

    @Test func probeThatCannotRunBlocksNothing() async throws {
        let fixture = try FixtureHome()
        let context = SweepContext.fixture(home: fixture.home)
        #expect(await SystemConditionProbe(context: context).conditions() == .clear)
    }

    @Test func gateIsCheckedAgainRightBeforeTheTaskRuns() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let privileged = FakePrivileged()
        let runner = OptimizeRunner(engine: engine, privileged: privileged, probe: StaticConditions(SystemConditions(onBattery: true, activeVPN: "Work")))

        let operation = await runner.run([OptimizeCatalog.flushDNS, OptimizeCatalog.reindexSpotlight])

        #expect(privileged.log.isEmpty)
        #expect(operation.entries.map(\.result) == [.skipped, .skipped])
        #expect(operation.entries.map(\.reason) == ["VPN is active (Work)", "On battery power"])
    }

    @Test func listShowsTheReasonForEveryGatedTask() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let conditions = SystemConditions(onBattery: true, runningBrowsers: ["Firefox"], activeVPN: "utun9")
        let runner = OptimizeRunner(engine: engine, privileged: FakePrivileged(), probe: StaticConditions(conditions))

        let checks = await runner.check()
        #expect(checks[OptimizeCatalog.flushDNS.id]?.readiness == .blocked("VPN is active (utun9)"))
        #expect(checks[OptimizeCatalog.reindexSpotlight.id]?.readiness == .blocked("On battery power"))
        #expect(checks[OptimizeCatalog.rebuildFontCaches.id]?.readiness == .blocked("Firefox is open"))
        #expect(checks[OptimizeCatalog.resetQuickLook.id]?.readiness == .ready)
    }

    @Test func adminTasksAreHeldBackWhenAdminWorkIsUnavailable() async throws {
        let fixture = try FixtureHome()
        let engine = fixture.engine(items: [])
        let runner = OptimizeRunner(engine: engine, privileged: NoPrivilegedRunner(), probe: StaticConditions())
        let checks = await runner.check()
        for task in OptimizeCatalog.all where task.needsAdmin {
            #expect(checks[task.id]?.readiness == .blocked("Admin tasks are not available"))
        }
        #expect(checks[OptimizeCatalog.restartDock.id]?.readiness == .ready)
    }
}
