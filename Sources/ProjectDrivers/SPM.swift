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
            try shell.exec(["swift", "package", "clean"] + Self.packageArguments(in: additionalArguments))
        }

        /// The build arguments that `swift package` subcommands must share with the build: `--scratch-path`,
        /// `--disable-sandbox`, and `--disable-keychain`. Build-only flags are not accepted by `swift package` subcommands, so only
        /// these are kept. Without the scratch path, a subcommand locks the default `.build`, which blocks when
        /// another SwiftPM process holds that lock, such as the `swift package` running a command plugin that
        /// runs lethen; and inside a plugin's sandbox, SwiftPM cannot start a sandbox of its own.
        static func packageArguments(in additionalArguments: [String]) throws -> [String] {
            var scratchArguments: [String] = []
            var arguments = additionalArguments.makeIterator()
            while let argument = arguments.next() {
                if argument == "--scratch-path" {
                    guard let path = arguments.next(), !path.hasPrefix("-") else {
                        throw LethenError.usageError("--scratch-path requires a path.")
                    }

                    scratchArguments += [argument, path]
                } else if argument.hasPrefix("--scratch-path=") || ["--disable-sandbox", "--disable-keychain"].contains(argument) {
                    scratchArguments.append(argument)
                }
            }
            return scratchArguments
        }

        /// Builds the package with indexing enabled, passing each line of build output to `onOutputLine`.
        public func build(additionalArguments: [String], onOutputLine: @escaping @Sendable (String) -> Void = { _ in }) throws {
            guard !additionalArguments.contains("--disable-index-store") else {
                throw LethenError.usageError("--disable-index-store conflicts with scanning a managed build. Remove it, or use --skip-build with --index-store-path for an externally built index.")
            }

            var arguments = ["swift", "build", "--build-tests"] + additionalArguments + ["--enable-index-store"]
            guard configuration.indexStorePath.isEmpty else {
                try shell.exec(arguments, onOutputLine: onOutputLine)
                return
            }

            let binary = try binaryDirectory(additionalArguments: additionalArguments)
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
            // In swiftbuild Release builds, --enable-index-store alone does
            // not put indexing flags on the Swift compiler invocation.
            let quotedStore = "'" + store.string.replacingOccurrences(of: "'", with: "'\\''") + "'"
            arguments += ["-Xswiftc", "-index-store-path", "-Xswiftc", quotedStore]

            // Indexing flags do not invalidate compiled tasks, so an existing tree can hold objects that
            // were never indexed or were recompiled without indexing. The build is reused only when
            // SPMIndexFreshness verifies it, and cleaned otherwise.
            try buildReusingIndex(arguments: arguments, additionalArguments: additionalArguments, binary: binary, store: store, onOutputLine: onOutputLine)
        }

        /// Builds incrementally when SPMIndexFreshness can prove the store matches the build, and cleans
        /// otherwise. The stamp is removed before any build it does not describe.
        private func buildReusingIndex(
            arguments: [String],
            additionalArguments: [String],
            binary: FilePath,
            store: FilePath,
            onOutputLine: @escaping @Sendable (String) -> Void
        ) throws {
            let logger = logger.contextualized(with: "spm:index-reuse")
            // swiftbuild keeps objects beside Products (.build/out), the native build system beside the triple.
            let freshness = SPMIndexFreshness(storePath: store, buildRoot: binary.removingLastComponent().removingLastComponent(), packageRoot: path)
            let stamp = try SPMIndexFreshness.Stamp(
                swiftVersion: SwiftVersion(shell: shell).fullVersion,
                buildArguments: additionalArguments
            )
            let sources = try packageSources()

            if binary.exists, store.exists, let previous = freshness.readStamp(), previous.stamp == stamp {
                // Only failures to read or verify the store fall back to cleaning; a failing build still throws.
                let preparation: SPMIndexFreshness.Preparation
                do {
                    preparation = try freshness.prepare(sources: sources, stampDate: previous.date)
                } catch {
                    preparation = .clean(reason: "the store could not be read: \(error)")
                }

                switch preparation {
                case let .clean(reason):
                    logger.debug("Index store not reusable, cleaning: \(reason)")
                case let .recompile(objects, modules):
                    try freshness.removeStamp()
                    for object in objects {
                        try FileManager.default.removeItem(atPath: object.string)
                    }

                    let start = Date()
                    try shell.exec(arguments, onOutputLine: onOutputLine)
                    let issues = verify(freshness, sources: sources, buildStart: start)
                    if issues.isEmpty {
                        logger.debug("Reused the index store; recompiled \(modules.count) modules (\(objects.count) objects): \(modules.sorted().joined(separator: ", "))")
                        try freshness.writeStamp(stamp)
                        return
                    }

                    logger.debug("Index store not reusable (\(issues.count) issues), cleaning: \(issues.prefix(3).joined(separator: "; "))")
                }
            } else {
                logger.debug("No matching build stamp, cleaning.")
            }

            try freshness.removeStamp()
            if binary.exists {
                try clean(additionalArguments: additionalArguments)
            }
            let start = Date()
            try shell.exec(arguments, onOutputLine: onOutputLine)
            let issues = verify(freshness, sources: sources, buildStart: start)
            guard issues.isEmpty else {
                // Leave no stamp, so the next scan cleans again; the scan itself proceeds as it does today.
                logger.debug("Clean build did not index every source (\(issues.count) issues): \(issues.prefix(3).joined(separator: "; "))")
                return
            }

            try freshness.writeStamp(stamp)
        }

        /// Verification issues, with a store that cannot be read reported as one.
        private func verify(_ freshness: SPMIndexFreshness, sources: Set<SPMIndexFreshness.Source>, buildStart: Date) -> [String] {
            do {
                return try freshness.verify(sources: sources, buildStart: buildStart).map(\.description)
            } catch {
                return ["the store could not be read: \(error)"]
            }
        }

        func packageSources() throws -> Set<SPMIndexFreshness.Source> {
            let description = try load()
            // Plugin scripts are compiled outside the build, so they never have units.
            return Set(description.targets.filter { $0.type != "plugin" }.flatMap { target in
                let module = target.c99name ?? target.name
                return (target.sources ?? [])
                    .filter { $0.hasSuffix(".swift") }
                    .map { SPMIndexFreshness.Source(path: path.appending(target.path).appending($0), module: module) }
            })
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
                let packageArguments = try Self.packageArguments(in: configuration.buildArguments)
                let jsonString = try shell.exec(["swift", "package"] + packageArguments + ["describe", "--type", "json"])

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
    /// The target's module name, as SwiftPM derives it.
    public let c99name: String?
    public let sources: [String]?
    public let resources: [Resource]?

    public var isTestTarget: Bool {
        type == "test"
    }
}

public struct Resource: Decodable {
    public let path: String
}
