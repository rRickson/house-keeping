import Foundation

/// The handful of file types the treemap tells apart by colour.
public enum FileCategory: UInt8, Sendable, CaseIterable, Codable, Hashable {
    case code, images, video, audio, archives, documents, apps, developer, system, other

    public var title: String {
        switch self {
        case .code: "Code"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archives: "Archives"
        case .documents: "Documents"
        case .apps: "Apps"
        case .developer: "Developer"
        case .system: "System"
        case .other: "Other"
        }
    }

    /// Classifies a file by its extension alone.
    public static func classify(fileName name: String) -> FileCategory {
        guard let ext = lowercasedExtension(of: name) else { return .other }
        return byExtension[ext] ?? .other
    }

    /// The category every file below a folder belongs to, when the folder is a
    /// bundle, a well-known build or package store, or part of macOS. Nil
    /// means files are classified one by one, by extension.
    /// - Parameters:
    ///   - parent: the context of the folder that contains this one.
    ///   - path: the folder's absolute path.
    public static func context(inheriting parent: FileCategory?, directoryName name: String, path: String) -> FileCategory? {
        switch parent {
        case nil:
            if developerDirectories.contains(name) { return .developer }
            if let ext = lowercasedExtension(of: name) {
                if bundleExtensions.contains(ext) { return .apps }
                if developerBundleExtensions.contains(ext) { return .developer }
            }
            return systemRoots.contains(path) ? .system : nil
        case .system?:
            // Apps and developer stores inside system locations keep their own colour.
            if name.hasSuffix(".app") { return .apps }
            if developerDirectories.contains(name) || name == "Developer" { return .developer }
            return .system
        default:
            return parent
        }
    }

    /// The context of an absolute path, found by walking down from `/`.
    public static func context(forPath path: String) -> FileCategory? {
        var context: FileCategory?
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            context = self.context(inheriting: context, directoryName: String(component), path: current)
        }
        return context
    }

    /// The extension in lower case, without allocating for the common short case.
    static func lowercasedExtension(of name: String) -> String? {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return nil }
        let start = utf8.index(after: dot)
        let length = utf8.distance(from: start, to: utf8.endIndex)
        guard length > 0, length <= 16 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for byte in utf8[start...] {
            // Extensions with spaces or non-ASCII bytes are not file types.
            guard byte < 0x80, byte != UInt8(ascii: " "), byte != UInt8(ascii: "/") else { return nil }
            bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "appex", "kext", "plugin", "xpc", "prefpane", "qlgenerator", "mdimporter",
        "saver", "component", "vst", "vst3",
    ]

    private static let developerBundleExtensions: Set<String> = [
        "dsym", "xcarchive", "simruntime", "xcresult", "swiftmodule", "docc", "doccarchive", "xcframework",
    ]

    private static let developerDirectories: Set<String> = [
        "node_modules", "DerivedData", ".build", "Pods", "Carthage", ".gradle", ".m2", ".cargo", ".rustup",
        ".npm", ".pnpm-store", ".yarn", ".venv", "venv", "__pycache__", ".git", ".tox", ".nox", ".next", ".nuxt",
        ".svelte-kit", ".turbo", ".parcel-cache", ".dart_tool", ".terraform", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", "CoreSimulator", "DeviceSupport", "iOS DeviceSupport", ".swiftpm", ".bun", ".deno",
        ".pyenv", ".rbenv", ".nvm", ".cocoapods", "site-packages",
    ]

    private static let systemRoots: Set<String> = [
        "/System", "/usr", "/bin", "/sbin", "/Library", "/cores", "/private/etc", "/private/var/db",
        "/private/var/vm", "/private/var/log", "/private/var/protected",
    ]

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = category }
        }
        add(.code, """
            swift m mm h c cc cpp cxx hpp hh rs go py rb js mjs cjs ts tsx jsx java kt kts cs php sh zsh bash fish \
            pl pm lua r scala sql html htm css scss sass less vue svelte json jsonc yaml yml toml xml gradle cmake \
            dart ex exs erl hs clj cljs ipynb proto graphql gql tf hcl zig nim asm s vb fs elm groovy makefile \
            xcconfig entitlements storyboard xib strings pbxproj
            """)
        add(.images, """
            jpg jpeg png gif heic heif tiff tif bmp webp svg raw cr2 cr3 nef arw dng orf rw2 raf psd psb ai eps \
            icns ico avif jxl sketch fig xcf tga exr hdr indd afphoto afdesign
            """)
        add(.video, "mp4 mov m4v mkv avi wmv flv webm mpg mpeg m2ts mts 3gp ts vob ogv mxf braw r3d prproj fcpbundle")
        add(.audio, "mp3 m4a aac wav aiff aif flac ogg opus wma caf mid midi m4b m4p m4r alac ape amr band logicx")
        add(.archives, """
            zip tar gz tgz bz2 tbz xz txz 7z rar dmg iso pkg mpkg zst lz4 lzma cab jar war ear ipa apk xip \
            sparsebundle sparseimage img deb rpm cpio z aar tbz2
            """)
        add(.documents, """
            pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf rtfd md markdown csv tsv epub mobi azw3 odt \
            ods odp tex bib eml emlx mbox ics vcf djvu xps one pub log
            """)
        add(.apps, "dylib so dll exe app framework bundle appex kext plugin xpc msi tbd")
        add(.developer, """
            o a obj class pyc pyo pcm swiftmodule swiftdoc swiftinterface swiftsourceinfo hmap d rlib rmeta wasm \
            map lock pch gch dsym xcarchive simruntime nib car metallib tsbuildinfo whl gem crate nupkg dex \
            ipsw vmdk qcow2 vdi vhd vhdx gguf safetensors onnx mlmodel mlmodelc mlpackage bin pack idx rev
            """)
        add(.system, "plist sys dat cache db sqlite sqlite3 sqlite-wal sqlite-shm kcache im4p dyld trace diag ips crash")
        return map
    }()
}

/// Bytes per category, in `FileCategory.allCases` order.
public struct CategoryBytes: Sendable, Equatable {
    public static let count = FileCategory.allCases.count

    public private(set) var values: [Int64]

    public init() { values = Array(repeating: 0, count: Self.count) }

    init(values: [Int64]) {
        precondition(values.count == Self.count)
        self.values = values
    }

    public subscript(category: FileCategory) -> Int64 {
        get { values[Int(category.rawValue)] }
        set { values[Int(category.rawValue)] = newValue }
    }

    public var total: Int64 { values.reduce(0, +) }

    /// The category with the most bytes, or nil when everything is zero.
    public var dominant: FileCategory? {
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return values[best] > 0 ? FileCategory(rawValue: UInt8(best)) : nil
    }

    /// Categories with bytes, largest first.
    public var ranked: [(category: FileCategory, bytes: Int64)] {
        FileCategory.allCases
            .map { (category: $0, bytes: self[$0]) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }
}
