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
            "-\(project.type)", "\"\(project.path.lexicallyNormalized().string.withEscapedQuotes)\"",
            "-scheme", "\"\(scheme.withEscapedQuotes)\"",
        ]
        if let configuration {
            args += ["-configuration", "\"\(configuration.withEscapedQuotes)\""]
        }
        args += [
            "-parallelizeTargets",
            "-derivedDataPath", "'\(derivedDataPath.string)'",
            "-quiet",
            "build-for-testing",
        ]
        let envs = [
            "CODE_SIGNING_ALLOWED=\"NO\"",
            "ENABLE_BITCODE=\"NO\"",
            "DEBUG_INFORMATION_FORMAT=\"dwarf\"",
            "COMPILER_INDEX_STORE_ENABLE=\"YES\"",
            "INDEX_ENABLE_DATA_STORE=\"YES\"",
        ]

        let quotedArguments = quote(arguments: additionalArguments)
        let xcodebuild = ["xcodebuild"] + args + envs + quotedArguments
        return try shell.exec(xcodebuild, onOutputLine: onOutputLine)
    }

    public func removeDerivedData(
        for project: XcodeProjectlike,
        allSchemes: [String],
        configuration: String? = nil,
        buildArguments: [String] = []
    ) throws {
        let path = try derivedDataPath(for: project, schemes: allSchemes, configuration: configuration, buildArguments: buildArguments)
        try shell.exec(["rm", "-rf", path.string])
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

    func schemes(project: XcodeProjectlike, additionalArguments: [String]) throws -> Set<String> {
        try schemes(
            type: project.type,
            path: project.path.lexicallyNormalized().string,
            additionalArguments: additionalArguments
        )
    }

    func schemes(type: String, path: String, additionalArguments: [String]) throws -> Set<String> {
        let args = [
            "-\(type)", "\"\(path.withEscapedQuotes)\"",
            "-list",
            "-json",
        ]

        let quotedArguments = quote(arguments: additionalArguments)
        let xcodebuild = ["xcodebuild"] + args + quotedArguments
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

    private func quote(arguments: [String]) -> [String] {
        var quotedArguments = arguments

        for (i, arg) in arguments.enumerated() {
            if arg.hasPrefix("-"),
               let value = arguments[safe: i + 1],
               !value.hasPrefix("-"),
               !value.hasPrefix("\""),
               !value.hasPrefix("\'")
            {
                quotedArguments[i + 1] = "\"\(value)\""
            }
        }

        return quotedArguments
    }
}
