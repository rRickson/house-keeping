import AppIntents
import SweepKit

/// "Clean dev caches": the one-click clean, Safe tier only.
struct CleanDevCachesIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Dev Caches"
    static let description = IntentDescription("Cleans every Safe-tier developer cache, the same as the menu bar button.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let operation = await AppModel.shared.cleanSafe(source: "shortcut")
        let summary = operation?.summary() ?? "Nothing to clean"
        return .result(value: summary, dialog: "\(summary)")
    }
}

/// "Get reclaimable space": bytes the one-click clean would free.
struct GetReclaimableSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Reclaimable Space"
    static let description = IntentDescription("Returns how much space the Safe-tier developer caches take, in bytes.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let engine = AppModel.shared.engine
        let results = await engine.scanAllCollected()
        let bytes = engine.oneClickSelection(from: results)
            .filter { $0.result.item.risk == .safe }
            .reduce(Int64(0)) { $0 + $1.result.bytes }
        return .result(value: Int(bytes), dialog: "\(ByteFormat.string(bytes)) can be reclaimed")
    }
}

/// "Purge stale projects": build artifacts of projects untouched for the stale period.
struct PurgeStaleProjectsIntent: AppIntent {
    static let title: LocalizedStringResource = "Purge Stale Projects"
    static let description = IntentDescription("Moves the build artifacts of projects untouched for 30 days or more to the Trash.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let engine = AppModel.shared.engine
        let scanner = ProjectScanner(engine: engine)
        let stale = await scanner.scan().filter { $0.isStale(days: engine.settings.staleProjectDays) }
        let artifacts = stale.flatMap(\.artifacts).filter(\.isDeletable)
        guard !artifacts.isEmpty else { return .result(value: "Nothing to purge", dialog: "Nothing to purge") }
        // Shortcuts never deletes permanently, whatever the setting says.
        let operation = await scanner.purge(artifacts, source: "shortcut", mode: .trash)
        AppModel.shared.reloadHistory()
        let summary = operation.summary(noun: "project")
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct SweepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CleanDevCachesIntent(), phrases: ["Clean dev caches with \(.applicationName)"],
                    shortTitle: "Clean Dev Caches", systemImageName: "sparkles")
        AppShortcut(intent: GetReclaimableSpaceIntent(), phrases: ["Get reclaimable space from \(.applicationName)"],
                    shortTitle: "Reclaimable Space", systemImageName: "internaldrive")
        AppShortcut(intent: PurgeStaleProjectsIntent(), phrases: ["Purge stale projects with \(.applicationName)"],
                    shortTitle: "Purge Stale Projects", systemImageName: "folder.badge.gearshape")
    }
}
