import AppKit
import SweepDesign
import SweepKit
import SweepUninstall
import SwiftUI

/// The Uninstall tool of the main window: a list of apps, a review of what
/// removing one takes with it, and a second view for orphaned leftovers.
public struct UninstallView: View {
    @State private var model: UninstallModel

    /// - Parameter dryRun: when true nothing is ever removed; every action reports what it would have done.
    public init(engine: SweepEngine, privileged: any PrivilegedRunning, dryRun: Bool = false) {
        let uninstaller = AppUninstaller(engine: engine, privileged: privileged)
        _model = State(initialValue: UninstallModel(uninstaller: uninstaller, dryRun: dryRun))
    }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ToolHeader("Uninstall", subtitle: model.subtitle) {
                Picker("View", selection: $model.tab) {
                    ForEach(UninstallModel.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Scan again")
                .disabled(model.isLoadingApps || model.isLoadingOrphans || model.isUninstalling)
            }

            switch model.tab {
            case .apps: AppsPane(model: model)
            case .orphans: OrphansPane(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.loadIfNeeded() }
        .onChange(of: model.tab) { model.tabChanged() }
        .sheet(isPresented: $model.isConfirming) {
            UninstallConfirmation(model: model)
        }
    }
}

/// The app list on the left, the review on the right.
struct AppsPane: View {
    @Bindable var model: UninstallModel

    var body: some View {
        HStack(spacing: 0) {
            AppList(model: model)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            Group {
                if let app = model.selectedApp {
                    AppReview(model: model, app: app)
                } else if let report = model.lastReport {
                    UninstallSummary(report: report, model: model)
                } else {
                    ContentUnavailableView(
                        "Choose an app",
                        systemImage: "trash",
                        description: Text("See everything an app leaves behind before any of it is removed."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.selectedAppID) { model.selectionChanged() }
    }
}

/// An app's own icon, read from the bundle by the system.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
private enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// A size once it is known, a quiet spinner until then.
struct PendingSize: View {
    let bytes: Int64?
    var font: Font = .system(.callout, design: .rounded)

    var body: some View {
        if let bytes {
            SizeText(bytes, font: font)
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Measuring")
        }
    }
}
