#if DEBUG
import AppKit
import SweepKit
import SwiftUI

/// `House Keeping --ui-test <file>` checks window plumbing that snapshots cannot and
/// writes what it saw to a log: the status item's content, opening the main
/// window on a requested section, and the Dock-icon switch. Only in debug builds.
///
/// It cannot click the menu bar item: macOS hosts status items outside the
/// app's process, so the popover itself has to be tried by hand.
enum UISelfTest {
    static func run(logPath: String) {
        let model = AppModel.shared
        var log: [String] = []
        func note(_ line: String) { log.append(line) }

        Task {
            model.rescan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            note("scan: \(model.orderedResults.count) results, \(ByteFormat.string(model.reclaimableBytes)) reclaimable")

            let statusWindow = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") }
            let button = statusWindow?.contentView.flatMap(findButton)
            note("status item: title '\(button?.title ?? "")', image \(button?.image != nil)")

            note("openMainWindow set: \(model.openMainWindow != nil)")
            model.requestedSection = .projects
            model.openMainWindow?()
            try? await Task.sleep(for: .milliseconds(1200))
            let main = NSApp.windows.first { !$0.className.contains("NSStatusBarWindow") && $0.isVisible }
            note("main window: '\(main?.title ?? "none")' \(Int(main?.frame.width ?? 0))x\(Int(main?.frame.height ?? 0)), Dock icon \(NSApp.activationPolicy() == .regular)")
            main?.close()
            try? await Task.sleep(for: .milliseconds(600))
            note("after closing: Dock icon \(NSApp.activationPolicy() == .regular)")

            try? log.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func findButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let found = findButton(subview) { return found }
        }
        return nil
    }
}
#endif
