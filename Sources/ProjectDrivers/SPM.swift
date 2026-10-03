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
        ///
        /// - Returns: the modules of targets this build does not compile, such as executables used only by command
        ///   plugins. They have no index units and are not scanned. Empty when an explicit index store is used.
        @discardableResult
        public func build(additionalArguments: [String], onOutputLine: @escaping @Sendable (String) -> Void = { _ in }) throws -> Set<String> {
            guard !additionalArguments.contains("--disable-index-store") else {
                throw LethenError.usageError("--disable-index-store conflicts with scanning a managed build. Remove it, or use --skip-build with --index-store-path for an externally built index.")
            }

            var arguments = ["swift", "build", "--build-tests"] + additionalArguments + ["--enable-index-store"]
            guard configuration.indexStorePath.isEmpty else {
                try shell.exec(arguments, onOutputLine: onOutputLine)
                return []
            }

            let binary = try binaryDirectory(additionalArguments: additionalArguments)
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
            // In swiftbuild Release builds, --enable-index-store alone does
            // not put indexing flags on the Swift compiler invocation.
            arguments += ["-Xswiftc", "-index-store-path", "-Xswiftc", store.string]

            // Indexing flags do not invalidate compiled tasks, so an existing tree can hold objects that
            // were never indexed or were recompiled without indexing. The build is reused only when
            // SPMIndexFreshness verifies it, and cleaned otherwise.
            return try buildReusingIndex(arguments: arguments, additionalArguments: additionalArguments, binary: binary, store: store, onOutputLine: onOutputLine)
        }

        /// Builds incrementally when SPMIndexFreshness can prove the store matches the build, and cleans
        /// otherwise. The stamp is removed before any build it does not describe. Returns the modules of targets
        /// the build did not compile; they are known only when verification succeeded, and are otherwise empty.
        private func buildReusingIndex(
            arguments: [String],
            additionalArguments: [String],
            binary: FilePath,
            store: FilePath,
            onOutputLine: @escaping @Sendable (String) -> Void
        ) throws -> Set<String> {
            let logger = logger.contextualized(with: "spm:index-reuse")
            // swiftbuild keeps objects beside Products (.build/out), the native build system beside the triple.
            let freshness = SPMIndexFreshness(storePath: store, buildRoot: binary.removingLastComponent().removingLastComponent(), packageRoot: path)
            let stamp = try SPMIndexFreshness.Stamp(
                swiftVersion: SwiftVersion(shell: shell).fullVersion,
                buildArguments: additionalArguments
            )
            let sources = try packageSources()

            if binary.exists, store.exists, let previous = freshness.readStamp(), previous.stamp.describesSameBuild(as: stamp) {
                // Only failures to read or verify the store fall back to cleaning; a failing build still throws.
                let preparation: SPMIndexFreshness.Preparation
                do {
                    preparation = try freshness.prepare(sources: sources, stampDate: previous.date, unbuiltTargets: Set(previous.stamp.unbuiltTargets))
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
                    let verification = verify(freshness, sources: sources, buildStart: start)
                    if verification.issues.isEmpty {
                        logger.debug("Reused the index store; recompiled \(modules.count) modules (\(objects.count) objects): \(modules.sorted().joined(separator: ", "))")
                        return try writeStamp(stamp, unbuiltTargets: verification.unbuiltTargets, freshness: freshness, logger: logger)
                    }

                    logger.debug("Index store not reusable (\(verification.issues.count) issues), cleaning: \(verification.issues.prefix(3).joined(separator: "; "))")
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
            let verification = verify(freshness, sources: sources, buildStart: start)
            guard verification.issues.isEmpty else {
                // Leave no stamp, so the next scan cleans again; the scan itself proceeds as it does today.
                logger.debug("Clean build did not index every source (\(verification.issues.count) issues): \(verification.issues.prefix(3).joined(separator: "; "))")
                return []
            }

            return try writeStamp(stamp, unbuiltTargets: verification.unbuiltTargets, freshness: freshness, logger: logger)
        }

        private func writeStamp(
            _ stamp: SPMIndexFreshness.Stamp,
            unbuiltTargets: Set<String>,
            freshness: SPMIndexFreshness,
            logger: ContextualLogger
        ) throws -> Set<String> {
            var stamp = stamp
            stamp.unbuiltTargets = unbuiltTargets.sorted()
            try freshness.writeStamp(stamp)
            if !unbuiltTargets.isEmpty {
                logger.debug("Targets the build does not compile, so not scanned: \(stamp.unbuiltTargets.joined(separator: ", "))")
            }
            return unbuiltTargets
        }

        /// Verification issues, with a store that cannot be read reported as one.
        private func verify(_ freshness: SPMIndexFreshness, sources: Set<SPMIndexFreshness.Source>, buildStart: Date) -> (issues: [String], unbuiltTargets: Set<String>) {
            do {
                let verification = try freshness.verify(sources: sources, buildStart: buildStart)
                return (verification.issues.map(\.description), verification.unbuiltTargets)
            } catch {
                return (["the store could not be read: \(error)"], [])
            }
        }

        func packageSources() throws -> Set<SPMIndexFreshness.Source> {
            let description = try load()
            // Plugin scripts are compiled outside the build, so they never have units.
            return Set(description.targets.filter { $0.type != "plugin" }.flatMap { target in
                let module = target.c99name ?? target.name
                return (target.sources ?? [])
                    .filter { $0.hasSuffix(".swift") }
                    .map {
                        SPMIndexFreshness.Source(
                            path: path.appending(target.path).appending($0),
                            module: module,
                            directoryNames: Set([target.name, module] + (target.productMemberships ?? []))
                        )
                    }
            })
        }

        /// Whether the index store the build with these arguments writes exists.
        func hasIndexStore(additionalArguments: [String]) throws -> Bool {
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binaryDirectory(additionalArguments: additionalArguments))
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: store.string, isDirectory: &isDirectory) && isDirectory.boolValue
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
    /// The package's products; absent from hand-written manifest JSON that lists only targets.
    public let products: [PackageProduct]?
}

public struct PackageProduct: Decodable {
    /// The product type SwiftPM reports, such as `library`, `executable`, `plugin`, or `macro`.
    public let kind: String

    enum CodingKeys: String, CodingKey {
        case type
    }

    /// SwiftPM encodes the type as an object with one key, such as `{"library": ["automatic"]}`.
    private struct TypeKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.nestedContainer(keyedBy: TypeKey.self, forKey: .type).allKeys.first?.stringValue ?? ""
    }
}

public struct Target: Decodable {
    public let name: String
    public let type: String
    public let path: String
    /// The target's module name, as SwiftPM derives it.
    public let c99name: String?
    public let sources: [String]?
    public let resources: [Resource]?
    /// Names of the package targets this target depends on.
    public let targetDependencies: [String]?
    /// Names of the products that contain this target; absent from hand-written manifest JSON.
    public let productMemberships: [String]?

    public var isTestTarget: Bool {
        type == "test"
    }
}

public struct Resource: Decodable {
    public let path: String
}
