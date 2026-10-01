import Foundation
import Logger
import Shared
import SystemPackage

public final class Xcodebuild {
    private let shell: Shell
    private let logger: Logger

    public required init(shell: Shell, logger: Logger) {
        self.shell = shell
        self.logger = logger
    }

    private static var version: String?

    public func version() throws -> String {
        if let version = Xcodebuild.version {
            return version
        }

        let version = try shell.exec(["xcodebuild", "-version"]).trimmed
        Xcodebuild.version = version
        return version
    }

    public func ensureConfigured() throws {
        do {
            try logger.debug(version())
        } catch {
            throw LethenError.xcodebuildNotConfigured
        }
    }

    /// Builds `scheme` for testing with indexing enabled, passing each line of build output to `onOutputLine`.
    /// A `configuration` is passed as `-configuration`; without one, xcodebuild uses the scheme's Test action
    /// configuration.
    @discardableResult
    public func build(
        project: XcodeProjectlike,
        scheme: String,
        allSchemes: [String],
        configuration: String? = nil,
        additionalArguments: [String] = [],
        onOutputLine: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> String {
        let derivedDataPath = try derivedDataPath(
            for: project,
            schemes: allSchemes,
            configuration: configuration,
            buildArguments: additionalArguments
        )
        var args = [
            "-\(project.type)", project.path.lexicallyNormalized().string,
            "-scheme", scheme,
        ]
        if let configuration {
            args += ["-configuration", configuration]
        }
        args += [
            "-parallelizeTargets",
            "-derivedDataPath", derivedDataPath.string,
            "-quiet",
            "build-for-testing",
        ]
        let envs = [
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_BITCODE=NO",
            "DEBUG_INFORMATION_FORMAT=dwarf",
            "COMPILER_INDEX_STORE_ENABLE=YES",
            "INDEX_ENABLE_DATA_STORE=YES",
        ]

        let xcodebuild = ["xcodebuild"] + args + envs + additionalArguments
        return try shell.exec(xcodebuild, onOutputLine: onOutputLine)
    }

    /// Locks the DerivedData directories of `configurations` for this scan: exclusively to build into them, shared to
    /// read their stores. The directories are locked in path order, so scans that lock overlapping sets cannot deadlock.
    public func lockDerivedData(
        project: XcodeProjectlike,
        schemes: [String],
        configurations: [String?],
        buildArguments: [String] = [],
        exclusive: Bool
    ) throws -> DerivedDataLock {
        let directories = try configurations.map {
            try derivedDataPath(for: project, schemes: schemes, configuration: $0, buildArguments: buildArguments)
        }
        return try DerivedDataLock(directories: directories, exclusive: exclusive) { [logger] directory in
            logger.info("Waiting for another Lethen scan to finish with \(directory)...")
        }
    }

    /// Starts this scan's builds into a DerivedData directory, which the caller has locked exclusively. A store left by
    /// a failed or interrupted build lacks units for what it never compiled, which no freshness check can see, so the
    /// completion mark is removed first. The directory's name is a hash that other projects of the same name or other
    /// scheme sets can share, and an incremental build would keep their units, so a directory last built for anything
    /// else, or by a Lethen that recorded nothing, is removed.
    public func beginBuild(
        project: XcodeProjectlike,
        schemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws {
        let directory = try derivedDataPath(for: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        let identity = try Self.markerContents(project: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        let identityFile = directory.appending(Self.buildIdentityFile)
        if directory.exists, FileManager.default.contents(atPath: identityFile.string) != identity {
            logger.debug("\(directory) was last built for another project or scheme set; removing it.")
            try FileManager.default.removeItem(atPath: directory.string)
        }

        let marker = directory.appending(Self.completedBuildMarker)
        if marker.exists {
            try FileManager.default.removeItem(atPath: marker.string)
        }

        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        try identity.write(to: identityFile.url, options: .atomic)
    }

    /// Marks the store complete once every build this scan started into the directory has succeeded. The caller still
    /// holds the exclusive lock it began with.
    public func completeBuild(
        project: XcodeProjectlike,
        schemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws {
        let directory = try derivedDataPath(for: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        let contents = try Self.markerContents(project: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        try contents.write(to: directory.appending(Self.completedBuildMarker).url, options: .atomic)
    }

    public func removeDerivedData(
        for project: XcodeProjectlike,
        allSchemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws {
        let path = try derivedDataPath(for: project, schemes: allSchemes, configuration: configuration, buildArguments: buildArguments)
        try path.removeIfPresent()
    }

    public func indexStorePath(
        project: XcodeProjectlike,
        schemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws -> FilePath {
        let derivedDataPath = try derivedDataPath(for: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        let pathsToTry = ["Index.noindex/DataStore", "Index/DataStore"]
            .map { derivedDataPath.appending($0) }
        guard let path = pathsToTry.first(where: { $0.exists }) else {
            throw LethenError.indexStoreNotFound(derivedDataPath: derivedDataPath.string)
        }

        return path
    }

    /// Whether the last build of every scheme into this DerivedData directory completed. A store whose build failed
    /// or was interrupted can lack units for whole files, so `--skip-build` must not read it as a complete index.
    public func hasCompletedBuild(
        project: XcodeProjectlike,
        schemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws -> Bool {
        let marker = try derivedDataPath(for: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
            .appending(Self.completedBuildMarker)
        return try FileManager.default.contents(atPath: marker.string)
            == Self.markerContents(project: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
    }

    static let completedBuildMarker = "lethen-build-completed"
    static let buildIdentityFile = "lethen-build-identity"

    /// What the mark records. The directory's name is a hash of the project's name, the joined scheme names, the
    /// configuration and the build arguments, so different projects or scheme sets, such as `A, BC` and `AB, C`, can
    /// share it; the mark names exactly what was built.
    static func markerContents(project: XcodeProjectlike, schemes: [String], configuration: String?, buildArguments: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CompletedBuild(
            project: project.path.lexicallyNormalized().string,
            schemes: schemes.sorted(),
            configuration: configuration,
            buildArguments: buildArguments
        ))
    }

    private struct CompletedBuild: Encodable {
        let project: String
        let schemes: [String]
        let configuration: String?
        let buildArguments: [String]
    }

    func schemes(project: XcodeProjectlike, additionalArguments: [String]) throws -> Set<String> {
        try schemes(
            type: project.type,
            path: project.path.lexicallyNormalized().string,
            additionalArguments: additionalArguments
        )
    }

    func schemes(type: String, path: String, additionalArguments: [String]) throws -> Set<String> {
        let args = [
            "-\(type)", path,
            "-list",
            "-json",
        ]

        let xcodebuild = ["xcodebuild"] + args + additionalArguments
        let lines = try shell.exec(xcodebuild).split(separator: "\n").map { String($0).trimmed }

        // xcodebuild may output unrelated warnings, we need to strip them out otherwise
        // JSON parsing will fail.
        let startIndex = lines.firstIndex { $0 == "{" } ?? 0
        var jsonLines = lines.suffix(from: startIndex)

        if let lastIndex = jsonLines.lastIndex(where: { $0 == "}" }) {
            jsonLines = jsonLines.prefix(upTo: lastIndex + 1)
        }

        let jsonString = jsonLines.joined(separator: "\n")

        guard let json = try deserialize(jsonString),
              let details = json[type] as? [String: Any],
              let schemes = details["schemes"] as? [String] else { return [] }

        return Set(schemes)
    }

    // MARK: - Private

    private func deserialize(_ jsonString: String) throws -> [String: Any]? {
        do {
            guard let jsonData = jsonString.data(using: .utf8) else { return nil }

            return try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        } catch {
            throw LethenError.jsonDeserializationError(error: error, json: jsonString)
        }
    }

    func derivedDataPath(
        for project: XcodeProjectlike,
        schemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws -> FilePath {
        // Given a project with two schemes: A and B, a scenario can arise where the index store contains conflicting
        // data. If scheme A is built, then the source file modified and then scheme B built, the index store will
        // contain two records for that source file. One reflects the state of the file when scheme A was built, and the
        // other when B was built. We must therefore key the DerivedData path with the full list of schemes being built.
        // The schemes are sorted so that the key does not depend on the order they were collected in; a `Set` of
        // schemes iterates in a different order in each process, which used to produce a new path on every run.
        //
        // A configuration or build arguments change what is compiled, so builds that differ in either would overwrite
        // each other's units in a shared directory; they key the path too. A build with neither keeps the path it
        // has always had, and with it the previous scan's DerivedData.

        let xcodeVersionHash = try version().djb2Hex
        let projectHash = project.name.djb2Hex
        let schemesHash = schemes.sorted().joined().djb2Hex
        var name = "DerivedData-\(xcodeVersionHash)-\(projectHash)-\(schemesHash)"

        if configuration != nil || !buildArguments.isEmpty {
            // Separators keep distinct inputs distinct: ["a b"] and ["a", "b"], or a configuration and an argument.
            let variant = ([configuration ?? ""] + buildArguments).joined(separator: "\u{0}")
            name += "-\(variant.djb2Hex)"
        }

        return try Constants.cachePath().appending(name)
    }
}

/// `flock` locks on files beside DerivedData directories, so that removing a directory does not drop its lock. They
/// are released by `release()`, or when the process exits.
public final class DerivedDataLock {
    private var descriptors: [Int32]

    init(directories: [FilePath], exclusive: Bool, wait: Bool = true, onWait: (FilePath) -> Void = { _ in }) throws {
        descriptors = []
        let operation = exclusive ? LOCK_EX : LOCK_SH
        for directory in Set(directories).sorted() {
            let lockFile = directory.removingLastComponent().appending((directory.lastComponent?.string ?? "") + ".lock")
            try FileManager.default.createDirectory(atPath: lockFile.removingLastComponent().string, withIntermediateDirectories: true)
            let descriptor = open(lockFile.string, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                release()
                throw LethenError.usageError("Could not open \(lockFile): \(String(cString: strerror(errno)))")
            }

            descriptors.append(descriptor)
            if flock(descriptor, operation | LOCK_NB) != 0 {
                guard wait, errno == EWOULDBLOCK else {
                    release()
                    throw LethenError.usageError("\(directory) is in use by another Lethen scan.")
                }

                onWait(directory)
                guard flock(descriptor, operation) == 0 else {
                    release()
                    throw LethenError.usageError("Could not lock \(lockFile): \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    deinit {
        release()
    }

    public func release() {
        for descriptor in descriptors {
            close(descriptor)
        }
        descriptors = []
    }
}
