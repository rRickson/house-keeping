import SweepDesign
import SweepKit
import SwiftUI

/// Rebuildable folders inside code directories, per project, oldest first.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// Artifacts the user ticked or unticked by hand, by path.
    @State private var overrides: [String: Bool] = [:]
    @State private var showConfirm = false
    @State private var isPurging = false
    @State private var lastResult: SweepOperation?

    private var settings: SweepSettings { model.settings }

    /// Recent projects start unticked; everything else starts ticked.
    private func isSelected(_ artifact: ProjectArtifact, in project: Project) -> Bool {
        guard artifact.isDeletable else { return false }
        return overrides[artifact.path] ?? !project.isRecent(days: settings.recentProjectDays)
    }

    private var selected: [ProjectArtifact] {
        model.projects.flatMap { project in project.artifacts.filter { isSelected($0, in: project) } }
    }

    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader("Projects", subtitle: subtitle) {
                Button("Purge Stale") { selectStale() }
                    .help("Select everything untouched for \(settings.staleProjectDays) days or more")
                    .disabled(model.projects.isEmpty)
                Button {
                    overrides.removeAll()
                    model.scanProjects()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanningProjects)
            }
            content
        }
        .overlay(alignment: .bottom) {
            if !model.projects.isEmpty {
                FloatingActionBar(
                    selected.isEmpty ? "Nothing selected" : "Purge \(selected.count) folder\(selected.count == 1 ? "" : "s")",
                    bytes: selected.isEmpty ? nil : selectedBytes,
                    systemImage: "trash",
                    isBusy: isPurging,
                    isEnabled: !selected.isEmpty
                ) { showConfirm = true }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $showConfirm) {
            Button(settings.projectDeleteMode == .trash ? "Move to Trash" : "Delete Permanently") { purge() }
        } message: {
            Text(settings.projectDeleteMode == .trash
                 ? "The folders go to the Trash, so a mistake is one drag away from undone. Git is asked again about each folder first."
                 : "The folders are deleted permanently. Git is asked again about each folder first.")
        }
        .onAppear {
            if !model.projectsScanned { model.scanProjects() }
        }
    }

    private var confirmTitle: String {
        "Purge \(selected.count) folder\(selected.count == 1 ? "" : "s") (\(ByteFormat.string(selectedBytes)))?"
    }

    private var subtitle: String {
        if model.isScanningProjects { return "Scanning \(model.context.abbreviate(model.projectScanStatus))" }
        if let lastResult, lastResult.bytesFreed > 0 {
            return "Freed \(ByteFormat.string(lastResult.bytesFreed)) from \(lastResult.cleanedItemNames.count) project\(lastResult.cleanedItemNames.count == 1 ? "" : "s")"
        }
        if model.projects.isEmpty { return "Build artifacts that can be rebuilt" }
        return "\(ByteFormat.string(model.projectsBytes)) in \(model.projects.count) project\(model.projects.count == 1 ? "" : "s"), oldest first"
    }

    @ViewBuilder
    private var content: some View {
        let roots = settings.effectiveProjectRoots(context: model.context)
        if roots.isEmpty {
            ContentUnavailableView {
                Label("No folders to scan", systemImage: "folder.badge.questionmark")
            } description: {
                Text("None of the default code folders exist. Add the folders that hold your projects.")
            } actions: {
                Button("Open Settings") { openSettings() }
            }
        } else if model.projects.isEmpty {
            if model.isScanningProjects {
                ProgressView("Looking for build artifacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing to purge", systemImage: "checkmark.circle",
                                       description: Text("No rebuildable folders were found in \(roots.map(model.context.abbreviate).joined(separator: ", "))."))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.projects) { project in
                        ProjectCard(
                            project: project,
                            isRecent: project.isRecent(days: settings.recentProjectDays),
                            isSelected: { isSelected($0, in: project) },
                            setSelected: { overrides[$0.path] = $1 }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
        }
    }

    /// "Purge stale" selects everything untouched for 30 days or more, and nothing else.
    private func selectStale() {
        for project in model.projects {
            let stale = project.isStale(days: settings.staleProjectDays)
            for artifact in project.artifacts { overrides[artifact.path] = stale && artifact.isDeletable }
        }
    }

    private func purge() {
        let artifacts = selected
        isPurging = true
        Task {
            lastResult = await model.purge(artifacts)
            isPurging = false
        }
    }
}

private struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let isRecent: Bool
    let isSelected: (ProjectArtifact) -> Bool
    let setSelected: (ProjectArtifact, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project.name).font(.headline)
                if isRecent {
                    Text("Recent")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                        .help("Touched in the last \(model.settings.recentProjectDays) days, so it starts unticked")
                }
                Spacer()
                Text("touched \(project.lastTouched.relativeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SizeText(project.bytes, font: .system(.body, design: .rounded).weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(model.context.abbreviate(project.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    Finder.reveal(project.path)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            VStack(spacing: 4) {
                ForEach(project.artifacts) { artifact in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { isSelected(artifact) }, set: { setSelected(artifact, $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!artifact.isDeletable)
                        Text(artifact.relativePath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(artifact.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let modified = artifact.lastModified {
                            Text(modified.relativeDescription).font(.caption).foregroundStyle(.tertiary)
                        }
                        SizeText(artifact.bytes, font: .system(.callout, design: .rounded))
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .contextMenu {
                        Button("Reveal in Finder") { Finder.reveal(artifact.path) }
                    }
                }
            }
            .padding(.top, 2)
        }
        .sweepCard(padding: 14)
    }
}
