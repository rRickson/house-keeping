import SweepDesign
import SweepKit
import SweepUninstall
import SwiftUI

/// The searchable, sortable list of installed apps.
struct AppList: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SearchField(text: $model.search, prompt: "Search apps")
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(UninstallModel.SortKey.allCases) { key in
                            Text(key.rawValue).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .symbolRenderingMode(.hierarchical)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort by \(model.sort.rawValue.lowercased())")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)

            let apps = model.filteredApps
            if apps.isEmpty {
                Group {
                    if model.isLoadingApps {
                        ProgressView().controlSize(.small)
                    } else if model.search.isEmpty {
                        ContentUnavailableView("No apps", systemImage: "square.dashed", description: Text("Nothing removable was found in Applications."))
                    } else {
                        ContentUnavailableView.search(text: model.search)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(apps, selection: $model.selectedAppID) { app in
                    AppRow(app: app, bytes: model.sizes[app.id])
                        .tag(app.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .sweepAnimation(value: model.sort)
            }
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let bytes: Int64?

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PendingSize(bytes: bytes)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let version = app.version { parts.append(version) }
        if app.isRunning {
            parts.append("Open now")
        } else if let opened = app.lastOpened {
            parts.append("Opened \(opened.relativeDescription)")
        } else {
            parts.append("Never opened")
        }
        return parts.joined(separator: " · ")
    }
}

/// A plain rounded search field that sits in content, so it is not glass.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
