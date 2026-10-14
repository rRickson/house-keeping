import OptimizeUI
import SweepJunk
import SweepKit
import SwiftUI

/// The admin helper and Full Disk Access.
struct HelperSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var diskAccess = FullDiskAccess.Status.unknown

    var body: some View {
        Section {
            HelperSettingsView(client: model.privileged)
        } header: {
            Text("Admin helper")
        } footer: {
            Text("Used for flushing DNS, system caches, Spotlight and root-owned apps. Without it, macOS asks for your password each time.")
        }
        Section {
            LabeledContent("Full Disk Access") {
                HStack {
                    Text(diskAccess == .granted ? "Granted" : "Not granted").foregroundStyle(.secondary)
                    Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Optional. Needed for Safari, Mail, iOS backups and some app containers.")
        }
        .onAppear { diskAccess = FullDiskAccess.status(context: model.context) }
    }
}
