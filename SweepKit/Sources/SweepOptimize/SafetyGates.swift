import Foundation
import SweepKit

/// What the machine is doing right now, as far as the gates care.
public struct SystemConditions: Sendable, Equatable {
    public var onBattery: Bool
    /// Display names of the browsers that are open.
    public var runningBrowsers: [String]
    /// The connected VPN service or tunnel interface, if any.
    public var activeVPN: String?

    public init(onBattery: Bool = false, runningBrowsers: [String] = [], activeVPN: String? = nil) {
        self.onBattery = onBattery
        self.runningBrowsers = runningBrowsers
        self.activeVPN = activeVPN
    }

    /// Nothing holds any task back.
    public static let clear = SystemConditions()
}

/// A condition that must hold for a task to run. A gate that fails skips the
/// task with a reason; nothing is ever force-quit or disconnected to pass it.
public enum SafetyGate: String, Sendable, Hashable, CaseIterable {
    /// Reindexing is hours of disk and CPU work; not on battery.
    case onACPower
    /// Browsers hold font caches open and redraw badly when they vanish.
    case browsersClosed
    /// A VPN brings its own resolver and routes; resetting them can drop the tunnel.
    case vpnInactive

    /// Why the gate holds a task back under `conditions`, or nil when it passes.
    public func blockReason(in conditions: SystemConditions) -> String? {
        switch self {
        case .onACPower:
            return conditions.onBattery ? "On battery power" : nil
        case .browsersClosed:
            guard !conditions.runningBrowsers.isEmpty else { return nil }
            let names = ListFormatter.localizedString(byJoining: conditions.runningBrowsers)
            return conditions.runningBrowsers.count == 1 ? "\(names) is open" : "\(names) are open"
        case .vpnInactive:
            guard let vpn = conditions.activeVPN else { return nil }
            return "VPN is active (\(vpn))"
        }
    }
}

extension OptimizeTask {
    /// The first gate that holds this task back, if any.
    public func blockReason(in conditions: SystemConditions) -> String? {
        for gate in gates {
            if let reason = gate.blockReason(in: conditions) { return reason }
        }
        return nil
    }
}

/// Reads the conditions the gates check.
public protocol ConditionProbing: Sendable {
    func conditions() async -> SystemConditions
}

/// A fixed answer, for tests and previews.
public struct StaticConditions: ConditionProbing {
    public var value: SystemConditions
    public init(_ value: SystemConditions = .clear) { self.value = value }
    public func conditions() async -> SystemConditions { value }
}

/// Reads power, browsers and VPN state through the context, so a fixture
/// context never looks at the real machine.
public struct SystemConditionProbe: ConditionProbing {
    private let context: SweepContext
    private let timeout: TimeInterval

    public init(context: SweepContext, timeout: TimeInterval = 5) {
        self.context = context
        self.timeout = timeout
    }

    public func conditions() async -> SystemConditions {
        async let power = context.runner.run([SystemTool.pmset, "-g", "batt"], timeout: timeout)
        async let services = context.runner.run([SystemTool.scutil, "--nc", "list"], timeout: timeout)
        async let routes = context.runner.run([SystemTool.netstat, "-rn", "-f", "inet"], timeout: timeout)
        let (powerResult, serviceResult, routeResult) = await (power, services, routes)

        // A probe that cannot run says nothing; the gate then passes.
        let onBattery = powerResult.succeeded && PowerSource.isOnBattery(pmsetOutput: powerResult.stdout)
        var vpn: String?
        if serviceResult.succeeded { vpn = VPNDetector.connectedService(scutilOutput: serviceResult.stdout) }
        if vpn == nil, routeResult.succeeded { vpn = VPNDetector.tunnelInterface(netstatOutput: routeResult.stdout) }

        return SystemConditions(
            onBattery: onBattery,
            runningBrowsers: Browsers.running(in: context.processes.runningProcesses()),
            activeVPN: vpn
        )
    }
}

public enum PowerSource {
    /// Parses `pmset -g batt`, whose first line reads "Now drawing from 'Battery Power'".
    public static func isOnBattery(pmsetOutput: String) -> Bool {
        guard let line = pmsetOutput.split(whereSeparator: \.isNewline).first(where: { $0.contains("drawing from") }) else {
            return false
        }
        return line.localizedCaseInsensitiveContains("Battery Power")
    }
}

public enum VPNDetector {
    /// The name of the first connected service in `scutil --nc list`.
    public static func connectedService(scutilOutput: String) -> String? {
        for line in scutilOutput.split(whereSeparator: \.isNewline) where line.contains("(Connected)") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 3, !parts[1].isEmpty { return String(parts[1]) }
            return "VPN"
        }
        return nil
    }

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp"]
    /// `0/1` and `128.0/1` are how WireGuard-style clients take over the default route.
    private static let defaultDestinations: Set<String> = ["default", "0/1", "128.0/1", "0.0.0.0/1", "128.0.0.0/1"]

    /// The tunnel interface that carries a default IPv4 route in `netstat -rn -f inet`.
    public static func tunnelInterface(netstatOutput: String) -> String? {
        for line in netstatOutput.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4, defaultDestinations.contains(String(columns[0])) else { continue }
            let interface = String(columns[3])
            if tunnelPrefixes.contains(where: { interface.hasPrefix($0) }) { return interface }
        }
        return nil
    }
}

public enum Browsers {
    /// Display name, then the process patterns that mean it is open.
    public static let known: [(name: String, patterns: [String])] = [
        ("Safari", ["Safari", "com.apple.Safari", "Safari Technology Preview"]),
        ("Chrome", ["Google Chrome", "com.google.Chrome", "Google Chrome Canary"]),
        ("Firefox", ["firefox", "org.mozilla.firefox", "Firefox Developer Edition"]),
        ("Arc", ["Arc", "company.thebrowser.Browser"]),
        ("Brave", ["Brave Browser", "com.brave.Browser"]),
        ("Edge", ["Microsoft Edge", "com.microsoft.edgemac"]),
        ("Opera", ["Opera", "com.operasoftware.Opera"]),
        ("Vivaldi", ["Vivaldi", "com.vivaldi.Vivaldi"]),
        ("Chromium", ["Chromium", "org.chromium.Chromium"]),
        ("Orion", ["Orion", "com.kagi.kagimacOS"]),
        ("Zen", ["zen", "Zen Browser", "app.zen-browser.zen"]),
        ("DuckDuckGo", ["DuckDuckGo", "com.duckduckgo.macos.browser"]),
    ]

    public static func running(in processes: [RunningProcess]) -> [String] {
        known.filter { browser in
            browser.patterns.contains { pattern in processes.contains { $0.matches(pattern) } }
        }.map(\.name)
    }
}
