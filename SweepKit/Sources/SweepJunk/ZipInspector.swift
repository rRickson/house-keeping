import Foundation

/// Reads the table of contents of a zip archive, without extracting anything,
/// to decide whether the archive is an app installer.
enum ZipInspector {
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EndSignature: UInt32 = 0x0606_4b50
    private static let entrySignature: UInt32 = 0x0201_4b50
    /// Tables of contents larger than this are not read; the archive is then not an installer.
    private static let maxDirectoryBytes: UInt64 = 32 * 1024 * 1024

    /// True only when everything at the top level of the archive is an app
    /// bundle (with its `Contents/Info.plist`), a package or a disk image.
    /// Any other content, or an archive that cannot be read, gives false.
    static func isAppInstaller(atPath path: String) -> Bool {
        guard let names = entryNames(atPath: path) else { return false }
        var topLevel = Set<String>()
        var bundlesWithInfo = Set<String>()
        for name in names {
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            let top = String(first)
            if top == "__MACOSX" || top == ".DS_Store" { continue }
            topLevel.insert(top)
            if components.count == 3, components[1] == "Contents", components[2] == "Info.plist" {
                bundlesWithInfo.insert(top)
            }
        }
        guard !topLevel.isEmpty, topLevel.count <= 4 else { return false }
        for top in topLevel {
            switch (top as NSString).pathExtension.lowercased() {
            case "app":
                if !bundlesWithInfo.contains(top) { return false }
            case "pkg", "mpkg", "dmg":
                continue
            default:
                return false
            }
        }
        return true
    }

    /// The names of every entry, or nil when the file is not a readable zip.
    static func entryNames(atPath path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return nil }

        // The end record sits at the very end, after an optional comment of up to 65,535 bytes.
        let tailLength = min(fileSize, 22 + 65_535 + 20)
        guard (try? handle.seek(toOffset: fileSize - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)

        var end = -1
        var index = bytes.count - 22
        while index >= 0 {
            if u32(bytes, index) == endSignature { end = index; break }
            index -= 1
        }
        guard end >= 0 else { return nil }

        var directorySize = UInt64(u32(bytes, end + 12))
        var directoryOffset = UInt64(u32(bytes, end + 16))
        let entryCount16 = u16(bytes, end + 10)

        if entryCount16 == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: a locator right before the end record points at the real one.
            let locator = end - 20
            guard locator >= 0, u32(bytes, locator) == zip64LocatorSignature else { return nil }
            let recordOffset = u64(bytes, locator + 8)
            guard recordOffset + 56 <= fileSize,
                  (try? handle.seek(toOffset: recordOffset)) != nil,
                  let record = try? handle.read(upToCount: 56), record.count == 56 else { return nil }
            let recordBytes = [UInt8](record)
            guard u32(recordBytes, 0) == zip64EndSignature else { return nil }
            directorySize = u64(recordBytes, 40)
            directoryOffset = u64(recordBytes, 48)
        }

        guard directorySize > 0, directorySize <= maxDirectoryBytes,
              directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset,
              (try? handle.seek(toOffset: directoryOffset)) != nil,
              let directory = try? handle.read(upToCount: Int(directorySize)),
              directory.count == Int(directorySize) else { return nil }
        let table = [UInt8](directory)

        var names: [String] = []
        var position = 0
        while position + 46 <= table.count {
            guard u32(table, position) == entrySignature else { break }
            let nameLength = Int(u16(table, position + 28))
            let extraLength = Int(u16(table, position + 30))
            let commentLength = Int(u16(table, position + 32))
            let nameStart = position + 46
            guard nameStart + nameLength <= table.count else { return nil }
            names.append(String(decoding: table[nameStart..<(nameStart + nameLength)], as: UTF8.self))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return names.isEmpty ? nil : names
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}
