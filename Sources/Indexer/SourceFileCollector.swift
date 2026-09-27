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

    /// A store can hold units for several versions of one file, such as an Xcode index built for
    /// several destinations over time. Their declarations conflict, so each file is indexed from one
    /// version: the units written after the file last changed, or, when every unit is older, the most
    /// recently written version, identified by its content-addressed main record.
    ///
    /// - Parameter requireFreshUnits: fail with `LethenError.staleIndexStore` instead when a source file
    ///   has units but none as new as the file. Used for stores lethen did not just build, such as
    ///   `--skip-build` scans; an explicit `--index-store-path` stays authoritative.
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
                // Without unit dates every unit counts as current, which is how stores were read before.
                let unitsDirectory = requireFreshUnits ? try Self.unitsDirectory(in: indexStorePath) : try? Self.unitsDirectory(in: indexStorePath)

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

                        let date = unitsDirectory.flatMap { Self.modificationDate($0.appending(unit.name)) }
                        let isFresh = unitsDirectory == nil || Self.isDate(date, asNewAs: file)
                        return CollectedUnit(
                            file: file,
                            store: indexStore,
                            storePath: indexStorePath,
                            unit: unit,
                            module: unit.moduleName,
                            date: date ?? .distantPast,
                            isFresh: isFresh
                        )
                    }

                    return nil
                }
            }

        var staleFiles: [FilePath: FilePath] = [:]
        var result: [SourceFile: [IndexUnit]] = [:]
        for (file, units) in Dictionary(grouping: collected, by: \.file) {
            var chosen = units.filter(\.isFresh)
            if chosen.isEmpty {
                if requireFreshUnits {
                    staleFiles[file] = units[0].storePath
                    continue
                }

                chosen = Self.newestVersion(of: units)
            }

            if chosen.count < units.count {
                logger.debug("Ignoring \(units.count - chosen.count) units for an older version of \(file.string)")
            }

            chosen.sort { ($0.storePath, $0.unit.name) < ($1.storePath, $1.unit.name) }
            let sourceFile = SourceFile(path: file, modules: chosen.mapSet(\.module))
            result[sourceFile] = chosen.map { IndexUnit(store: $0.store, unit: $0.unit) }
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
        let date: Date
        let isFresh: Bool
    }

    /// The units that indexed the same content as the most recently written unit. Units of one version
    /// share the record of the main file, whose name is derived from its content.
    private static func newestVersion(of units: [CollectedUnit]) -> [CollectedUnit] {
        guard let newest = units.max(by: { ($0.date, $0.unit.name) < ($1.date, $1.unit.name) }) else { return [] }

        let record = newest.unit.recordName
        return units.filter { $0.unit.recordName == record }
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

    private static func isDate(_ unitDate: Date?, asNewAs file: FilePath) -> Bool {
        guard let unitDate, let fileDate = modificationDate(file) else { return false }

        return unitDate >= fileDate
    }

    private static func modificationDate(_ path: FilePath) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.string))?[.modificationDate] as? Date
    }
}
