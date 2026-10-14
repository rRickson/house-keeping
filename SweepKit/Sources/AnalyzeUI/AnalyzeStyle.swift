import SweepAnalyze
import SweepKit
import SwiftUI

extension FileCategory {
    /// System colours, so every tile and legend dot adapts to light and dark mode.
    var color: Color {
        switch self {
        case .code: .blue
        case .images: .pink
        case .video: .purple
        case .audio: .orange
        case .archives: .brown
        case .documents: .teal
        case .apps: .indigo
        case .developer: .green
        case .system, .other: .gray
        }
    }

    /// How strongly a tile of this type is tinted. Tiles are tints over the
    /// plain background rather than solid blocks, so labels stay in the
    /// primary text colour and the map stays calm.
    func tintOpacity(_ scheme: ColorScheme) -> Double {
        switch self {
        case .other: scheme == .dark ? 0.22 : 0.16
        case .system: scheme == .dark ? 0.42 : 0.34
        default: scheme == .dark ? 0.50 : 0.36
        }
    }

    /// The tint of a tile or legend dot.
    func tint(_ scheme: ColorScheme) -> Color {
        color.opacity(tintOpacity(scheme))
    }

    var symbol: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archives: "archivebox"
        case .documents: "doc.text"
        case .apps: "macwindow"
        case .developer: "hammer"
        case .system: "gearshape"
        case .other: "doc"
        }
    }
}

enum AnalyzeFormat {
    /// "1,204 files"
    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count.formatted()) files"
    }

    /// "3 folders"
    static func folders(_ count: Int) -> String {
        count == 1 ? "1 folder" : "\(count.formatted()) folders"
    }

    /// "changed 2 years ago"
    static func lastChanged(_ date: Date?) -> String {
        guard let date else { return "no date" }
        return "changed " + date.relativeDescription
    }
}

/// Number and unit of a size as plain text, for places a view cannot go
/// (the treemap canvas). Matches `SizeText`.
func sizeLabel(_ bytes: Int64) -> String {
    let parts = ByteFormat.parts(bytes)
    return parts.value + " " + parts.unit
}
