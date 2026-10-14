import Foundation
import os
import SweepKit

/// The helper's XPC front door: checks who is calling, then hands the task
/// name to `PrivilegedTaskRunner`. `HouseKeepingHelper/main.swift` only starts it.
public final class HelperService: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
    private let runner: PrivilegedTaskRunner
    private let verifier: CallerVerifier
    /// One task at a time.
    private let work = DispatchQueue(label: "com.rickson.housekeeping.helper.work")
    /// Open connections plus tasks in flight; the helper exits when this stays at zero.
    private let activity = Locked(0)
    private let idleExitAfter: TimeInterval?
    private let log = Logger(subsystem: HelperConstants.helperIdentifier, category: "helper")

    /// - Parameter idleExitAfter: seconds without a connection before the
    ///   helper exits. launchd starts it again on the next request, so nothing
    ///   of House Keeping's stays running as root in the background.
    public init(runner: PrivilegedTaskRunner = PrivilegedTaskRunner(), verifier: CallerVerifier, idleExitAfter: TimeInterval? = 30) {
        self.runner = runner
        self.verifier = verifier
        self.idleExitAfter = idleExitAfter
    }

    // MARK: NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard verifier.isTrusted(connection) else {
            log.error("Rejected a connection from pid \(connection.processIdentifier, privacy: .public): not House Keeping")
            scheduleIdleCheck()
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = self
        activity.mutate { $0 += 1 }
        let ended: @Sendable () -> Void = { [weak self] in
            self?.activity.mutate { $0 -= 1 }
            self?.scheduleIdleCheck()
        }
        connection.invalidationHandler = ended
        connection.resume()
        return true
    }

    // MARK: HelperXPCProtocol

    public func runTask(_ name: String, argument: String?, reply: @escaping @Sendable (Bool, String, Int64) -> Void) {
        activity.mutate { $0 += 1 }
        work.async { [self] in
            let result = runner.run(taskName: name, argument: argument)
            // The name is only logged once it is known to be one of ours.
            let known = PrivilegedTask(rawValue: name)?.rawValue ?? "unknown"
            log.notice("Task \(known, privacy: .public): \(result.succeeded ? "done" : "failed", privacy: .public)")
            reply(result.succeeded, result.message, result.bytesFreed)
            activity.mutate { $0 -= 1 }
            scheduleIdleCheck()
        }
    }

    public func protocolVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    // MARK: Idle exit

    func scheduleIdleCheck() {
        guard let idleExitAfter else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + idleExitAfter) { [weak self] in
            guard let self, self.activity.get() <= 0 else { return }
            exit(0)
        }
    }
}

/// What `HouseKeepingHelper/main.swift` calls.
public enum HelperMain {
    /// Starts the Mach service and never returns.
    ///
    /// The code-signing requirement is enforced twice: by the system on every
    /// incoming message (`setConnectionCodeSigningRequirement`) and by
    /// `CallerVerifier` when a connection is offered.
    public static func run() -> Never {
        let log = Logger(subsystem: HelperConstants.helperIdentifier, category: "helper")
        guard let verifier = CallerVerifier() else {
            log.error("The helper is not signed by a team, so no caller can be verified. Exiting.")
            exit(EXIT_FAILURE)
        }
        let service = HelperService(verifier: verifier)
        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        listener.setConnectionCodeSigningRequirement(verifier.requirementText)
        listener.delegate = service
        listener.resume()
        service.scheduleIdleCheck()
        withExtendedLifetime((service, listener)) {
            dispatchMain()
        }
    }
}
