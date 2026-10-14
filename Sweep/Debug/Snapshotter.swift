#if DEBUG
import AppKit
import SweepDesign
import SweepKit
import SwiftUI

/// `Sweep --snapshot <folder>` renders each screen to a PNG and quits. Used to
/// check layouts without clicking through the app; only in debug builds.
enum Snapshotter {
    static func run(outputDirectory: String) {
        let model = AppModel.shared
        Task {
            model.rescan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            model.scanProjects()
            while model.isScanningProjects { try? await Task.sleep(for: .milliseconds(100)) }
            try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = scheme == .aqua ? "light" : "dark"
                await render(PopoverView(), size: nil, name: "popover-\(suffix)", appearance: scheme, to: outputDirectory)
                await render(OverviewView(open: { _ in }), size: CGSize(width: 860, height: 760), name: "overview-\(suffix)", appearance: scheme, to: outputDirectory)
                await render(DevCachesView(), size: CGSize(width: 860, height: 760), name: "devcaches-\(suffix)", appearance: scheme, to: outputDirectory)
                await render(ProjectsView(), size: CGSize(width: 860, height: 600), name: "projects-\(suffix)", appearance: scheme, to: outputDirectory)
                await render(HistoryView(), size: CGSize(width: 860, height: 600), name: "history-\(suffix)", appearance: scheme, to: outputDirectory)
                for section in [SidebarSection.clean, .uninstall, .optimize, .analyze, .status] {
                    await render(FeatureHost(section: section), size: CGSize(width: 860, height: 640), name: "\(section.rawValue)-\(suffix)", appearance: scheme, to: outputDirectory)
                }
            }
            await render(SettingsView(), size: nil, name: "settings", appearance: .aqua, to: outputDirectory)

            // Mid-scan: some tools measured, some being measured again, some not heard from yet.
            model.debugSimulateScanning(loading: ["pnpm", "pip", "xcode-deriveddata"], unknown: ["bun", "uv", "homebrew", "cocoapods"])
            await render(PopoverView(), size: nil, name: "popover-scanning-light", appearance: .aqua, to: outputDirectory)
            await render(PopoverView(), size: nil, name: "popover-scanning-dark", appearance: .darkAqua, to: outputDirectory)
            model.debugEndSimulatedScan()
            model.rescan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            // Quick erase: one cache being erased, two queued behind it.
            if model.context.isFixture {
                for id in ["electron", "node-gyp", "pip"] {
                    if let result = model.orderedResults.first(where: { $0.id == id }) { model.quickErase(result) }
                }
                await render(PopoverView(), size: nil, name: "popover-quick-erase", appearance: .aqua, to: outputDirectory, settle: 30)
                while model.cleaning != nil || !model.eraseQueue.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(300))
                await render(PopoverView(), size: nil, name: "popover-quick-erase-done", appearance: .aqua, to: outputDirectory, settle: 400)
                try? "quick erase: electron \(model.results["electron"]?.bytes ?? -1), node-gyp \(model.results["node-gyp"]?.bytes ?? -1), pip \(model.results["pip"]?.bytes ?? -1) bytes left"
                    .write(toFile: outputDirectory + "/quick.txt", atomically: true, encoding: .utf8)
            }
            model.rescan()
            while model.isScanning { try? await Task.sleep(for: .milliseconds(100)) }

            // With a fixture home, also walk the clean flow: cleaning, done, and the result in History.
            if model.context.isFixture {
                var log = ["before: checked \(model.checkedResults.count) rows, \(ByteFormat.string(model.checkedBytes))"]
                model.clean(model.quickSelection().selections, source: "menubar")
                await render(PopoverView(), size: nil, name: "flow-1-cleaning", appearance: .aqua, to: outputDirectory, settle: 50)
                while model.cleaning != nil { try? await Task.sleep(for: .milliseconds(50)) }
                await render(PopoverView(), size: nil, name: "flow-2-done", appearance: .aqua, to: outputDirectory, settle: 400)
                log.append("banner: \(model.banner.map { "\(ByteFormat.string($0.bytes)) from \($0.count), \($0.failures) failed" } ?? "none")")
                log.append("after: checked \(model.checkedResults.count) rows, \(ByteFormat.string(model.checkedBytes))")
                let stale = model.projects.filter { $0.isStale(days: model.settings.staleProjectDays) }.flatMap(\.artifacts)
                let purge = await model.purge(stale)
                log.append("purge: \(purge.summary(noun: "project")), \(model.projects.count) projects left")
                await render(ProjectsView(), size: CGSize(width: 860, height: 600), name: "flow-3-projects", appearance: .aqua, to: outputDirectory)
                await render(HistoryView(), size: CGSize(width: 860, height: 600), name: "flow-4-history", appearance: .aqua, to: outputDirectory)
                try? log.joined(separator: "\n").write(toFile: outputDirectory + "/flow.txt", atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize?, name: String, appearance: NSAppearance.Name, to directory: String, settle: Int = 1200) async {
        let model = AppModel.shared
        let root = view
            .environment(model)
            .environment(\.sweepSolidControls, true)
            .tint(model.accent)
            .frame(width: size?.width, height: size?.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? hosting.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setContentSize(size ?? hosting.fittingSize)
        // Kept off screen: the view lays out and draws without ever being shown.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(settle))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}
#endif
