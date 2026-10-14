import Foundation

/// The set of rules Sweep knows: the bundled catalog plus any JSON dropped
/// into `~/Library/Application Support/Sweep/catalog.d/`.
public struct Catalog: Sendable {
    public var items: [CatalogItem]
    /// Problems found while loading user entries (file name and reason).
    public var warnings: [String]

    public init(items: [CatalogItem], warnings: [String] = []) {
        self.items = items
        self.warnings = warnings
    }

    public func item(_ id: String) -> CatalogItem? { items.first { $0.id == id } }

    public func items(in group: CatalogGroup) -> [CatalogItem] { items.filter { $0.group == group } }

    /// The catalog shipped inside SweepKit.
    public static func bundled() -> Catalog {
        guard let url = catalogURL(), let data = try? Data(contentsOf: url) else {
            return Catalog(items: [], warnings: ["bundled catalog is missing"])
        }
        do {
            return Catalog(items: try JSONDecoder().decode([CatalogItem].self, from: data))
        } catch {
            return Catalog(items: [], warnings: ["bundled catalog is invalid: \(error)"])
        }
    }

    /// Finds `catalog.json`. The `sweep` tool inside Sweep.app sits in
    /// `Contents/Helpers`, where SwiftPM's own lookup does not search, so the
    /// app's Resources folder is tried first.
    private static func catalogURL() -> URL? {
        let bundleName = "SweepKit_SweepKit.bundle"
        var folders = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let folder = executable.deletingLastPathComponent()
            folders.append(folder)
            folders.append(folder.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for folder in folders.compactMap({ $0 }) {
            let bundle = folder.appendingPathComponent(bundleName)
            for candidate in [bundle.appendingPathComponent("Contents/Resources/catalog.json"), bundle.appendingPathComponent("catalog.json")]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return Bundle.module.url(forResource: "catalog", withExtension: "json")
    }

    /// The bundled catalog with the user's `catalog.d` entries merged in.
    /// A user entry with the id of a bundled one replaces it.
    public static func load(context: SweepContext) -> Catalog {
        var catalog = bundled()
        let directory = context.supportDirectory.appendingPathComponent("catalog.d")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return catalog
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()
                let entries: [CatalogItem]
                if let many = try? decoder.decode([CatalogItem].self, from: data) {
                    entries = many
                } else {
                    entries = [try decoder.decode(CatalogItem.self, from: data)]
                }
                for entry in entries {
                    if let problem = validate(entry) {
                        catalog.warnings.append("\(file.lastPathComponent): \(problem)")
                        continue
                    }
                    if let index = catalog.items.firstIndex(where: { $0.id == entry.id }) {
                        catalog.items[index] = entry
                    } else {
                        catalog.items.append(entry)
                    }
                }
            } catch {
                catalog.warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return catalog
    }

    /// Returns a reason when an entry cannot be used.
    public static func validate(_ item: CatalogItem) -> String? {
        if item.id.isEmpty || item.name.isEmpty { return "entry needs an id and a name" }
        if item.locate.isEmpty && item.clean.type != .handler { return "\(item.id): no locate steps" }
        switch item.clean.type {
        case .command:
            if (item.clean.command ?? []).isEmpty { return "\(item.id): command strategy without a command" }
        case .handler:
            guard let name = item.clean.handler, Handlers.all[name] != nil else {
                return "\(item.id): unknown handler \(item.clean.handler ?? "")"
            }
        case .delete, .deleteChildren, .select:
            break
        }
        return nil
    }
}
