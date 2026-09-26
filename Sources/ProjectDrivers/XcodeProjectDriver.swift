#if os(macOS)
    import Configuration
    import Foundation
    import Indexer
    import Logger
    import Shared
    import SourceGraph
    import SystemPackage
    import XcodeSupport

    public final class XcodeProjectDriver {
        private let logger: Logger
        private let configuration: Configuration
        private let xcodebuild: Xcodebuild
        private let project: XcodeProjectlike
        private let schemes: Set<String>
        private let derivedDataLocator: XcodeDerivedDataLocator

        public convenience init(
            projectPath: FilePath,
            configuration: Configuration,
            shell: Shell,
            logger: Logger
        ) throws {
            if configuration.outputFormat.supportsAuxiliaryOutput {
                let asterisk = logger.colorize("*", .boldGreen)
                logger.info("\(asterisk) Inspecting project...")
            }

            let xcodebuild = Xcodebuild(shell: shell, logger: logger)

            guard !configuration.schemes.isEmpty else {
                throw LethenError.usageError("The '--schemes' option is required.")
            }

            try xcodebuild.ensureConfigured()

            let project: XcodeProjectlike
            if projectPath.extension == "xcworkspace" {
                project = try XcodeWorkspace(
                    path: .makeAbsolute(projectPath),
                    xcodebuild: xcodebuild,
                    configuration: configuration,
                    logger: logger,
                    shell: shell
                )
            } else {
                var loadedProjectPaths: Set<FilePath> = []
                project = try XcodeProject(
                    path: .makeAbsolute(projectPath),
                    loadedProjectPaths: &loadedProjectPaths,
                    xcodebuild: xcodebuild,
                    shell: shell,
                    logger: logger
                )
            }

            let schemes: Set<String>

            if configuration.skipSchemesValidation {
                schemes = Set(configuration.schemes)
            } else {
                // Ensure schemes exist within the project
                schemes = try project.schemes(
                    additionalArguments: configuration.xcodeListArguments
                ).filter { configuration.schemes.contains($0) }
                let validSchemeNames = schemes.mapSet { $0 }

                if let scheme = Set(configuration.schemes).subtracting(validSchemeNames).first {
                    throw LethenError.invalidScheme(name: scheme, project: project.path.lastComponent?.string ?? "")
                }
            }

            self.init(
                logger: logger,
                configuration: configuration,
                xcodebuild: xcodebuild,
                project: project,
                schemes: schemes
            )
        }

        init(
            logger: Logger,
            configuration: Configuration,
            xcodebuild: Xcodebuild,
            project: XcodeProjectlike,
            schemes: Set<String>,
            derivedDataLocator: XcodeDerivedDataLocator = XcodeDerivedDataLocator()
        ) {
            self.logger = logger
            self.configuration = configuration
            self.xcodebuild = xcodebuild
            self.project = project
            self.schemes = schemes
            self.derivedDataLocator = derivedDataLocator
        }
    }

    extension XcodeProjectDriver: ProjectDriver {
        public func build() throws {
            guard !configuration.skipBuild else { return }

            if configuration.cleanBuild {
                try xcodebuild.removeDerivedData(for: project, allSchemes: Array(schemes))
            }

            for scheme in schemes {
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let asterisk = logger.colorize("*", .boldGreen)
                    logger.info("\(asterisk) Building \(scheme)...")
                }

                try xcodebuild.build(project: project,
                                     scheme: scheme,
                                     allSchemes: Array(schemes),
                                     additionalArguments: configuration.buildArguments)
            }
        }

        public func plan(logger: ContextualLogger) throws -> IndexPlan {
            let indexStorePaths: Set<FilePath> = if !configuration.indexStorePath.isEmpty {
                Set(configuration.indexStorePath)
            } else if configuration.skipBuild {
                try [skipBuildIndexStore()]
            } else {
                try [xcodebuild.indexStorePath(project: project, schemes: Array(schemes))]
            }

            let targets = project.targets
            try targets.forEach { try $0.identifyFiles() }
            let excludedTestTargets = configuration.excludeTests ? project.targets.filter(\.isTestTarget).mapSet(\.name) : []
            let collector = SourceFileCollector(
                indexStorePaths: indexStorePaths,
                excludedTestTargets: excludedTestTargets,
                // A store lethen did not just build may predate edits; an explicit path stays authoritative.
                requireFreshUnits: configuration.skipBuild && configuration.indexStorePath.isEmpty,
                logger: logger,
                configuration: configuration
            )
            let sourceFiles = try collector.collect()
            let infoPlistPaths = targets.flatMapSet { $0.files(kind: .infoPlist) }
            let xibPaths = targets.flatMapSet { $0.files(kind: .interfaceBuilder) }
            let xcDataModelPaths = targets.flatMapSet { $0.files(kind: .xcDataModel) }
            let xcMappingModelPaths = targets.flatMapSet { $0.files(kind: .xcMappingModel) }

            return IndexPlan(
                sourceFiles: sourceFiles,
                plistPaths: infoPlistPaths,
                xibPaths: xibPaths,
                xcDataModelPaths: xcDataModelPaths,
                xcMappingModelPaths: xcMappingModelPaths
            )
        }

        // MARK: - Private

        /// Without a build, the index is either lethen's own from an earlier scan or the one Xcode keeps
        /// for this project in its DerivedData; the most recently written one is used, and named.
        private func skipBuildIndexStore() throws -> FilePath {
            let own = try? xcodebuild.indexStorePath(project: project, schemes: Array(schemes))
            let candidates = ([own].compactMap(\.self) + derivedDataLocator.indexStores(for: project.path))
                .map { ($0, XcodeDerivedDataLocator.lastWritten($0)) }
            guard let (store, date) = candidates.max(by: { $0.1 < $1.1 }) else {
                throw LethenError.usageError("--skip-build found no index for \(project.path). Build the project in Xcode, scan once without --skip-build, or pass --index-store-path.")
            }

            if configuration.outputFormat.supportsAuxiliaryOutput {
                let source = store == own ? "lethen's previous build" : "Xcode's DerivedData"
                logger.info("Using the index from \(source) at \(store), last written \(date.formatted(.iso8601)).")
            }

            return store
        }
    }
#endif
