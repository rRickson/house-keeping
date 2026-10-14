import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SweepKit
import SwiftUI
import UserNotifications

// MARK: Notifications

enum Notifier {
    /// Asked on the first clean. Does nothing against a fixture home.
    static func requestAuthorizationIfNeeded(context: SweepContext) async {
        guard !context.isFixture else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func post(title: String, body: String, context: SweepContext) {
        guard !context.isFixture else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Threshold notices repeat at most once a day.
    static func postOncePerDay(key: String, title: String, body: String, context: SweepContext) {
        let defaultsKey = "lastNotice.\(key)"
        let last = UserDefaults.standard.double(forKey: defaultsKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: defaultsKey)
        post(title: title, body: body, context: context)
    }
}

// MARK: Launch at login

enum LoginItem {
    static func apply(enabled: Bool, context: SweepContext) {
        guard !context.isFixture else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("House Keeping: login item change failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}

// MARK: Scheduled clean

enum AutoClean {
    static let agentPlist = "com.rickson.housekeeping.autoclean.plist"

    /// The weekly schedule also registers a LaunchAgent, so it runs even when House Keeping is not open.
    static func applyLaunchAgent(schedule: AutoCleanSchedule, context: SweepContext) {
        guard !context.isFixture else { return }
        let agent = SMAppService.agent(plistName: agentPlist)
        do {
            if schedule == .weekly, agent.status != .enabled {
                try agent.register()
            } else if schedule != .weekly, agent.status == .enabled {
                try agent.unregister()
            }
        } catch {
            NSLog("House Keeping: launch agent change failed: \(error.localizedDescription)")
        }
    }

    /// True when the schedule says a clean is due now.
    static func isDue(_ settings: SweepSettings, disk: DiskSpace, now: Date = Date()) -> Bool {
        guard !settings.autoCleanPaused else { return false }
        let last = settings.lastAutoClean ?? .distantPast
        switch settings.autoClean {
        case .off: return false
        case .daily: return now.timeIntervalSince(last) >= 86_400
        case .weekly: return now.timeIntervalSince(last) >= 7 * 86_400
        case .lowDisk: return disk.total > 0 && disk.freeFraction < settings.lowDiskNotifyFraction && now.timeIntervalSince(last) >= 3600
        }
    }

    /// Runs one scheduled clean. Automation only ever touches the Safe tier.
    static func run(model: AppModel) async {
        var settings = model.settings
        settings.lastAutoClean = Date()
        model.settings = settings
        await model.cleanSafe(source: "schedule")
    }

    /// `House Keeping --auto-clean`: clean without showing any UI, then quit.
    static func runHeadless() async {
        let engine = SweepEngine()
        var settings = engine.settings
        guard !settings.autoCleanPaused, settings.autoClean != .off else { return }
        let results = await engine.scanAllCollected()
        let selections = engine.oneClickSelection(from: results).filter { $0.result.item.risk == .safe }
        guard !selections.isEmpty else { return }
        let operation = await engine.clean(selections, source: "schedule")
        settings.lastAutoClean = Date()
        engine.updateSettings(settings)
        if operation.bytesFreed > 0 {
            Notifier.post(title: "House Keeping", body: operation.summary(), context: engine.context)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: Command-line tool

enum CLIInstaller {
    static let linkPath = "/usr/local/bin/housekeeping"

    static var bundledTool: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/housekeeping") }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledTool.path
    }

    /// The command to run by hand when `/usr/local/bin` is not writable.
    static var manualCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(bundledTool.path)' \(linkPath)"
    }

    /// Symlinks the bundled binary into `/usr/local/bin`. Returns an error message on failure.
    static func install() -> String? {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: bundledTool.path) else { return "The bundled housekeeping tool is missing from this build." }
        do {
            try manager.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            if (try? manager.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                try manager.removeItem(atPath: linkPath)
            } else if manager.fileExists(atPath: linkPath) {
                return "\(linkPath) already exists and is not a link made by House Keeping."
            }
            try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledTool.path)
            return nil
        } catch {
            return "Could not write to /usr/local/bin. Run this in Terminal instead:\n\(manualCommand)"
        }
    }
}

// MARK: Global hotkey

/// Carbon delivers the hotkey on the main thread but outside any actor.
private nonisolated func hotkeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in AppServices.shared.hotkeyPressed() }
    return noErr
}

/// Long-lived app plumbing: the hotkey, the right-click menu and the timers.
final class AppServices: NSObject {
    static let shared = AppServices()

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var rightClickMonitor: Any?
    private var housekeeping: Timer?
    private var model: AppModel { .shared }

    func start() {
        installRightClickMenu()
        // System integrations are skipped when House Keeping runs against a fixture home.
        if !model.context.isFixture {
            applyHotkey()
            LoginItem.apply(enabled: model.settings.launchAtLogin, context: model.context)
            AutoClean.applyLaunchAgent(schedule: model.settings.autoClean, context: model.context)
            // One light check an hour: thresholds and the schedule. Nothing runs between ticks.
            housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in AppServices.shared.housekeepingTick() }
            }
        }
        model.applyMenuBarGraph()
        model.rescan()
    }

    private func housekeepingTick() {
        model.refreshDisk()
        if AutoClean.isDue(model.settings, disk: model.disk) {
            Task { await AutoClean.run(model: model) }
        } else if Date().timeIntervalSince(model.lastScan ?? .distantPast) > 6 * 3600 {
            model.rescan()
        }
    }

    // Hotkey

    func applyHotkey() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        guard model.settings.hotkeyEnabled else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, nil, &handlerRef)
        }
        let hotkey = model.settings.hotkey
        let id = EventHotKeyID(signature: OSType(0x5357_5031), id: 1)
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotkeyRef)
    }

    func hotkeyPressed() {
        guard model.cleaning == nil else { return }
        HUDController.shared.show()
        Task {
            await model.cleanSafe(source: "hotkey")
            HUDController.shared.dismiss(after: 2)
        }
    }

    // Right-click menu on the menu bar icon

    private func installRightClickMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let window = event.window, window.className.contains("NSStatusBarWindow"),
                  let view = window.contentView else { return event }
            let menu = self.makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
            return nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Clean Safe Caches Now", #selector(cleanNow), enabled: model.cleaning == nil)
        add("Rescan", #selector(rescan), enabled: !model.isBusy)
        menu.addItem(.separator())
        add("Open House Keeping", #selector(openSweep))
        add(model.settings.autoCleanPaused ? "Resume Auto-Clean" : "Pause Auto-Clean", #selector(togglePause),
            enabled: model.settings.autoClean != .off)
        menu.addItem(.separator())
        add("Quit House Keeping", #selector(quit))
        return menu
    }

    @objc private func cleanNow() { Task { await model.cleanSafe(source: "menubar") } }
    @objc private func rescan() { model.rescan() }
    @objc private func openSweep() { model.openMainWindow?() }
    @objc private func togglePause() { model.settings.autoCleanPaused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: HUD

/// The small glass capsule shown in the middle of the screen when the hotkey cleans.
final class HUDController {
    static let shared = HUDController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel.contentView = NSHostingView(rootView: HUDView().environment(AppModel.shared).tint(AppModel.shared.accent))
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func dismiss(after delay: TimeInterval) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
                Task { @MainActor in panel.orderOut(nil) }
            })
        }
    }
}
