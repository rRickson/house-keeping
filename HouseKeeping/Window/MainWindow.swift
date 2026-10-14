import SweepDesign
import SweepKit
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, devCaches, projects, clean, uninstall, optimize, analyze, status, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .devCaches: "Dev Caches"
        case .projects: "Projects"
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .optimize: "Optimize"
        case .analyze: "Analyze"
        case .status: "Status"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .devCaches: "hammer"
        case .projects: "folder.badge.gearshape"
        case .clean: "sparkles"
        case .uninstall: "trash"
        case .optimize: "bolt"
        case .analyze: "square.split.2x2"
        case .status: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// The main window: a sidebar with all nine tools. The sidebar and toolbar are
/// glass automatically when built with the macOS 26 SDK.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var section: SidebarSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    row(.overview)
                }
                Section("Developer") {
                    row(.devCaches)
                    row(.projects)
                }
                Section("System") {
                    row(.clean)
                    row(.uninstall)
                    row(.optimize)
                    row(.analyze)
                    row(.status)
                }
                Section {
                    row(.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(minWidth: 680, minHeight: 520)
                .background(Night.backdrop.ignoresSafeArea())
        }
        .navigationTitle(section?.title ?? "House Keeping")
        // The night look is dark whatever the system appearance is.
        .environment(\.colorScheme, .dark)
        .onAppear {
            // A menu bar app has no Dock icon until its window is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            applyRequestedSection()
            model.rescanIfStale()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: model.requestedSection) { applyRequestedSection() }
    }

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .symbolRenderingMode(.hierarchical)
            .tag(section)
    }

    private func applyRequestedSection() {
        guard let requested = model.requestedSection else { return }
        section = requested
        model.requestedSection = nil
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .overview {
        case .overview: OverviewView(open: { section = $0 })
        case .devCaches: DevCachesView()
        case .projects: ProjectsView()
        case .history: HistoryView()
        case .clean, .uninstall, .optimize, .analyze, .status: FeatureHost(section: section ?? .clean)
        }
    }
}
