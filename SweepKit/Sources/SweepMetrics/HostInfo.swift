import Darwin
import Foundation

/// Facts about this Mac that do not change while it runs.
public enum HostInfo {
    /// "Apple M4 Max", or the Intel brand string.
    public static let chipName: String? = string("machdep.cpu.brand_string")
    /// "Mac16,5"
    public static let modelIdentifier: String? = string("hw.model")
    public static let logicalCores: Int = ProcessInfo.processInfo.activeProcessorCount
    public static let memoryBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory)

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
