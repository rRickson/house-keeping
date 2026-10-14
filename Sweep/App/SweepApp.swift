import SweepDesign
import SweepKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        // `Sweep --auto-clean` is how the weekly LaunchAgent runs a clean without any UI.
        if CommandLine.arguments.contains("--auto-clean") {
            Task {
                await AutoClean.runHeadless()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        SweepApp.main()
    }
}

struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .tint(model.accent)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Sweep", id: "main") {
            MainWindow()
                .environment(model)
                .tint(model.accent)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
                .tint(model.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            Snapshotter.run(outputDirectory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-test"), CommandLine.arguments.count > index + 1 {
            AppServices.shared.start()
            UISelfTest.run(logPath: CommandLine.arguments[index + 1])
            return
        }
        #endif
        AppServices.shared.start()
    }

    /// Sweep lives in the menu bar; closing the window does not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
