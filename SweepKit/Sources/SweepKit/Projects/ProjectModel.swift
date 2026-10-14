import Foundation

/// When a folder name counts as a rebuildable artifact.
public struct ArtifactRule: Sendable {
    public enum Condition: Sendable {
        /// One of these files sits next to the folder. `*.ext` matches by extension.
        case sibling([String])
        /// The folder itself contains this file.
        case contains(String)
        /// Git ignores the folder. Used for generic names that prove nothing on their own.
        case gitIgnored
    }

    public var names: [String]
    public var condition: Condition
    public var kind: String

    public init(_ names: [String], _ condition: Condition, kind: String) {
        self.names = names
        self.condition = condition
        self.kind = kind
    }

    static let pythonMarkers = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "tox.ini", "noxfile.py", "*.py"]
    static let gradleMarkers = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    /// Checked in order; the first rule whose condition holds wins.
    public static let all: [ArtifactRule] = [
        ArtifactRule(["node_modules"], .sibling(["package.json"]), kind: "Node modules"),
        ArtifactRule([".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite"], .sibling(["package.json"]), kind: "Framework cache"),
        ArtifactRule([".venv", "venv", "env"], .contains("pyvenv.cfg"), kind: "Python virtualenv"),
        ArtifactRule(["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox"], .sibling(pythonMarkers), kind: "Python cache"),
        ArtifactRule(["target"], .sibling(["Cargo.toml", "pom.xml"]), kind: "Build output"),
        ArtifactRule([".build"], .sibling(["Package.swift"]), kind: "SwiftPM build"),
        ArtifactRule(["build", ".gradle"], .sibling(gradleMarkers), kind: "Gradle output"),
        ArtifactRule([".dart_tool"], .sibling(["pubspec.yaml"]), kind: "Dart tool cache"),
        ArtifactRule(["_build", "deps"], .sibling(["mix.exs"]), kind: "Elixir build"),
        ArtifactRule([".terraform"], .sibling(["*.tf"]), kind: "Terraform providers"),
        ArtifactRule(["build", "dist"], .gitIgnored, kind: "Build output"),
    ]

    /// Files that make a folder a project even when it has no artifacts yet.
    static let projectMarkers: Set<String> = [
        "package.json", "Cargo.toml", "pom.xml", "Package.swift", "pyproject.toml", "setup.py", "requirements.txt",
        "pubspec.yaml", "mix.exs", "go.mod", "Gemfile", "composer.json", "build.gradle", "build.gradle.kts",
        "settings.gradle", "settings.gradle.kts", "Makefile", "CMakeLists.txt",
    ]

    /// Every folder name some rule knows. The scanner never descends into these.
    static let artifactNames: Set<String> = Set(all.flatMap(\.names))
}

public enum GitState: String, Sendable, Codable {
    /// The project is not a git repository.
    case noRepository
    /// Git ignores the folder.
    case ignored
    /// Not ignored, but nothing inside is tracked.
    case untracked
    /// Git tracks files inside. Never deleted.
    case tracked
}

public struct ProjectArtifact: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var projectPath: String
    /// Path relative to the project, for display.
    public var relativePath: String
    public var kind: String
    public var bytes: Int64
    public var lastModified: Date?
    public var git: GitState
    public var fingerprint: Fingerprint?
    /// True when only git's ignore list makes this folder an artifact.
    public var requiresIgnore: Bool
    /// True for a DerivedData folder matched to the project; it lives outside the project.
    public var isDerivedData: Bool

    public var isDeletable: Bool { git != .tracked }
}

public struct Project: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var artifacts: [ProjectArtifact]
    /// The newest change to the project's own files, artifacts excluded.
    public var lastTouched: Date
    public var isGitRepository: Bool

    public var bytes: Int64 { artifacts.filter(\.isDeletable).reduce(0) { $0 + $1.bytes } }

    public func isRecent(days: Int, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastTouched) < TimeInterval(days) * 86_400
    }

    public func isStale(days: Int, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastTouched) >= TimeInterval(days) * 86_400
    }
}
