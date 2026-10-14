import Darwin
import Foundation
import Testing
@testable import SweepMetrics

private func process(_ pid: Int32, _ name: String, cpu: Double? = nil, memory: Int64? = nil, uid: UInt32 = 501, user: String? = "me") -> ProcessSample {
    ProcessSample(pid: pid, name: name, cpuPercent: cpu, residentBytes: memory, ownerUID: uid, ownerName: user)
}

@Suite struct ProcessOrderingTests {
    let list = [
        process(10, "Safari", cpu: 12, memory: 900),
        process(11, "Xcode", cpu: 80, memory: 4000),
        process(12, "kernel_task", uid: 0, user: "root"),
        process(13, "Finder", cpu: 0.5, memory: 300),
        process(14, "node", cpu: 12, memory: 150),
    ]

    @Test func busiestFirstByDefault() {
        let sorted = ProcessOrdering.sorted(list)
        #expect(sorted.map(\.name) == ["Xcode", "Safari", "node", "Finder", "kernel_task"])
    }

    @Test func sortsByMemoryInBothDirections() {
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.memory)).map(\.pid) == [11, 10, 13, 14, 12])
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.memory, ascending: true)).map(\.pid) == [14, 13, 10, 11, 12])
    }

    @Test func unknownValuesStayLastWhicheverWayTheSortRuns() {
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.cpu, ascending: false)).last?.name == "kernel_task")
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.cpu, ascending: true)).last?.name == "kernel_task")
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.cpu, ascending: true)).first?.name == "Finder")
    }

    @Test func equalValuesKeepASteadyOrderByPID() {
        // Safari (10) and node (14) both use 12 %.
        let descending = ProcessOrdering.sorted(list, by: ProcessSort(.cpu)).map(\.pid)
        let ascending = ProcessOrdering.sorted(list, by: ProcessSort(.cpu, ascending: true)).map(\.pid)
        #expect(descending.firstIndex(of: 10)! < descending.firstIndex(of: 14)!)
        #expect(ascending.firstIndex(of: 10)! < ascending.firstIndex(of: 14)!)
        #expect(ProcessOrdering.sorted(list.reversed(), by: ProcessSort(.cpu)).map(\.pid) == descending)
    }

    @Test func pinnedRowsStayOnTop() {
        let sorted = ProcessOrdering.sorted(list, by: ProcessSort(.cpu), pinned: ["Finder", "kernel_task"])
        #expect(sorted.map(\.name) == ["Finder", "kernel_task", "Xcode", "Safari", "node"])
    }

    @Test func pinnedRowsStayOnTopForEverySortAndAreSortedAmongThemselves() {
        let pinned: Set<String> = ["Safari", "node"]
        for key in ProcessSortKey.allCases {
            for ascending in [true, false] {
                let sorted = ProcessOrdering.sorted(list, by: ProcessSort(key, ascending: ascending), pinned: pinned)
                #expect(Set(sorted.prefix(2).map(\.name)) == pinned, "\(key) ascending=\(ascending)")
                #expect(sorted.count == list.count)
            }
        }
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.memory), pinned: pinned).prefix(2).map(\.name) == ["Safari", "node"])
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.memory, ascending: true), pinned: pinned).prefix(2).map(\.name) == ["node", "Safari"])
    }

    @Test func aPinMatchesEveryProcessWithThatName() {
        let helpers = [process(1, "Helper", cpu: 1), process(2, "Other", cpu: 90), process(3, "Helper", cpu: 5)]
        #expect(ProcessOrdering.sorted(helpers, pinned: ["Helper"]).map(\.pid) == [3, 1, 2])
    }

    @Test func sortsByNameAndPIDAndUser() {
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.name, ascending: true)).map(\.name) == ["Finder", "kernel_task", "node", "Safari", "Xcode"])
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.pid, ascending: false)).map(\.pid) == [14, 13, 12, 11, 10])
        #expect(ProcessOrdering.sorted(list, by: ProcessSort(.user, ascending: false)).first?.name == "kernel_task")
    }

    @Test func filtersByNameOwnerOrExactPID() {
        #expect(ProcessOrdering.filtered(list, matching: "saf").map(\.pid) == [10])
        #expect(ProcessOrdering.filtered(list, matching: "root").map(\.pid) == [12])
        #expect(ProcessOrdering.filtered(list, matching: "13").map(\.pid) == [13])
        #expect(ProcessOrdering.filtered(list, matching: "  ").count == list.count)
    }
}

@Suite struct PinnedProcessesTests {
    @Test func togglingPinsAndUnpins() {
        let once = PinnedProcesses.toggling("Xcode", in: [])
        #expect(once == ["Xcode"])
        #expect(PinnedProcesses.toggling("Xcode", in: once).isEmpty)
    }

    @Test func pinsSurviveInUserDefaults() throws {
        let suite = "sweep-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PinnedProcesses.load(from: defaults).isEmpty)
        PinnedProcesses.save(["Xcode", "node"], to: defaults)
        #expect(PinnedProcesses.load(from: defaults) == ["Xcode", "node"])
        #expect(defaults.stringArray(forKey: PinnedProcesses.defaultsKey) == ["Xcode", "node"])
        PinnedProcesses.save([], to: defaults)
        #expect(PinnedProcesses.load(from: defaults).isEmpty)
        #expect(defaults.object(forKey: PinnedProcesses.defaultsKey) == nil)
    }
}

@Suite struct ProcessNamingTests {
    @Test func findsTheBundleThatHoldsAnExecutable() {
        #expect(ProcessNaming.bundlePath(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(ProcessNaming.bundlePath(forExecutable: "/usr/sbin/cfprefsd") == nil)
    }

    @Test func aHelperBelongsToItsOwnInnerBundle() {
        let path = "/Applications/Chrome.app/Contents/Frameworks/Chrome Framework.framework/Helpers/Chrome Helper.app/Contents/MacOS/Chrome Helper"
        #expect(ProcessNaming.bundlePath(forExecutable: path)
            == "/Applications/Chrome.app/Contents/Frameworks/Chrome Framework.framework/Helpers/Chrome Helper.app")
    }

    @Test func namesComeFromThePathThenTheCommandThenThePID() {
        #expect(ProcessNaming.displayName(executablePath: "/usr/libexec/trustd", command: "trustd", pid: 5) == "trustd")
        #expect(ProcessNaming.displayName(executablePath: nil, command: "launchd", pid: 1) == "launchd")
        #expect(ProcessNaming.displayName(executablePath: "", command: "", pid: 0) == "kernel_task")
        #expect(ProcessNaming.displayName(executablePath: nil, command: "", pid: 77) == "pid 77")
    }
}

@Suite struct ProcessTerminatorTests {
    let me: UInt32 = 501
    let ownPID: Int32 = 4242

    private func terminator(_ control: FakeProcessControl) -> ProcessTerminator {
        ProcessTerminator(currentUID: me, ownPID: ownPID, control: control)
    }

    private func mine(_ pid: Int32, name: String = "target", started: Date? = Date(timeIntervalSince1970: 100)) -> ProcessSample {
        ProcessSample(pid: pid, name: name, ownerUID: me, startDate: started)
    }

    private func expectRefusal(_ expected: QuitRefusal, _ process: ProcessSample, force: Bool = false, control: FakeProcessControl) {
        #expect(throws: expected) { try terminator(control).quit(process, force: force) }
    }

    @Test func refusesTheKernelAndLaunchd() {
        let control = FakeProcessControl()
        control.identities = [0: ProcessIdentity(ownerUID: me), 1: ProcessIdentity(ownerUID: me)]
        for pid: Int32 in [-5, 0, 1] {
            expectRefusal(.systemProcess, mine(pid), control: control)
            expectRefusal(.systemProcess, mine(pid), force: true, control: control)
        }
        #expect(control.calls.isEmpty)
    }

    @Test func refusesSweepItself() {
        let control = FakeProcessControl()
        control.identities = [ownPID: ProcessIdentity(ownerUID: me)]
        control.apps = [ownPID]
        expectRefusal(.sweepItself, mine(ownPID), control: control)
        #expect(control.calls.isEmpty)
    }

    @Test func refusesAnotherUsersProcess() {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: 0)]
        let rootOwned = ProcessSample(pid: 300, name: "WindowServer", ownerUID: 0)
        expectRefusal(.otherUser, rootOwned, control: control)
        #expect(terminator(control).refusal(for: rootOwned) == .otherUser)
        #expect(control.calls.isEmpty)
    }

    @Test func refusesWhenTheLiveOwnerIsSomeoneElseEvenIfTheListSaidOtherwise() {
        // The pid was listed as mine, but by now it belongs to a root process.
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: 0, startDate: Date(timeIntervalSince1970: 100))]
        expectRefusal(.otherUser, mine(300), control: control)
        #expect(control.calls.isEmpty)
    }

    @Test func refusesAPIDThatWasReused() {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 999))]
        expectRefusal(.replaced, mine(300, started: Date(timeIntervalSince1970: 100)), control: control)
        #expect(control.calls.isEmpty)
    }

    @Test func reportsAProcessThatAlreadyEnded() {
        let control = FakeProcessControl()
        expectRefusal(.notRunning, mine(300), control: control)
        #expect(control.calls.isEmpty)
    }

    @Test func asksAnAppToQuitThroughAppKit() throws {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100))]
        control.apps = [300]
        #expect(try terminator(control).quit(mine(300)) == .application)
        #expect(control.calls == [.terminate(pid: 300, force: false)])
    }

    @Test func sendsSIGTERMToAProcessThatIsNotAnApp() throws {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100))]
        #expect(try terminator(control).quit(mine(300)) == .signal(SIGTERM))
        #expect(control.calls == [.signal(SIGTERM, pid: 300)])
    }

    @Test func forceUsesSIGKILLOrAForcedAppTermination() throws {
        let control = FakeProcessControl()
        control.identities = [
            300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100)),
            301: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100)),
        ]
        control.apps = [301]
        #expect(try terminator(control).quit(mine(300), force: true) == .signal(SIGKILL))
        #expect(try terminator(control).quit(mine(301), force: true) == .application)
        #expect(control.calls == [.signal(SIGKILL, pid: 300), .terminate(pid: 301, force: true)])
    }

    @Test func aProcessWithNoKnownStartDateIsStillCheckedByOwner() throws {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100))]
        #expect(try terminator(control).quit(mine(300, started: nil)) == .signal(SIGTERM))
    }

    @Test func mapsSignalErrors() {
        let control = FakeProcessControl()
        control.identities = [300: ProcessIdentity(ownerUID: me, startDate: Date(timeIntervalSince1970: 100))]
        control.signalResult = ESRCH
        expectRefusal(.notRunning, mine(300), control: control)
        control.signalResult = EPERM
        expectRefusal(.failed(errno: EPERM), mine(300), control: control)
    }

    @Test func theStaticCheckMatchesTheRules() {
        let terminator = terminator(FakeProcessControl())
        #expect(terminator.refusal(pid: 0, ownerUID: me) == .systemProcess)
        #expect(terminator.refusal(pid: 1, ownerUID: me) == .systemProcess)
        #expect(terminator.refusal(pid: ownPID, ownerUID: me) == .sweepItself)
        #expect(terminator.refusal(pid: 300, ownerUID: 0) == .otherUser)
        #expect(terminator.refusal(pid: 300, ownerUID: me) == nil)
    }

    @Test func everyRefusalExplainsItself() {
        let refusals: [QuitRefusal] = [.systemProcess, .sweepItself, .otherUser, .notRunning, .replaced, .failed(errno: EPERM)]
        for refusal in refusals {
            #expect(!(refusal.errorDescription ?? "").isEmpty)
        }
    }

    @Test func theDefaultTerminatorGuardsThisProcess() {
        // Built with the real uid and pid, never asked to act.
        let terminator = ProcessTerminator(control: FakeProcessControl())
        #expect(terminator.refusal(pid: getpid(), ownerUID: getuid()) == .sweepItself)
        #expect(terminator.currentUID == getuid())
    }
}
