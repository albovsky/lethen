import Configuration
import Foundation
import Indexer
import IndexStore
import Logger
import Shared
import SystemPackage

public final class SPMProjectDriver {
    private let pkg: SPM.Package
    private let configuration: Configuration
    private let logger: Logger

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

            try BuildProgress(configuration: configuration, logger: logger).run { onOutputLine in
                for arguments in buildArgumentSets {
                    try pkg.build(additionalArguments: arguments, onOutputLine: onOutputLine)
                }
                // A build that cannot reuse its tree runs `swift package clean`, which also removes the
                // products of the configurations built before it. Build those again; with their products
                // gone, they cannot clean in turn.
                for arguments in buildArgumentSets.dropLast() where try !pkg.hasIndexStore(additionalArguments: arguments) {
                    try pkg.build(additionalArguments: arguments, onOutputLine: onOutputLine)
                }
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
        if let warning = Self.buildBoundaryWarning(description: description, configuration: configuration) {
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

        return IndexPlan(
            sourceFiles: sourceFiles,
            xibPaths: xibPaths
        )
    }

    /// Excluded targets can be the only consumers of a scanned target's public API. Says so, naming
    /// the modules to pass to `--retain-public-targets`.
    static func buildBoundaryWarning(description: PackageDescription, configuration: Configuration) -> String? {
        guard !configuration.retainPublic else { return nil }

        let excluded = description.targets.filter {
            (configuration.excludeTests && $0.isTestTarget) || configuration.excludeTargets.contains($0.name)
        }
        guard !excluded.isEmpty else { return nil }

        let targetsByName = Dictionary(description.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let excludedNames = Set(excluded.map(\.name))
        let retained = Set(configuration.retainPublicTargets)
        let consumed = Set(excluded.flatMap { $0.targetDependencies ?? [] })
            .subtracting(excludedNames)
            .compactMap { targetsByName[$0] }
            .map { $0.c99name ?? $0.name }
            .filter { !retained.contains($0) }
            .sorted()
        guard !consumed.isEmpty else { return nil }

        return "Targets \(excludedNames.sorted().joined(separator: ", ")) are excluded from the scan but depend on \(consumed.joined(separator: ", ")). Public declarations used only from the excluded targets will be reported; pass --retain-public-targets \(consumed.joined(separator: " ")) to keep them."
    }

    // MARK: - Private

    /// One argument set per configuration, or the plain build arguments.
    private var buildArgumentSets: [[String]] {
        configuration.configurations.isEmpty
            ? [configuration.buildArguments]
            : configuration.configurations.map { configuration.buildArguments + ["-c", $0] }
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
