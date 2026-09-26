import Configuration
import Foundation
import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

public struct SourceFileCollector {
    private let indexStorePaths: Set<FilePath>
    private let excludedTestTargets: Set<String>
    private let requireFreshUnits: Bool
    private let logger: ContextualLogger
    private let configuration: Configuration

    /// - Parameter requireFreshUnits: drop units older than their source file, and fail with
    ///   `LethenError.staleIndexStore` when a source file has units but none as new as the file. Used for
    ///   stores lethen did not just build, such as `--skip-build` scans; an explicit `--index-store-path`
    ///   stays authoritative.
    public init(
        indexStorePaths: Set<FilePath>,
        excludedTestTargets: Set<String>,
        requireFreshUnits: Bool = false,
        logger: ContextualLogger,
        configuration: Configuration
    ) {
        self.indexStorePaths = indexStorePaths
        self.excludedTestTargets = excludedTestTargets
        self.requireFreshUnits = requireFreshUnits
        self.logger = logger
        self.configuration = configuration
    }

    public func collect() throws -> [SourceFile: [IndexUnit]] {
        let excludedTargets = excludedTestTargets.union(configuration.excludeTargets)
        let currentFilePath = FilePath.current

        let collected = try JobPool(jobs: Array(indexStorePaths))
            .flatMap { indexStorePath in
                logger.debug("Reading \(indexStorePath)")
                let indexStore = try IndexStore(path: indexStorePath.string)
                let unitsDirectory = requireFreshUnits ? try Self.unitsDirectory(in: indexStorePath) : nil

                return indexStore.units.filter { !$0.isSystem }.compactMap { unit -> CollectedUnit? in
                    let filePath = unit.mainFile

                    guard !filePath.isEmpty else {
                        return nil
                    }

                    let file = FilePath.makeAbsolute(filePath, relativeTo: currentFilePath)

                    if !isExcluded(file) {
                        guard file.exists else {
                            logger.debug("Source file does not exist: \(file.string)")
                            return nil
                        }

                        if excludedTargets.contains(unit.moduleName) {
                            return nil
                        }

                        let isFresh = unitsDirectory.map { Self.isUnit(unit, in: $0, asNewAs: file) } ?? true
                        return CollectedUnit(file: file, store: indexStore, storePath: indexStorePath, unit: unit, module: unit.moduleName, isFresh: isFresh)
                    }

                    return nil
                }
            }

        var staleFiles: [FilePath: FilePath] = [:]
        var result: [SourceFile: [IndexUnit]] = [:]
        for (file, units) in Dictionary(grouping: collected, by: \.file) {
            let fresh = units.filter(\.isFresh)
            guard !fresh.isEmpty else {
                staleFiles[file] = units[0].storePath
                continue
            }

            if fresh.count < units.count {
                logger.debug("Ignoring \(units.count - fresh.count) units older than \(file.string)")
            }

            let sourceFile = SourceFile(path: file, modules: fresh.mapSet(\.module))
            result[sourceFile] = fresh.map { IndexUnit(store: $0.store, unit: $0.unit) }
        }

        if let store = staleFiles.values.min() {
            throw LethenError.staleIndexStore(path: store.string, staleFiles: staleFiles.keys.map(\.string).sorted())
        }

        return result
    }

    // MARK: - Private

    private struct CollectedUnit {
        let file: FilePath
        let store: IndexStore
        let storePath: FilePath
        let unit: UnitReader
        let module: String
        let isFresh: Bool
    }

    private func isExcluded(_ file: FilePath) -> Bool {
        configuration.indexExcludeMatchers.anyMatch(filename: file.string)
    }

    /// The directory of unit files, whose modification dates are when each unit was written.
    private static func unitsDirectory(in store: FilePath) throws -> FilePath {
        let versions = try FileManager.default.contentsOfDirectory(atPath: store.string)
            .filter { $0.hasPrefix("v") && Int($0.dropFirst()) != nil }
        guard versions.count == 1, let version = versions.first else {
            throw LethenError.indexStoreNotFound(derivedDataPath: store.string)
        }

        return store.appending(version).appending("units")
    }

    private static func isUnit(_ unit: UnitReader, in unitsDirectory: FilePath, asNewAs file: FilePath) -> Bool {
        guard let unitDate = modificationDate(unitsDirectory.appending(unit.name)),
              let fileDate = modificationDate(file)
        else { return false }

        return unitDate >= fileDate
    }

    private static func modificationDate(_ path: FilePath) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.string))?[.modificationDate] as? Date
    }
}
