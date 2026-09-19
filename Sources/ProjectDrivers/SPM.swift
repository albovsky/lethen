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
                        throw PeripheryError.usageError("--scratch-path requires a path.")
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
                throw PeripheryError.usageError("--disable-index-store conflicts with scanning a managed build. Remove it, or use --skip-build with --index-store-path for an externally built index.")
            }

            var arguments = ["swift", "build", "--build-tests"] + additionalArguments + ["--enable-index-store"]
            if configuration.indexStorePath.isEmpty {
                let binary = try binaryDirectory(additionalArguments: additionalArguments)
                let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
                // Swiftbuild can reuse objects from an auto-indexed build without
                // regenerating indexes when only index flags change.
                if binary.exists, !store.exists {
                    try clean(additionalArguments: additionalArguments)
                }
                // In swiftbuild Release builds, --enable-index-store alone does
                // not put indexing flags on the Swift compiler invocation.
                let quotedStore = "'" + store.string.replacingOccurrences(of: "'", with: "'\\''") + "'"
                arguments += ["-Xswiftc", "-index-store-path", "-Xswiftc", quotedStore]
            }
            try shell.exec(arguments)
        }

        public func indexStorePath(additionalArguments: [String]) throws -> FilePath {
            let binary = try binaryDirectory(additionalArguments: additionalArguments)
            let store = try SPMIndexStoreLocator.indexStorePath(binPath: binary)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: store.string, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PeripheryError.packageError(message: "Index store does not exist at \(store.string) (resolved by 'swift build --show-bin-path \(additionalArguments.joined(separator: " ")) --enable-index-store'). Build the selected configuration with indexing enabled, or use --index-store-path for an externally built index.")
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
                throw PeripheryError.packageError(message: "Expected one absolute binary directory from '\(query.joined(separator: " "))', received: \(output)")
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
                    throw PeripheryError.packageError(message: "Failed to read swift package description.")
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
    public let resources: [Resource]?

    public var isTestTarget: Bool {
        type == "test"
    }
}

public struct Resource: Decodable {
    public let path: String
}
