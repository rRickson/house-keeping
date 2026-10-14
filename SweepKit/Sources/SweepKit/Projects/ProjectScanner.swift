import Foundation

/// Finds rebuildable folders inside code directories and purges them per project.
///
/// A folder is only a candidate when its marker file sits next to it and git
/// does not track it. Symlinked folders are never candidates.
public struct ProjectScanner: Sendable {
    public let engine: SweepEngine
    public var maxDepth = 8

    public init(engine: SweepEngine) {
        self.engine = engine
    }

    private var context: SweepContext { engine.context }

    // MARK: Scan

    /// Scans the given roots (the Settings roots when nil). Projects come back oldest first.
    public func scan(roots: [String]? = nil, onProgress: (@Sendable (String) -> Void)? = nil) async -> [Project] {
        let roots = (roots ?? engine.settings.effectiveProjectRoots(context: context)).compactMap { SafetyGuard.realpath($0) }
        let settings = engine.settings
        let context = self.context
        let depth = maxDepth

        let found = await Task.detached(priority: .utility) { () -> Walker in
            let walker = Walker(maxDepth: depth, isExcluded: { settings.isExcluded(path: $0, context: context) }, onProgress: onProgress)
            for root in roots { walker.walk(root, depth: 0, project: nil) }
            return walker
        }.value
        if Task.isCancelled { return [] }

        // Group candidates by project and ask git about each group.
        var byProject: [String: [Walker.Candidate]] = [:]
        for candidate in found.candidates { byProject[candidate.project, default: []].append(candidate) }

        var projects: [String: Project] = [:]
        for (path, info) in found.projects {
            projects[path] = Project(
                path: path,
                name: (path as NSString).lastPathComponent,
                artifacts: [],
                lastTouched: Date(timeIntervalSince1970: info.lastTouched),
                isGitRepository: info.isGit
            )
        }

        await withTaskGroup(of: (String, [ProjectArtifact]).self) { group in
            var pending = byProject.makeIterator()
            func addNext() {
                guard let (path, candidates) = pending.next() else { return }
                let isGit = found.projects[path]?.isGit ?? false
                group.addTask { (path, await self.artifacts(for: candidates, project: path, isGit: isGit)) }
            }
            for _ in 0..<4 { addNext() }
            while let (path, artifacts) = await group.next() {
                projects[path]?.artifacts = artifacts
                addNext()
            }
        }

        await attachDerivedData(to: &projects)

        return projects.values
            .filter { !$0.artifacts.isEmpty }
            .map { project in
                var project = project
                project.artifacts.sort { $0.bytes > $1.bytes }
                return project
            }
            .sorted { $0.lastTouched < $1.lastTouched }
    }

    /// Applies the git rules to a project's candidates and sizes the survivors.
    private func artifacts(for candidates: [Walker.Candidate], project: String, isGit: Bool) async -> [ProjectArtifact] {
        var states: [String: GitState] = [:]
        if isGit {
            guard let gitStates = await gitStates(of: candidates.map(\.path), project: project) else {
                // Without git there is no way to prove nothing is tracked.
                return []
            }
            states = gitStates
        }

        var result: [ProjectArtifact] = []
        for candidate in candidates {
            let state = isGit ? (states[candidate.path] ?? .untracked) : .noRepository
            if state == .tracked { continue }
            if candidate.requiresIgnore, state != .ignored { continue }
            guard let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: candidate.path)]) else { continue }
            result.append(ProjectArtifact(
                path: candidate.path,
                projectPath: project,
                relativePath: Self.relative(candidate.path, to: project),
                kind: candidate.kind,
                bytes: size.bytes,
                lastModified: size.lastModified,
                git: state,
                fingerprint: Fingerprint(path: candidate.path),
                requiresIgnore: candidate.requiresIgnore,
                isDerivedData: false
            ))
        }
        return result
    }

    /// Asks git which of the paths hold tracked files and which are ignored.
    /// Returns nil when git cannot be run.
    func gitStates(of paths: [String], project: String) async -> [String: GitState]? {
        guard context.runner.locate("git") != nil else { return nil }
        var states: [String: GitState] = [:]
        let relatives = paths.map { Self.relative($0, to: project) }
        for chunk in stride(from: 0, to: relatives.count, by: 100).map({ Array(relatives[$0..<min($0 + 100, relatives.count)]) }) {
            let tracked = await context.runner.run("git", ["-C", project, "ls-files", "-z", "--"] + chunk, timeout: 30)
            guard tracked.succeeded else { return nil }
            let trackedFiles = tracked.stdout.split(separator: "\0").map(String.init)
            let ignored = await context.runner.run(
                "git", ["-C", project, "-c", "core.quotePath=false", "check-ignore", "--"] + chunk, timeout: 30)
            // Exit 1 means "none ignored"; anything else is an error.
            guard ignored.launched, !ignored.timedOut, ignored.exitCode == 0 || ignored.exitCode == 1 else { return nil }
            // A path git had to quote will not match, which errs on the side of keeping the folder.
            let ignoredPaths = Set(ignored.stdout.split(whereSeparator: \.isNewline).map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) })
            for relative in chunk {
                let path = project + "/" + relative
                if trackedFiles.contains(where: { $0 == relative || $0.hasPrefix(relative + "/") }) {
                    states[path] = .tracked
                } else if ignoredPaths.contains(relative) {
                    states[path] = .ignored
                } else {
                    states[path] = .untracked
                }
            }
        }
        return states
    }

    /// Adds each Xcode DerivedData folder to the project its workspace lives in.
    private func attachDerivedData(to projects: inout [String: Project]) async {
        let derivedData = context.home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: derivedData) else { return }
        for folder in folders {
            let path = derivedData + "/" + folder
            guard let info = NSDictionary(contentsOfFile: path + "/info.plist"),
                  let workspace = info["WorkspacePath"] as? String else { continue }
            let real = SafetyGuard.realpath(workspace) ?? workspace
            // The deepest project that contains the workspace.
            let owner = projects.keys
                .filter { SafetyGuard.isInside(real, $0) }
                .max { $0.count < $1.count }
            guard let owner, let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: path)]) else { continue }
            projects[owner]?.artifacts.append(ProjectArtifact(
                path: path,
                projectPath: owner,
                relativePath: "DerivedData/\(folder)",
                kind: "Xcode DerivedData",
                bytes: size.bytes,
                lastModified: size.lastModified,
                git: .noRepository,
                fingerprint: Fingerprint(path: path),
                requiresIgnore: false,
                isDerivedData: true
            ))
        }
    }

    static func relative(_ path: String, to project: String) -> String {
        path.hasPrefix(project + "/") ? String(path.dropFirst(project.count + 1)) : path
    }

    // MARK: Purge

    /// Deletes artifacts, re-checking git and the guard for each one first.
    @discardableResult
    public func purge(
        _ artifacts: [ProjectArtifact],
        source: String,
        mode: DeleteMode? = nil,
        dryRun: Bool = false,
        onEvent: (@Sendable (CleanEvent) -> Void)? = nil
    ) async -> SweepOperation {
        let mode = mode ?? engine.settings.projectDeleteMode
        var operation = SweepOperation(kind: .projects, source: source, dryRun: dryRun)
        for artifact in artifacts {
            if Task.isCancelled { break }
            onEvent?(.started(itemID: artifact.id))
            let entry = await purge(artifact, mode: mode, dryRun: dryRun)
            operation.entries.append(entry)
            let freed = entry.result == .removed || entry.result == .dryRun ? entry.bytes : 0
            onEvent?(.finished(itemID: artifact.id, bytesFreed: freed, entries: [entry]))
        }
        engine.ledger.append(operation)
        return operation
    }

    private func purge(_ artifact: ProjectArtifact, mode: DeleteMode, dryRun: Bool) async -> OperationEntry {
        let name = (artifact.projectPath as NSString).lastPathComponent
        func entry(_ bytes: Int64, _ result: OperationEntry.Result, _ reason: String? = nil) -> OperationEntry {
            OperationEntry(itemID: artifact.projectPath, itemName: name, target: artifact.path, bytes: bytes, mode: mode.rawValue, result: result, reason: reason)
        }
        if engine.settings.isExcluded(path: artifact.path, context: context) {
            return entry(0, .skipped, "Excluded in Settings")
        }

        let allowedRoot: String
        let scope: SafetyGuard.Scope
        if artifact.isDerivedData {
            if context.processes.firstRunning(of: ["Xcode", "com.apple.dt.Xcode"]) != nil {
                return entry(0, .skipped, "Xcode is running")
            }
            allowedRoot = (artifact.path as NSString).deletingLastPathComponent
            scope = .cache
        } else {
            allowedRoot = artifact.projectPath
            scope = .projectArtifact
            // Anything git tracks is never deleted. Asked again now, not at scan time.
            if FileManager.default.fileExists(atPath: artifact.projectPath + "/.git") {
                guard let states = await gitStates(of: [artifact.path], project: artifact.projectPath) else {
                    return entry(0, .skipped, "git is not available to confirm nothing is tracked")
                }
                let state = states[artifact.path] ?? .untracked
                if state == .tracked { return entry(0, .refused, "git tracks files in this folder") }
                if artifact.requiresIgnore, state != .ignored { return entry(0, .refused, "not ignored by git") }
            } else if artifact.requiresIgnore {
                return entry(0, .refused, "not ignored by git")
            }
        }
        guard let realRoot = SafetyGuard.realpath(allowedRoot) else { return entry(0, .skipped, "already gone") }

        let remover = engine.remover
        let outcome = await Task.detached(priority: .utility) {
            remover.remove(artifact.path, allowedRoots: [realRoot], scope: scope, fingerprint: artifact.fingerprint, mode: mode, dryRun: dryRun)
        }.value
        switch outcome {
        case .removed(let bytes): return entry(bytes, .removed)
        case .dryRun(let bytes): return entry(bytes, .dryRun)
        case .skipped(let reason): return entry(0, .skipped, reason)
        case .refused(let reason): return entry(0, .refused, reason)
        case .failed(let reason, let freed): return entry(freed, .failed, reason)
        }
    }
}

/// Walks a scan root once, collecting projects and artifact candidates.
final class Walker: @unchecked Sendable {
    struct Candidate {
        var path: String
        var kind: String
        var project: String
        var requiresIgnore: Bool
    }

    struct ProjectInfo {
        var isGit: Bool
        var lastTouched: TimeInterval
    }

    private let maxDepth: Int
    private let isExcluded: (String) -> Bool
    private let onProgress: (@Sendable (String) -> Void)?
    private(set) var candidates: [Candidate] = []
    private(set) var projects: [String: ProjectInfo] = [:]

    /// Bundles and dependency folders that never hold a project of their own.
    private static let skippedExtensions: Set<String> = [
        "app", "framework", "xcodeproj", "xcworkspace", "xcassets", "bundle", "photoslibrary", "lproj", "xcframework", "playground",
    ]
    private static let skippedNames: Set<String> = ["Pods", "Carthage", "vendor", "DerivedData", "Library"]

    init(maxDepth: Int, isExcluded: @escaping (String) -> Bool, onProgress: (@Sendable (String) -> Void)?) {
        self.maxDepth = maxDepth
        self.isExcluded = isExcluded
        self.onProgress = onProgress
    }

    func walk(_ directory: String, depth: Int, project: String?) {
        if Task.isCancelled || isExcluded(directory) { return }
        var files = Set<String>()
        var folders: [String] = []
        var hasGit = false
        var hasXcodeProject = false
        var newest: TimeInterval = 0
        _ = try? DirectoryReader.read(directory) { entry in
            if entry.name == ".git" {
                hasGit = true
                if entry.modified > newest { newest = entry.modified }
                return
            }
            switch entry.kind {
            case .file:
                files.insert(entry.name)
                if entry.name != ".DS_Store", entry.modified > newest { newest = entry.modified }
            case .directory:
                folders.append(entry.name)
                let ext = (entry.name as NSString).pathExtension
                if ext == "xcodeproj" || ext == "xcworkspace" { hasXcodeProject = true }
                if !ArtifactRule.artifactNames.contains(entry.name), entry.modified > newest { newest = entry.modified }
            case .symlink, .other:
                // Symlinked folders are skipped, and never followed.
                break
            }
        }

        // A git repository always starts a project; a marker file starts one
        // only when the folder is not already inside a project.
        var current = project
        if hasGit {
            current = directory
        } else if current == nil, hasXcodeProject || !files.isDisjoint(with: ArtifactRule.projectMarkers) {
            current = directory
        }
        if let current {
            if current == directory {
                projects[directory] = ProjectInfo(isGit: hasGit, lastTouched: newest)
                if depth <= 2 { onProgress?(directory) }
            } else if let info = projects[current], newest > info.lastTouched {
                projects[current]?.lastTouched = newest
            }
        }
        let isGitProject = current.flatMap { projects[$0]?.isGit } ?? false

        for name in folders.sorted() {
            let path = directory + "/" + name
            if ArtifactRule.artifactNames.contains(name) {
                if let (rule, requiresIgnore) = matchingRule(name: name, path: path, siblings: files, isGitProject: isGitProject) {
                    let owner = current ?? directory
                    if projects[owner] == nil { projects[owner] = ProjectInfo(isGit: false, lastTouched: newest) }
                    candidates.append(Candidate(path: path, kind: rule.kind, project: owner, requiresIgnore: requiresIgnore))
                    continue
                }
                // Dependency folders are never entered, whatever sits next to them.
                if name == "node_modules" || name.hasPrefix(".") || name == "__pycache__" { continue }
            } else if name.hasPrefix(".") || Self.skippedNames.contains(name)
                        || Self.skippedExtensions.contains((name as NSString).pathExtension) {
                continue
            }
            if depth < maxDepth {
                walk(path, depth: depth + 1, project: current)
            }
        }
    }

    private func matchingRule(name: String, path: String, siblings: Set<String>, isGitProject: Bool) -> (ArtifactRule, Bool)? {
        for rule in ArtifactRule.all where rule.names.contains(name) {
            switch rule.condition {
            case .sibling(let markers):
                let found = markers.contains { marker in
                    if marker.hasPrefix("*.") {
                        let suffix = String(marker.dropFirst(1))
                        return siblings.contains { $0.hasSuffix(suffix) }
                    }
                    return siblings.contains(marker)
                }
                if found { return (rule, false) }
            case .contains(let file):
                if FileManager.default.fileExists(atPath: path + "/" + file) { return (rule, false) }
            case .gitIgnored:
                // Only git can vouch for a generic name.
                if isGitProject { return (rule, true) }
            }
        }
        return nil
    }
}
