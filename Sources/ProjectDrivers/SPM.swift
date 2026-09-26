import Configuration
import Extensions
import Foundation
import Logger
import Shared
import SystemPackage

public enum SPM {
    public static var isSupported: Bool {
        FilePath.current.appending("Package.swift").exists
    }

    public struct Package {
        public let path: FilePath = .current

        private let configuration: Configuration
        private let shell: Shell
        private let logger: Logger

        public init(configuration: Configuration, shell: Shell, logger: Logger) {
            self.configuration = configuration
            self.shell = shell
            self.logger = logger
        }

        public func clean(additionalArguments: [String] = []) throws {
            // Build-only flags are not accepted by `swift package clean`.
            var scratchArguments: [String] = []
            var arguments = additionalArguments.makeIterator()
            while let argument = arguments.next() {
                if argument == "--scratch-path" {
                    guard let path = arguments.next(), !path.hasPrefix("-") else {
                        throw LethenError.usageError("--scratch-path requires a path.")
                    }

                    scratchArguments += [argument, path]
                } else if argument.hasPrefix("--scratch-path=") {
                    scratchArguments.append(argument)
                }
            }
            try shell.exec(["swift", "package", "clean"] + scratchArguments)
        }

        public func build(additionalArguments: [String]) throws {
            guard !additionalArguments.contains("--disable-index-store") else {
                throw LethenError.usageError("--disable-index-store conflicts with scanning a managed build. Remove it, or use --skip-build with --index-store-path for an externally built index.")
            }

            var arguments = ["swift", "build", "--build-tests"] + additionalArguments + ["--enable-index-store"]
            guard configuration.indexStorePath.isEmpty else {
                try shell.exec(arguments)
                return
            }

            let binary = try binaryDirectory(additionalArguments: additionalArguments)
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
            // In swiftbuild Release builds, --enable-index-store alone does
            // not put indexing flags on the Swift compiler invocation.
            let quotedStore = "'" + store.string.replacingOccurrences(of: "'", with: "'\\''") + "'"
            arguments += ["-Xswiftc", "-index-store-path", "-Xswiftc", quotedStore]

            if configuration.experimentalReuseIndex {
                try buildReusingIndex(arguments: arguments, additionalArguments: additionalArguments, binary: binary, store: store)
                return
            }

            // Indexing flags do not invalidate all Swiftbuild compilation tasks.
            // Even an existing store can be stale after an unindexed build.
            // Rebuild managed products; callers that verify an external index
            // can opt into reuse with --skip-build.
            if binary.exists {
                try clean(additionalArguments: additionalArguments)
            }
            try shell.exec(arguments)
        }

        /// Builds incrementally when SPMIndexFreshness can prove the store matches the build, and cleans
        /// otherwise. The stamp is removed before any build it does not describe.
        private func buildReusingIndex(arguments: [String], additionalArguments: [String], binary: FilePath, store: FilePath) throws {
            let logger = logger.contextualized(with: "spm:index-reuse")
            // swiftbuild keeps objects beside Products (.build/out), the native build system beside the triple.
            let freshness = SPMIndexFreshness(storePath: store, buildRoot: binary.removingLastComponent().removingLastComponent())
            let stamp = try SPMIndexFreshness.Stamp(
                swiftVersion: SwiftVersion(shell: shell).fullVersion,
                buildArguments: additionalArguments
            )
            let sources = try packageSources()

            if binary.exists, store.exists, let previous = freshness.readStamp(), previous.stamp == stamp {
                switch try freshness.prepare(sources: sources, stampDate: previous.date) {
                case let .clean(reason):
                    logger.debug("Index store not reusable, cleaning: \(reason)")
                case let .recompile(objects, modules):
                    try freshness.removeStamp()
                    for object in objects {
                        try FileManager.default.removeItem(atPath: object.string)
                    }

                    let start = Date()
                    try shell.exec(arguments)
                    let issues = try freshness.verify(sources: sources, buildStart: start)
                    if issues.isEmpty {
                        logger.debug("Reused the index store; recompiled \(modules.count) modules (\(objects.count) objects): \(modules.sorted().joined(separator: ", "))")
                        try freshness.writeStamp(stamp)
                        return
                    }

                    logger.debug("Index store not reusable (\(issues.count) issues), cleaning: \(issues.prefix(3).map(\.description).joined(separator: "; "))")
                }
            } else {
                logger.debug("No matching build stamp, cleaning.")
            }

            try freshness.removeStamp()
            if binary.exists {
                try clean(additionalArguments: additionalArguments)
            }
            let start = Date()
            try shell.exec(arguments)
            let issues = try freshness.verify(sources: sources, buildStart: start)
            guard issues.isEmpty else {
                // Leave no stamp, so the next scan cleans again; the scan itself proceeds as it does today.
                logger.debug("Clean build did not index every source (\(issues.count) issues): \(issues.prefix(3).map(\.description).joined(separator: "; "))")
                return
            }
            try freshness.writeStamp(stamp)
        }

        func packageSources() throws -> Set<SPMIndexFreshness.Source> {
            let description = try load()
            // Plugin scripts are compiled outside the build, so they never have units.
            return Set(description.targets.filter { $0.type != "plugin" }.flatMap { target in
                let module = Self.c99Name(target.name)
                return (target.sources ?? [])
                    .filter { $0.hasSuffix(".swift") }
                    .map { SPMIndexFreshness.Source(path: path.appending(target.path).appending($0), module: module) }
            })
        }

        /// SwiftPM's module name for a target: characters outside a C identifier become underscores.
        static func c99Name(_ name: String) -> String {
            var result = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
            if let first = result.first, first.isNumber {
                result = "_" + result
            }
            return result
        }

        public func indexStorePath(additionalArguments: [String]) throws -> FilePath {
            let binary = try binaryDirectory(additionalArguments: additionalArguments)
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: store.string, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LethenError.packageError(message: "Index store does not exist at \(store.string) (resolved by 'swift build --show-bin-path \(additionalArguments.joined(separator: " ")) --enable-index-store'). Build the selected configuration with indexing enabled, or use --index-store-path for an externally built index.")
            }

            return store
        }

        private func binaryDirectory(additionalArguments: [String]) throws -> FilePath {
            let query = ["swift", "build", "--show-bin-path"] + additionalArguments + ["--enable-index-store"]
            let output = try shell.exec(query)
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.contains(where: \.isNewline),
                  !path.contains("\0"), FilePath(path).isAbsolute
            else {
                throw LethenError.packageError(message: "Expected one absolute binary directory from '\(query.joined(separator: " "))', received: \(output)")
            }

            return FilePath(path)
        }

        public func load() throws -> PackageDescription {
            logger.contextualized(with: "spm:package").debug("Loading \(FilePath.current)")

            let jsonData: Data

            if let path = configuration.jsonPackageManifestPath {
                jsonData = try Data(contentsOf: path.url)
            } else {
                let jsonString = try shell.exec(["swift", "package", "describe", "--type", "json"])

                guard let data = jsonString.data(using: .utf8) else {
                    throw LethenError.packageError(message: "Failed to read swift package description.")
                }

                jsonData = data
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(PackageDescription.self, from: jsonData)
        }
    }
}

public struct PackageDescription: Decodable {
    public let targets: [Target]
}

public struct Target: Decodable {
    public let name: String
    public let type: String
    public let path: String
    public let sources: [String]?
    public let resources: [Resource]?

    public var isTestTarget: Bool {
        type == "test"
    }
}

public struct Resource: Decodable {
    public let path: String
}
