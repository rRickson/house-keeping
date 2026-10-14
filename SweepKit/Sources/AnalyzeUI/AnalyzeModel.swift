import AppKit
import Observation
import SweepAnalyze
import SweepDesign
import SweepKit
import SwiftUI

/// State of the Analyze tool: what is being looked at, the scan, and the
/// actions on single items. All disk work happens in `AnalyzeService`.
@MainActor
@Observable
final class AnalyzeModel {
    enum Phase: Equatable {
        /// Nothing scanned yet for the chosen folder.
        case idle
        case scanning
        case ready
    }

    enum ListKind: String, CaseIterable, Identifiable {
        case files, folders, untouched
        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: "Files"
            case .folders: "Folders"
            case .untouched: "Untouched"
            }
        }
    }

    /// One line of feedback after an action, shown under the treemap.
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var bytes: Int64?
        var succeeded: Bool
    }

    let service: AnalyzeService
    var context: SweepContext { service.engine.context }

    /// The folder or volume the next scan reads.
    private(set) var target: URL
    private(set) var phase: Phase = .idle
    private(set) var progress = AnalyzeProgress()
    private(set) var tree: AnalyzeTree?
    /// Changes whenever the tree does, so layouts know to rebuild.
    private(set) var treeVersion = 0
    /// The folder the treemap shows.
    private(set) var focus: AnalyzeTree.NodeID = 0
    private(set) var lists = AnalyzeLists()
    private(set) var volume: VolumeSpace?
    private(set) var retrying: Set<AnalyzeTree.NodeID> = []
    private(set) var failure: String?
    var notice: Notice?
    var listKind: ListKind = .files
    /// Path of the list row that is selected; its tile is outlined in the treemap.
    var selection: String?
    /// The item waiting for the user to confirm the move to the Trash.
    var pendingTrash: AnalyzeItem?

    private var scanTask: Task<Void, Never>?
    private var listsTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var didLoad = false

    init(engine: SweepEngine) {
        service = AnalyzeService(engine: engine)
        target = engine.context.home
    }

    // MARK: Choosing what to look at

    /// Shows the last scan of the chosen folder when it is under a day old. Never starts a scan.
    func load() {
        guard !didLoad else { return }
        didLoad = true
        restore()
    }

    func choose(_ url: URL) {
        scanTask?.cancel()
        target = url.standardizedFileURL
        tree = nil
        treeVersion += 1
        focus = 0
        lists = AnalyzeLists()
        failure = nil
        notice = nil
        phase = .idle
        restore()
    }

    func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = target
        panel.prompt = "Choose"
        panel.message = "Choose a folder or volume to analyze."
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    /// Mounted volumes worth offering in the target menu.
    var volumes: [(name: String, url: URL)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { return nil }
            return (values?.volumeName ?? url.lastPathComponent, url)
        }
    }

    var targetName: String {
        if target.path == context.home.path { return "Home" }
        if target.path == "/" { return volume?.name ?? "Startup Disk" }
        return FileManager.default.displayName(atPath: target.path)
    }

    var targetIsHome: Bool { target.path == context.home.path }

    private func restore() {
        let url = target
        let service = service
        Task {
            // Reading a big cached tree takes a moment; keep it off the main thread.
            async let cached = Task.detached(priority: .userInitiated) { service.cachedTree(for: url) }.value
            async let space = service.volumeSpace(for: url)
            let (tree, volume) = await (cached, space)
            guard url == target else { return }
            self.volume = volume
            if let tree, phase == .idle, self.tree == nil {
                show(tree)
            }
        }
    }

    // MARK: Scanning

    func scan() {
        scanTask?.cancel()
        let url = target
        let service = service
        let hadTree = tree != nil
        progress = AnalyzeProgress()
        failure = nil
        notice = nil
        phase = .scanning
        scanTask = Task { [weak self] in
            do {
                let tree = try await service.scan(url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .scanning else { return }
                        self.progress = progress
                    }
                }
                let volume = await service.volumeSpace(for: url)
                guard let self, !Task.isCancelled, url == self.target else { return }
                self.volume = volume
                self.show(tree)
            } catch is CancellationError {
                guard let self, url == self.target, self.phase == .scanning else { return }
                self.phase = hadTree ? .ready : .idle
            } catch {
                guard let self, url == self.target else { return }
                self.failure = "“\(url.lastPathComponent)” could not be read."
                self.phase = hadTree ? .ready : .idle
                if hadTree { self.post(Notice(text: "“\(url.lastPathComponent)” could not be read again. Showing the earlier scan.", succeeded: false)) }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// Puts a finished scan on screen.
    func show(_ tree: AnalyzeTree) {
        self.tree = tree
        treeVersion += 1
        focus = tree.root
        phase = .ready
        refreshLists()
    }

    /// Reads an unreadable folder again and folds the result into the tree.
    func retry(_ id: AnalyzeTree.NodeID) {
        Task { await performRetry([id]) }
    }

    /// Retries every unreadable folder below the one on screen.
    func retryAllUnreadable() {
        guard let tree else { return }
        let folders = tree.unreadableFolders(under: focus)
        Task { await performRetry(folders) }
    }

    private func performRetry(_ folders: [AnalyzeTree.NodeID]) async {
        var stillUnreadable = 0
        // One at a time: each retry hands back a whole new tree.
        for id in folders {
            guard let tree, tree.isValid(id), tree[id].isUnreadable, !retrying.contains(id) else { continue }
            let version = treeVersion
            retrying.insert(id)
            let updated = try? await service.retry(id, in: tree)
            retrying.remove(id)
            // Only apply it when nothing else changed the tree meanwhile.
            guard let updated, version == treeVersion else { continue }
            self.tree = updated
            treeVersion += 1
            if updated[id].isUnreadable { stillUnreadable += 1 }
        }
        if stillUnreadable > 0 {
            let subject = stillUnreadable == 1 ? "1 folder still cannot" : "\(stillUnreadable) folders still cannot"
            post(Notice(text: "\(subject) be read. House Keeping may need Full Disk Access.", succeeded: false))
        }
        refreshLists()
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Drill-down

    func open(_ id: AnalyzeTree.NodeID) {
        guard let tree, tree.isValid(id), tree[id].isDirectory, !tree[id].isUnreadable, id != focus else { return }
        focus = id
        refreshLists()
    }

    func goUp() {
        guard let tree, let parent = tree.parent(of: focus) else { return }
        open(parent)
    }

    /// Shows the folder that holds `path` in the treemap.
    func showInMap(_ path: String) {
        guard let tree else { return }
        var candidate = (path as NSString).deletingLastPathComponent
        while candidate.count >= tree.rootPath.count {
            if let id = tree.node(atPath: candidate), tree[id].isDirectory {
                selection = path
                if id != focus { open(id) }
                return
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
    }

    /// The tile on screen that holds the selected list row, if any.
    var highlightedTile: AnalyzeTree.NodeID? {
        guard let tree, let selection, tree.isValid(focus) else { return nil }
        let focusPath = tree.path(of: focus)
        let prefix = focusPath == "/" ? "/" : focusPath + "/"
        guard selection.hasPrefix(prefix), let name = selection.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        if let id = tree.children(of: focus).first(where: { tree[$0].kind != .aggregate && tree[$0].name == name }) { return id }
        // A file folded into "N other files".
        return selection.dropFirst(prefix.count).contains("/") ? nil : tree.children(of: focus).first { tree[$0].kind == .aggregate }
    }

    private func refreshLists() {
        listsTask?.cancel()
        guard let tree else {
            lists = AnalyzeLists()
            return
        }
        let scope = focus
        let version = treeVersion
        let cutoff = Date().addingTimeInterval(-365 * 24 * 3600)
        listsTask = Task {
            let lists = await Task.detached(priority: .userInitiated) {
                tree.lists(under: scope, limit: 50, untouchedSince: cutoff)
            }.value
            guard !Task.isCancelled, version == treeVersion, scope == focus else { return }
            self.lists = lists
        }
    }

    // MARK: Item actions

    /// Why the guard would refuse to trash this path; nil when it may go.
    func trashDenyReason(_ path: String) -> String? {
        service.trashDenyReason(for: path)
    }

    func isExcluded(_ path: String) -> Bool {
        service.isExcludedExactly(path)
    }

    func reveal(_ path: String) {
        Finder.reveal(path)
    }

    func toggleExclusion(_ path: String) {
        let name = (path as NSString).lastPathComponent
        if service.isExcludedExactly(path) {
            service.removeExclusion(path)
            post(Notice(text: "“\(name)” is no longer excluded.", succeeded: true))
        } else {
            service.addExclusion(path)
            post(Notice(text: "“\(name)” is now excluded. House Keeping will never remove it.", succeeded: true))
        }
    }

    func requestTrash(_ item: AnalyzeItem) {
        guard trashDenyReason(item.path) == nil else { return }
        pendingTrash = item
    }

    func confirmTrash() {
        guard let item = pendingTrash else { return }
        pendingTrash = nil
        let service = service
        Task {
            let result = await service.trash(item.path)
            if result.succeeded {
                removeFromTree(result.path)
                post(Notice(text: "Moved “\(item.name)” to the Trash", bytes: result.bytes, succeeded: true))
                Haptics.done()
            } else {
                post(Notice(text: "“\(item.name)” was not moved: \(result.reason ?? "unknown reason").", succeeded: false))
            }
        }
    }

    /// Updates sizes in place after a trash, without a rescan.
    private func removeFromTree(_ path: String) {
        guard var tree else { return }
        self.tree = nil // Keep the tree uniquely referenced so the update is in place.
        tree.remove(path: path)
        // If the folder on screen went with it, step out to the nearest folder that is left.
        if tree.node(atPath: tree.path(of: focus)) != focus {
            var candidate = (path as NSString).deletingLastPathComponent
            while tree.node(atPath: candidate) == nil, candidate.count > tree.rootPath.count {
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            focus = tree.node(atPath: candidate) ?? tree.root
        }
        self.tree = tree
        treeVersion += 1
        refreshLists()
        let service = service
        Task.detached(priority: .utility) { service.save(tree) }
    }

    private func post(_ notice: Notice) {
        noticeTask?.cancel()
        self.notice = notice
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self.notice?.id == notice.id else { return }
            self.notice = nil
        }
    }
}
