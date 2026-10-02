import Configuration
import Foundation
import Indexer
import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

public final class SPMProjectDriver {
    private let pkg: SPM.Package
    private let configuration: Configuration
    private let logger: Logger
    /// Modules of targets the managed build did not compile, from the last `build()`.
    private(set) var unbuiltTargets: Set<String> = []

    public convenience init(configuration: Configuration, shell: Shell, logger: Logger) throws {
        if !configuration.schemes.isEmpty {
            throw LethenError.usageError("The --schemes option has no effect with Swift Package Manager projects.")
        }

        let unknown = configuration.configurations.filter { !["debug", "release"].contains($0) }
        if !unknown.isEmpty {
            throw LethenError.usageError("--configurations accepts 'debug' and 'release' for Swift packages, not \(unknown.joined(separator: ", ")).")
        }
        if !configuration.configurations.isEmpty, configuration.buildArguments.contains(where: { $0 == "-c" || $0 == "--configuration" || $0.hasPrefix("--configuration=") }) {
            throw LethenError.usageError("--configurations already selects the build configuration; remove -c/--configuration from the build arguments.")
        }

        let pkg = SPM.Package(configuration: configuration, shell: shell, logger: logger)
        self.init(pkg: pkg, configuration: configuration, logger: logger)
    }

    init(pkg: SPM.Package, configuration: Configuration, logger: Logger) {
        self.pkg = pkg
        self.configuration = configuration
        self.logger = logger
    }
}

extension SPMProjectDriver: ProjectDriver {
    public func build() throws {
        if !configuration.skipBuild {
            if configuration.cleanBuild {
                // `swift package clean` removes every configuration's products, so once is enough.
                try pkg.clean(additionalArguments: configuration.buildArguments)
            }

            if configuration.outputFormat.supportsAuxiliaryOutput {
                let asterisk = logger.colorize("*", .boldGreen)
                logger.info("\(asterisk) Building...")
            }

            unbuiltTargets = try BuildProgress(configuration: configuration, logger: logger).run { onOutputLine in
                var unbuilt: Set<String> = []
                for arguments in buildArgumentSets {
                    try unbuilt.formUnion(pkg.build(additionalArguments: arguments, onOutputLine: onOutputLine))
                }
                // A build that cannot reuse its tree runs `swift package clean`, which also removes the
                // products of the configurations built before it. Build those again; with their products
                // gone, they cannot clean in turn.
                for arguments in buildArgumentSets.dropLast() where try !pkg.hasIndexStore(additionalArguments: arguments) {
                    try unbuilt.formUnion(pkg.build(additionalArguments: arguments, onOutputLine: onOutputLine))
                }
                return unbuilt
            }
        }
    }

    public func plan(logger: ContextualLogger) throws -> IndexPlan {
        let indexStorePaths: Set<FilePath> = if !configuration.indexStorePath.isEmpty {
            Set(configuration.indexStorePath)
        } else {
            try Set(buildArgumentSets.map { try pkg.indexStorePath(additionalArguments: $0) })
        }

        // Load package description once and reuse it
        let description = try pkg.load()
        if let warning = buildBoundaryWarning(description: description) {
            self.logger.warn(warning)
        }

        let excludedTestTargets = configuration.excludeTests ? testTargetNames(from: description) : []
        let collector = SourceFileCollector(
            indexStorePaths: indexStorePaths,
            excludedTestTargets: excludedTestTargets,
            // A store lethen did not just build may predate edits; an explicit path stays authoritative.
            requireFreshUnits: configuration.skipBuild && configuration.indexStorePath.isEmpty,
            logger: logger,
            configuration: configuration
        )
        let sourceFiles = try collector.collect()
        let xibPaths = interfaceBuilderFiles(from: description)
        let coverage = clangCoverage(
            description: description,
            excludedTestTargets: excludedTestTargets,
            indexedFiles: Set(sourceFiles.sourceFiles.keys.map(\.path)).union(sourceFiles.clangSourceFiles.keys.map(\.path))
        )
        if let warning = coverage.warning {
            self.logger.warn(warning)
        }

        return IndexPlan(
            sourceFiles: sourceFiles.sourceFiles,
            clangSourceFiles: sourceFiles.clangSourceFiles,
            xibPaths: xibPaths,
            clangCoverage: coverage
        )
    }

    /// The warning for this driver's configuration and the targets its build did not compile.
    func buildBoundaryWarning(description: PackageDescription) -> String? {
        Self.buildBoundaryWarning(description: description, configuration: configuration, unbuiltTargets: unbuiltTargets)
    }

    /// Excluded targets, and targets the build does not compile, can be the only consumers of a scanned
    /// target's public API. Says so, naming the modules to pass to `--retain-public-targets`.
    static func buildBoundaryWarning(description: PackageDescription, configuration: Configuration, unbuiltTargets: Set<String> = []) -> String? {
        guard !configuration.retainPublic else { return nil }

        let excluded = description.targets.filter {
            (configuration.excludeTests && $0.isTestTarget) || configuration.excludeTargets.contains($0.name)
        }
        let unbuilt = description.targets.filter { unbuiltTargets.contains($0.c99name ?? $0.name) }
        let outside = excluded + unbuilt
        guard !outside.isEmpty else { return nil }

        let targetsByName = Dictionary(description.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let outsideNames = Set(outside.map(\.name))
        let retained = Set(configuration.retainPublicTargets)
        let consumed = Set(outside.flatMap { $0.targetDependencies ?? [] })
            .subtracting(outsideNames)
            .compactMap { targetsByName[$0] }
            .map { $0.c99name ?? $0.name }
            .filter { !retained.contains($0) }
            .sorted()
        guard !consumed.isEmpty else { return nil }

        let advice = "Public declarations used only from them will be reported; pass --retain-public-targets \(consumed.joined(separator: " ")) to keep them."
        // A target both excluded and never built is only excluded.
        let unbuiltOnlyNames = Set(unbuilt.map(\.name)).subtracting(excluded.map(\.name))
        guard !unbuiltOnlyNames.isEmpty else {
            return "Targets \(outsideNames.sorted().joined(separator: ", ")) are excluded from the scan but depend on \(consumed.joined(separator: ", ")). \(advice)"
        }

        let unbuiltNames = unbuiltOnlyNames.sorted().joined(separator: ", ")
        let excludedNames = Set(excluded.map(\.name)).sorted().joined(separator: ", ")
        let excludedClause = excluded.isEmpty ? "" : "Targets \(excludedNames) are excluded from the scan. "
        return "\(excludedClause)Targets \(unbuiltNames) are not compiled by `swift build --build-tests` (for example executables used only by command plugins), so they are not scanned, but they depend on \(consumed.joined(separator: ", ")). \(advice)"
    }

    // MARK: - Private

    /// One argument set per configuration, or the plain build arguments.
    private var buildArgumentSets: [[String]] {
        configuration.configurations.isEmpty
            ? [configuration.buildArguments]
            : configuration.configurations.map { configuration.buildArguments + ["-c", $0] }
    }

    /// Whether the index has a unit for every C and Objective-C file of the targets the scan covers.
    /// The collector drops files that match an index exclusion or are missing on disk, so they are
    /// not expected to have a unit.
    private func clangCoverage(description: PackageDescription, excludedTestTargets: Set<String>, indexedFiles: Set<FilePath>) -> ClangCoverage {
        let targets = description.targets
            .filter { $0.type != "plugin" && !excludedTestTargets.contains($0.name) && !configuration.excludeTargets.contains($0.name) }
            .map { target in
                let targetPath = pkg.path.appending(target.path)
                let files = (target.sources ?? []).map { targetPath.appending($0) }.filter {
                    $0.exists && !configuration.indexExcludeMatchers.anyMatch(filename: $0.string)
                }
                return ClangCoverage.Target(name: target.name, sourceFiles: Set(files))
            }
        return ClangCoverage.assess(targets: targets, indexedFiles: indexedFiles)
    }

    private func testTargetNames(from description: PackageDescription) -> Set<String> {
        description.targets.filter(\.isTestTarget).mapSet(\.name)
    }

    private func interfaceBuilderFiles(from description: PackageDescription) -> Set<FilePath> {
        var xibFiles: Set<FilePath> = []

        for target in description.targets {
            let targetPath = pkg.path.appending(target.path)

            guard let resources = target.resources else { continue }

            for resource in resources {
                // Resource.path is always a single file path
                let resourceFilePath = FilePath(resource.path)
                let resourcePath: FilePath = resourceFilePath.isAbsolute
                    ? resourceFilePath
                    : targetPath.appending(resource.path)

                // Check if the resource path exists and is a xib/storyboard file
                guard resourcePath.exists else { continue }
                guard let ext = resourcePath.extension?.lowercased(), ["xib", "storyboard"].contains(ext) else { continue }

                xibFiles.insert(resourcePath)
            }
        }

        return xibFiles
    }
}
