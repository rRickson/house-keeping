import Carbon.HIToolbox
import SweepDesign
import SweepKit
import SwiftUI

/// One window (⌘,) with the few settings House Keeping has.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CleaningSettings().tabItem { Label("Cleaning", systemImage: "sparkles") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "hammer") }
            ProjectsSettings().tabItem { Label("Projects", systemImage: "folder.badge.gearshape") }
            ExclusionsSettings().tabItem { Label("Exclusions", systemImage: "hand.raised") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show CPU and memory graph", isOn: $model.settings.showMenuBarGraph)
                Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
            }
            Section("Quick clean hotkey") {
                Toggle("Enable global hotkey", isOn: $model.settings.hotkeyEnabled)
                LabeledContent("Shortcut") {
                    HotkeyRecorder(hotkey: $model.settings.hotkey)
                        .disabled(!model.settings.hotkeyEnabled)
                }
            }
            Section("Notifications") {
                LabeledContent("When reclaimable caches exceed") {
                    Stepper(value: gigabytes($model.settings.reclaimableNotifyBytes), in: 1...200) {
                        Text("\(model.settings.reclaimableNotifyBytes / 1_000_000_000) GB").monospacedDigit()
                    }
                }
                LabeledContent("When free disk drops below") {
                    Stepper(value: percent($model.settings.lowDiskNotifyFraction), in: 1...50) {
                        Text("\(Int((model.settings.lowDiskNotifyFraction * 100).rounded()))%").monospacedDigit()
                    }
                }
            }
            Section("Appearance") {
                Picker("Accent colour", selection: $model.settings.accent) {
                    ForEach(SweepAccent.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(accent.color)
                        }
                        .tag(accent.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func gigabytes(_ bytes: Binding<Int64>) -> Binding<Int> {
        Binding(get: { Int(bytes.wrappedValue / 1_000_000_000) }, set: { bytes.wrappedValue = Int64($0) * 1_000_000_000 })
    }

    private func percent(_ fraction: Binding<Double>) -> Binding<Int> {
        Binding(get: { Int((fraction.wrappedValue * 100).rounded()) }, set: { fraction.wrappedValue = Double($0) / 100 })
    }
}

/// Records a key combination while its button has focus.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Type a shortcut…" : hotkey.display) {
            isRecording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // A global shortcut needs at least one of ⌘, ⌥ or ⌃.
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
            var carbon: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

// MARK: Cleaning

private struct CleaningSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: tier(.safe)) { tierLabel(.safe) }
                Toggle(isOn: tier(.caution)) { tierLabel(.caution) }
                LabeledContent {
                    Text("Never").foregroundStyle(.secondary)
                } label: {
                    tierLabel(.ask)
                }
            } header: {
                Text("Tiers included in one-click")
            } footer: {
                Text("The hotkey, schedules and Shortcuts only ever clean the Safe tier.")
            }
            Section("Delete mode") {
                modePicker("Caches", $model.settings.cacheDeleteMode)
                modePicker("Uninstall", $model.settings.uninstallDeleteMode)
                modePicker("Projects", $model.settings.projectDeleteMode)
            }
            Section {
                Picker("Auto-clean", selection: $model.settings.autoClean) {
                    ForEach(AutoCleanSchedule.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.settings.autoClean != .off {
                    Toggle("Paused", isOn: $model.settings.autoCleanPaused)
                    if let last = model.settings.lastAutoClean {
                        LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Daily and low-disk cleans run while House Keeping is open. Weekly also registers a login agent so it runs when House Keeping is closed.")
            }
            Section {
                Stepper("Sessions count as old after \(model.settings.oldSessionDays) day\(model.settings.oldSessionDays == 1 ? "" : "s")",
                        value: $model.settings.oldSessionDays, in: 1...365)
            } header: {
                Text("AI agent sessions")
            } footer: {
                Text("Applies to transcripts, checkpoints and recordings of Claude Code, Codex and other agents. Sessions touched more recently are never offered.")
            }
            Section("uv") {
                Toggle("Clean the whole uv cache instead of pruning unused entries", isOn: $model.settings.uvFullClean)
            }
        }
        .formStyle(.grouped)
    }

    private func tier(_ tier: RiskTier) -> Binding<Bool> {
        Binding(
            get: { model.settings.oneClickTiers.contains(tier) },
            set: { isOn in
                if isOn { model.settings.oneClickTiers.insert(tier) } else { model.settings.oneClickTiers.remove(tier) }
            }
        )
    }

    private func tierLabel(_ tier: RiskTier) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                RiskDot(tier)
                Text(tier.title)
            }
            Text(tier.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modePicker(_ title: String, _ mode: Binding<DeleteMode>) -> some View {
        Picker(title, selection: mode) {
            ForEach(DeleteMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

// MARK: Tools

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(CatalogGroup.allCases, id: \.self) { group in
                let items = model.engine.catalog.items(in: group)
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { item in
                            Toggle(isOn: enabled(item.id)) {
                                HStack(spacing: 6) {
                                    RiskDot(item.risk)
                                    Text(item.name)
                                }
                            }
                        }
                    }
                }
            }
            if !model.engine.catalog.warnings.isEmpty {
                Section("Catalog problems") {
                    ForEach(model.engine.catalog.warnings, id: \.self) { Text($0).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledItems.contains(id) },
            set: { isOn in
                if isOn { model.settings.disabledItems.remove(id) } else { model.settings.disabledItems.insert(id) }
            }
        )
    }
}

// MARK: Projects

private struct ProjectsSettings: View {
    @Environment(AppModel.self) private var model

    private var roots: [String] { model.settings.projectRoots ?? SweepSettings.defaultProjectRoots }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(root)
                        if !FileManager.default.fileExists(atPath: model.context.expand(root)) {
                            Text("not found").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.settings.projectRoots = roots.filter { $0 != root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…") { addFolder() }
                    if model.settings.projectRoots != nil {
                        Button("Restore Defaults") { model.settings.projectRoots = nil }
                    }
                }
            } header: {
                Text("Scan roots")
            } footer: {
                Text("Only folders that exist are scanned.")
            }
            Section("Protection") {
                Stepper("Projects touched in the last \(model.settings.recentProjectDays) days start unticked",
                        value: $model.settings.recentProjectDays, in: 1...60)
                Stepper("\"Purge Stale\" selects projects untouched for \(model.settings.staleProjectDays) days",
                        value: $model.settings.staleProjectDays, in: 7...365)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var updated = roots
        for url in panel.urls {
            let path = model.context.abbreviate(url.path)
            if !updated.contains(path) { updated.append(path) }
        }
        model.settings.projectRoots = updated
    }
}

// MARK: Exclusions

private struct ExclusionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newEntry = ""

    var body: some View {
        Form {
            Section {
                if model.settings.exclusions.isEmpty {
                    Text("Nothing is excluded.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.exclusions, id: \.self) { exclusion in
                    HStack {
                        Image(systemName: exclusion.hasPrefix("/") || exclusion.hasPrefix("~") ? "folder" : "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(exclusion).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            model.settings.exclusions.removeAll { $0 == exclusion }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Never touched")
            } footer: {
                Text("A path excludes itself and everything inside it. A catalog id, such as npm, excludes that tool.")
            }
            Section {
                HStack {
                    TextField("Path or catalog id", text: $newEntry)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose…") { choose() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let entry = newEntry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, !model.settings.exclusions.contains(entry) else { return }
        model.settings.exclusions.append(entry)
        newEntry = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = model.context.abbreviate(url.path)
        if !model.settings.exclusions.contains(path) { model.settings.exclusions.append(path) }
    }
}

// MARK: Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cliMessage: String?
    @State private var cliInstalled = CLIInstaller.isInstalled

    var body: some View {
        Form {
            Section {
                LabeledContent("housekeeping") {
                    HStack {
                        Text(cliInstalled ? "Installed in /usr/local/bin" : "Not installed").foregroundStyle(.secondary)
                        Button(cliInstalled ? "Reinstall" : "Install") {
                            cliMessage = CLIInstaller.install()
                            cliInstalled = CLIInstaller.isInstalled
                        }
                    }
                }
                if let cliMessage {
                    Text(cliMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Command-line tool")
            } footer: {
                Text("`housekeeping scan`, `housekeeping clean --tier safe --dry-run`, `housekeeping purge ~/Projects --older-than 30d`.")
            }
            HelperSettingsSection()
            Section {
                LabeledContent("Custom rules") {
                    Button("Open catalog.d") { openCatalogFolder() }
                }
                LabeledContent("Operation log") {
                    Button("Show in Finder") { Finder.reveal(model.engine.ledger.fileURL.deletingLastPathComponent().path) }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Drop a JSON rule into catalog.d to add a tool without rebuilding House Keeping.")
            }
            Section("About") {
                Text("House Keeping is open source under the MIT licence: no payments, no telemetry, no update server. Cache rules and safety lists are informed by Mole, the MIT-licensed CLI by tw93.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func openCatalogFolder() {
        let folder = model.context.supportDirectory.appendingPathComponent("catalog.d")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        model.engine.reloadCatalog()
    }
}
