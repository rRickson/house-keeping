import Foundation

/// What a handler found for its item.
public struct HandlerScan: Sendable {
    public var roots: [String] = []
    public var targets: [CleanTarget] = []
    public var status: ScanStatus = .missing
    public var selectable = false
    public var actionDescription = ""
    /// Overrides the sum of target sizes when the targets do not carry sizes.
    public var bytes: Int64?

    public init() {}
}

/// Logic for catalog items that do not fit a declarative rule. Handlers only
/// describe what to do; deletes and commands still run through the executor.
public protocol ItemHandler: Sendable {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan
    /// A scan that must not reuse an earlier answer; used to measure what a clean freed.
    func scan(_ item: CatalogItem, engine: SweepEngine, fresh: Bool) async -> HandlerScan
}

extension ItemHandler {
    public func scan(_ item: CatalogItem, engine: SweepEngine, fresh: Bool) async -> HandlerScan {
        await scan(item, engine: engine)
    }
}

public enum Handlers {
    public static let all: [String: any ItemHandler] = [
        "docker-build-cache": DockerBuildCacheHandler(),
        "docker-prune": DockerPruneHandler(),
        "docker-images": DockerImagesHandler(),
        "docker-volumes": DockerVolumesHandler(),
        "ollama-models": OllamaHandler(),
        "simulator-runtimes": SimulatorRuntimesHandler(),
        "unavailable-simulators": UnavailableSimulatorsHandler(),
        "device-support": DeviceSupportHandler(),
        "jetbrains-stale": JetBrainsHandler(),
    ]

    static func jsonLines(_ output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}

// MARK: Docker

private enum DockerState {
    case notInstalled
    case unavailable(String)
    case rows([[String: Any]])
}

/// `docker system df`, one JSON object per resource type. The command is slow
/// on a busy daemon, so the three Docker items share one answer.
private func dockerDiskUsage(_ engine: SweepEngine, fresh: Bool = false) async -> DockerState {
    guard engine.context.runner.locate("docker") != nil else { return .notInstalled }
    let result = await engine.run(["docker", "system", "df", "--format", "{{json .}}"], timeout: 90, reuseWithin: fresh ? 0 : 30)
    if result.timedOut { return .unavailable("Docker did not answer in time") }
    guard result.succeeded else { return .unavailable("Docker is not running") }
    return .rows(Handlers.jsonLines(result.stdout))
}

private func reclaimable(_ rows: [[String: Any]], type: String) -> Int64 {
    guard let row = rows.first(where: { ($0["Type"] as? String) == type }),
          let text = row["Reclaimable"] as? String else { return 0 }
    return ByteFormat.parse(text) ?? 0
}

struct DockerBuildCacheHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        await scan(item, engine: engine, fresh: false)
    }

    func scan(_ item: CatalogItem, engine: SweepEngine, fresh: Bool) async -> HandlerScan {
        var scan = HandlerScan()
        let command = ["docker", "builder", "prune", "-f"]
        scan.actionDescription = command.joined(separator: " ")
        switch await dockerDiskUsage(engine, fresh: fresh) {
        case .notInstalled:
            break
        case .unavailable(let reason):
            scan.status = .blocked(reason)
        case .rows(let rows):
            scan.targets = [.command(command, bytes: reclaimable(rows, type: "Build Cache"))]
            scan.status = .ready
        }
        return scan
    }
}

struct DockerPruneHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        await scan(item, engine: engine, fresh: false)
    }

    func scan(_ item: CatalogItem, engine: SweepEngine, fresh: Bool) async -> HandlerScan {
        var scan = HandlerScan()
        let command = ["docker", "system", "prune", "-f"]
        scan.actionDescription = command.joined(separator: " ")
        switch await dockerDiskUsage(engine, fresh: fresh) {
        case .notInstalled:
            break
        case .unavailable(let reason):
            scan.status = .blocked(reason)
        case .rows(let rows):
            var bytes = reclaimable(rows, type: "Containers")
            let dangling = await engine.context.runner.run(
                "docker", ["images", "--filter", "dangling=true", "--format", "{{.Size}}"], timeout: 30)
            if dangling.succeeded {
                for line in dangling.stdout.split(whereSeparator: \.isNewline) {
                    bytes += ByteFormat.parse(String(line)) ?? 0
                }
            }
            scan.targets = [.command(command, bytes: bytes)]
            scan.status = .ready
        }
        return scan
    }
}

/// Every image no container uses, not just dangling ones: `docker image prune -a -f`.
struct DockerImagesHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        await scan(item, engine: engine, fresh: false)
    }

    func scan(_ item: CatalogItem, engine: SweepEngine, fresh: Bool) async -> HandlerScan {
        var scan = HandlerScan()
        let command = ["docker", "image", "prune", "-a", "-f"]
        scan.actionDescription = command.joined(separator: " ")
        switch await dockerDiskUsage(engine, fresh: fresh) {
        case .notInstalled:
            break
        case .unavailable(let reason):
            scan.status = .blocked(reason)
        case .rows(let rows):
            scan.targets = [.command(command, bytes: reclaimable(rows, type: "Images"))]
            scan.status = .ready
        }
        return scan
    }
}

struct DockerVolumesHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        scan.selectable = true
        scan.actionDescription = "docker volume rm <volume>"
        guard engine.context.runner.locate("docker") != nil else { return scan }
        let result = await engine.run(["docker", "system", "df", "-v", "--format", "{{json .}}"], timeout: 90, reuseWithin: 30)
        guard result.succeeded else {
            scan.status = .blocked(result.timedOut ? "Docker did not answer in time" : "Docker is not running")
            return scan
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]] else {
            scan.status = .ready
            return scan
        }
        for volume in volumes {
            guard let name = volume["Name"] as? String else { continue }
            let bytes = (volume["Size"] as? String).flatMap(ByteFormat.parse) ?? 0
            let links = (volume["Links"] as? Int) ?? Int(volume["Links"] as? String ?? "") ?? 0
            let detail = links > 0 ? "in use by \(links) container\(links == 1 ? "" : "s")" : nil
            scan.targets.append(.command(["docker", "volume", "rm", name], label: name, bytes: bytes, detail: detail))
        }
        scan.targets.sort { $0.bytes > $1.bytes }
        scan.status = .ready
        return scan
    }
}

// MARK: Ollama

struct OllamaHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        scan.selectable = true
        scan.actionDescription = "ollama rm <model>"
        let context = engine.context
        let models = context.expand(context.environment["OLLAMA_MODELS"] ?? "~/.ollama/models")
        let hasModels = FileManager.default.fileExists(atPath: models)
        guard context.runner.locate("ollama") != nil else {
            // Models without the tool: show the folder, but there is no safe way to pick one.
            if hasModels, let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: models)]) {
                scan.bytes = size.bytes
                scan.status = .blocked("Ollama is not installed")
            }
            return scan
        }
        let result = await context.runner.run("ollama", ["list"], timeout: 15)
        guard result.succeeded else {
            if hasModels, let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: models)]) {
                scan.bytes = size.bytes
            }
            scan.status = .blocked("Ollama is not running")
            return scan
        }
        for line in result.stdout.split(whereSeparator: \.isNewline).dropFirst() {
            // NAME  ID  SIZE  MODIFIED, separated by runs of spaces.
            let columns = line.replacingOccurrences(of: "\t", with: "  ")
                .components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard columns.count >= 3 else { continue }
            let name = columns[0]
            let bytes = ByteFormat.parse(columns[2]) ?? 0
            let detail = columns.count > 3 ? "modified \(columns[3])" : nil
            scan.targets.append(.command(["ollama", "rm", name], label: name, bytes: bytes, detail: detail))
        }
        scan.targets.sort { $0.bytes > $1.bytes }
        scan.status = .ready
        return scan
    }
}

// MARK: Simulators

struct SimulatorRuntimesHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        scan.selectable = true
        scan.actionDescription = "xcrun simctl runtime delete <id>"
        guard engine.context.runner.locate("xcrun") != nil else { return scan }
        let result = await engine.context.runner.run("xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return scan }
        for (id, value) in object {
            guard let runtime = value as? [String: Any] else { continue }
            if let deletable = runtime["deletable"] as? Bool, !deletable { continue }
            let bytes = (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let version = runtime["version"] as? String ?? ""
            let build = runtime["build"] as? String ?? ""
            let platform = (runtime["platformIdentifier"] as? String ?? "")
                .replacingOccurrences(of: "com.apple.platform.", with: "")
                .replacingOccurrences(of: "simulator", with: "")
            let names = ["iphone": "iOS", "appletv": "tvOS", "watch": "watchOS", "xr": "visionOS"]
            let label = "\(names[platform] ?? platform) \(version) (\(build))"
            scan.targets.append(.command(["xcrun", "simctl", "runtime", "delete", id], label: label, bytes: bytes,
                                         detail: runtime["state"] as? String))
        }
        scan.targets.sort { $0.label.compare($1.label, options: .numeric) == .orderedDescending }
        scan.status = scan.targets.isEmpty ? .missing : .ready
        return scan
    }
}

struct UnavailableSimulatorsHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        let command = ["xcrun", "simctl", "delete", "unavailable"]
        scan.actionDescription = command.joined(separator: " ")
        guard engine.context.runner.locate("xcrun") != nil else { return scan }
        let result = await engine.context.runner.run("xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: Any] else { return scan }
        var bytes: Int64 = 0
        var count = 0
        var unsized: [URL] = []
        for (_, value) in runtimes {
            for device in value as? [[String: Any]] ?? [] {
                if let available = device["isAvailable"] as? Bool, available { continue }
                count += 1
                if let size = (device["dataPathSize"] as? NSNumber)?.int64Value {
                    bytes += size
                } else if let path = device["dataPath"] as? String {
                    unsized.append(URL(fileURLWithPath: path).deletingLastPathComponent())
                }
            }
        }
        if !unsized.isEmpty, let size = try? await engine.sizer.sizeAsync(of: unsized) { bytes += size.bytes }
        guard count > 0 else { return scan }
        scan.targets = [.command(command, bytes: bytes, detail: "\(count) device\(count == 1 ? "" : "s")")]
        scan.status = .ready
        return scan
    }
}

// MARK: Device support

/// Keeps the newest device-support folder per platform and offers the rest.
struct DeviceSupportHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        scan.actionDescription = "Delete all but the newest version per platform"
        let resolution = await engine.resolver.resolve(item)
        scan.roots = resolution.roots
        for root in resolution.roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            let folders = names.filter { !$0.hasPrefix(".") }.map { name -> (name: String, version: [Int], path: String) in
                (name, Self.version(in: name), root + "/" + name)
            }
            let sorted = folders.sorted { Self.isNewer($0.version, than: $1.version) }
            let platform = (root as NSString).lastPathComponent
            for folder in sorted.dropFirst() {
                let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: folder.path)])
                scan.targets.append(.delete(folder.path, label: "\(platform)/\(folder.name)", bytes: size?.bytes ?? 0,
                                            lastModified: size?.lastModified))
            }
        }
        scan.status = scan.roots.isEmpty ? .missing : .ready
        return scan
    }

    /// The first dotted number in a name like "iPhone14,7 17.5.1 (21F90)".
    static func version(in name: String) -> [Int] {
        for token in name.split(separator: " ") {
            let parts = token.split(separator: ".")
            if parts.count >= 1, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return parts.compactMap { Int($0) }
            }
        }
        return []
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: JetBrains

/// Offers the cache folders of IDE versions that are no longer installed.
struct JetBrainsHandler: ItemHandler {
    func scan(_ item: CatalogItem, engine: SweepEngine) async -> HandlerScan {
        var scan = HandlerScan()
        scan.actionDescription = "Delete caches of IDE versions that are no longer installed"
        let resolution = await engine.resolver.resolve(item)
        scan.roots = resolution.roots
        guard !resolution.roots.isEmpty else { return scan }
        let installed = Self.installedDataDirectories(home: engine.context.home.path, includeSystem: !engine.context.isFixture)
        for root in resolution.roots {
            let isGoogle = (root as NSString).lastPathComponent == "Google"
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where Self.isVersionedCache(name) && !installed.contains(name) {
                // The Google folder also holds Chrome; only Android Studio belongs to this rule.
                if isGoogle, !name.hasPrefix("AndroidStudio") { continue }
                let path = root + "/" + name
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let size = try? await engine.sizer.sizeAsync(of: [URL(fileURLWithPath: path)])
                scan.targets.append(.delete(path, bytes: size?.bytes ?? 0, lastModified: size?.lastModified))
            }
        }
        scan.status = .ready
        return scan
    }

    /// True for "IntelliJIdea2026.2" or "AndroidStudio2025.3.4": a product name followed by a version.
    /// Shared folders such as "Daemon" are never offered.
    static func isVersionedCache(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z]+[0-9]{4}\.[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// The cache folder name of every installed JetBrains IDE. Current IDEs
    /// state it in `product-info.json`; older ones in `idea.paths.selector`.
    static func installedDataDirectories(home: String, includeSystem: Bool = true) -> Set<String> {
        var names = Set<String>()
        var appFolders = ["\(home)/Applications", "\(home)/Applications/JetBrains Toolbox"]
        if includeSystem { appFolders.append("/Applications") }
        let toolbox = "\(home)/Library/Application Support/JetBrains/Toolbox/apps"
        if let enumerator = FileManager.default.enumerator(atPath: toolbox) {
            // Toolbox nests apps as <product>/<channel>/<build>/<Name>.app.
            for case let relative as String in enumerator {
                if relative.hasSuffix(".app") {
                    appFolders.append(toolbox + "/" + (relative as NSString).deletingLastPathComponent)
                    enumerator.skipDescendants()
                } else if relative.split(separator: "/").count > 4 {
                    enumerator.skipDescendants()
                }
            }
        }
        for folder in Set(appFolders) {
            guard let apps = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for app in apps where app.hasSuffix(".app") {
                let contents = "\(folder)/\(app)/Contents"
                if let data = FileManager.default.contents(atPath: contents + "/Resources/product-info.json"),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = info["dataDirectoryName"] as? String {
                    names.insert(name)
                }
                if let info = NSDictionary(contentsOfFile: contents + "/Info.plist"),
                   let options = info["JVMOptions"] as? [String: Any],
                   let properties = options["Properties"] as? [String: Any],
                   let selector = properties["idea.paths.selector"] as? String {
                    names.insert(selector)
                }
            }
        }
        return names
    }
}
