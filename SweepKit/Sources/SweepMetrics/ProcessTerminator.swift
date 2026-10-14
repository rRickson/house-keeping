import AppKit
import Darwin
import Foundation

/// Who owns a live process and when it started.
public struct ProcessIdentity: Sendable, Equatable {
    public var ownerUID: UInt32
    public var startDate: Date?

    public init(ownerUID: UInt32, startDate: Date? = nil) {
        self.ownerUID = ownerUID
        self.startDate = startDate
    }
}

/// The few things quitting a process needs from the system. Tests supply a fake.
public protocol ProcessControlling: Sendable {
    /// Owner and start date of a live process, or nil when no such process exists.
    func identity(of pid: Int32) -> ProcessIdentity?
    /// Asks an app to quit through AppKit. False when the pid is not an app or the request could not be made.
    func terminateApplication(pid: Int32, force: Bool) -> Bool
    /// Sends a signal. Returns 0 on success, otherwise `errno`.
    func send(signal: Int32, to pid: Int32) -> Int32
}

public struct SystemProcessControl: ProcessControlling {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? { ProcessCollector.identity(of: pid) }

    public func terminateApplication(pid: Int32, force: Bool) -> Bool {
        // Background-only processes have no event loop to hear the request, so they get a signal instead.
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }

    public func send(signal: Int32, to pid: Int32) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }
}

public enum QuitRefusal: Error, Equatable, Sendable, LocalizedError {
    /// pid 0 (the kernel) and pid 1 (launchd).
    case systemProcess
    case sweepItself
    case otherUser
    /// The process ended before it could be asked to quit.
    case notRunning
    /// The pid now belongs to a different process than the one that was listed.
    case replaced
    case failed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .systemProcess: "macOS needs this process to keep running."
        case .sweepItself: "This is House Keeping. Quit it from the menu instead."
        case .otherUser: "This process belongs to another user."
        case .notRunning: "The process has already ended."
        case .replaced: "The process ended and another one took its place."
        case let .failed(code): "The process could not be asked to quit (\(String(cString: strerror(code))))."
        }
    }
}

public enum QuitMethod: Sendable, Equatable {
    /// The app was asked to quit through AppKit, as if the user chose Quit.
    case application
    /// The process was sent this signal.
    case signal(Int32)
}

/// Quits processes the current user owns, and nothing else.
public struct ProcessTerminator: Sendable {
    public let currentUID: UInt32
    public let ownPID: Int32
    private let control: any ProcessControlling

    public init(currentUID: UInt32 = getuid(), ownPID: Int32 = getpid(), control: any ProcessControlling = SystemProcessControl()) {
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.control = control
    }

    /// Why a listed process may not be quit, judged from the listing alone. Nil when it may.
    public func refusal(pid: Int32, ownerUID: UInt32) -> QuitRefusal? {
        if pid <= 1 { return .systemProcess }
        if pid == ownPID { return .sweepItself }
        if ownerUID != currentUID { return .otherUser }
        return nil
    }

    public func refusal(for process: ProcessSample) -> QuitRefusal? {
        refusal(pid: process.pid, ownerUID: process.ownerUID)
    }

    /// Asks a process to quit: apps through AppKit, everything else with SIGTERM.
    /// With `force`, apps are force-terminated and other processes get SIGKILL.
    ///
    /// The owner and start date are read again right before acting, so a pid
    /// that was reused since the list was drawn is never touched.
    @discardableResult
    public func quit(_ process: ProcessSample, force: Bool = false) throws(QuitRefusal) -> QuitMethod {
        if let refusal = refusal(for: process) { throw refusal }
        guard let live = control.identity(of: process.pid) else { throw .notRunning }
        guard live.ownerUID == currentUID else { throw .otherUser }
        if let listed = process.startDate, let current = live.startDate, listed != current { throw .replaced }

        if control.terminateApplication(pid: process.pid, force: force) { return .application }
        let signal = force ? SIGKILL : SIGTERM
        let code = control.send(signal: signal, to: process.pid)
        if code == 0 { return .signal(signal) }
        throw code == ESRCH ? .notRunning : .failed(errno: code)
    }
}
