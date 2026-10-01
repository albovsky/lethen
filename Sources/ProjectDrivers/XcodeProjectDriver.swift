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
        /// The lock on the DerivedData this scan builds into or reads without a build. It is held for the driver's
        /// lifetime, since the index pipeline reads the stores' records long after `plan()` returns.
        private var derivedDataLock: DerivedDataLock?

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

            try Self.validateConfigurations(configuration, project: project)

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

            // A lock this driver already holds would block its own new one, since `flock` locks per open file.
            derivedDataLock?.release()
            derivedDataLock = try xcodebuild.lockDerivedData(
                project: project,
                schemes: Array(schemes),
                configurations: buildConfigurations,
                buildArguments: configuration.buildArguments,
                exclusive: true
            )
            // A scan whose build failed reads nothing, so it lets other scans in at once.
            var succeeded = false
            defer {
                if !succeeded {
                    derivedDataLock?.release()
                    derivedDataLock = nil
                }
            }

            if configuration.cleanBuild {
                for buildConfiguration in buildConfigurations {
                    try xcodebuild.removeDerivedData(
                        for: project,
                        allSchemes: Array(schemes),
                        configuration: buildConfiguration,
                        buildArguments: configuration.buildArguments
                    )
                }
            }

            // Every scheme builds into each configuration's one DerivedData directory, so a configuration is complete
            // only once all of them have built.
            for buildConfiguration in buildConfigurations {
                try xcodebuild.beginBuild(
                    project: project,
                    schemes: Array(schemes),
                    configuration: buildConfiguration,
                    buildArguments: configuration.buildArguments
                )
            }

            for scheme in schemes.sorted() {
                let schemeConfigurations = project.schemeConfigurations(named: scheme)
                if let warning = Self.configurationMismatchWarning(scheme: scheme, schemeConfigurations: schemeConfigurations, configuration: configuration) {
                    logger.warn(warning)
                }

                for buildConfiguration in buildConfigurations {
                    if configuration.outputFormat.supportsAuxiliaryOutput {
                        let asterisk = logger.colorize("*", .boldGreen)
                        logger.info("\(asterisk) \(Self.buildDescription(scheme: scheme, listedConfiguration: buildConfiguration, schemeConfigurations: schemeConfigurations, buildArguments: configuration.buildArguments))...")
                    }

                    try BuildProgress(configuration: configuration, logger: logger).run { onOutputLine in
                        try xcodebuild.build(project: project,
                                             scheme: scheme,
                                             allSchemes: Array(schemes),
                                             configuration: buildConfiguration,
                                             additionalArguments: configuration.buildArguments,
                                             onOutputLine: onOutputLine)
                    }
                }
            }

            for buildConfiguration in buildConfigurations {
                try xcodebuild.completeBuild(
                    project: project,
                    schemes: Array(schemes),
                    configuration: buildConfiguration,
                    buildArguments: configuration.buildArguments
                )
            }
            succeeded = true
        }

        public func plan(logger: ContextualLogger) throws -> IndexPlan {
            let indexStorePaths: Set<FilePath>
            if !configuration.indexStorePath.isEmpty {
                indexStorePaths = Set(configuration.indexStorePath)
            } else if configuration.skipBuild {
                // A scan building into Lethen's own stores meanwhile waits rather than changing them underneath this one.
                derivedDataLock?.release()
                derivedDataLock = try xcodebuild.lockDerivedData(
                    project: project,
                    schemes: Array(schemes),
                    configurations: buildConfigurations,
                    buildArguments: configuration.buildArguments,
                    exclusive: false
                )
                indexStorePaths = try configuration.configurations.isEmpty ? [skipBuildIndexStore()] : skipBuildConfigurationIndexStores()
            } else {
                // One store per configuration; the collector keeps every store's units, so a reference
                // compiled in any configuration counts.
                indexStorePaths = try buildConfigurations.mapSet {
                    try xcodebuild.indexStorePath(
                        project: project,
                        schemes: Array(schemes),
                        configuration: $0,
                        buildArguments: configuration.buildArguments
                    )
                }
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
                sourceFiles: sourceFiles.sourceFiles,
                clangSourceFiles: sourceFiles.clangSourceFiles,
                plistPaths: infoPlistPaths,
                xibPaths: xibPaths,
                xcDataModelPaths: xcDataModelPaths,
                xcMappingModelPaths: xcMappingModelPaths
            )
        }

        // MARK: - Private

        /// The configurations to build, each into its own DerivedData; `nil` builds the scheme's Test action configuration.
        private var buildConfigurations: [String?] {
            configuration.configurations.isEmpty ? [nil] : configuration.configurations.removingDuplicates()
        }

        /// Without a build, the index is either lethen's own from an earlier scan or the one Xcode keeps
        /// for this project in its DerivedData; the most recently written one is used, and named.
        private func skipBuildIndexStore() throws -> FilePath {
            let own = try? xcodebuild.indexStorePath(project: project, schemes: Array(schemes), buildArguments: configuration.buildArguments)
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

        /// Without a build, `--configurations` reads the index of Lethen's last completed build of each configuration.
        /// Xcode's own DerivedData holds whichever configuration it last built, so it is never a stand-in for one of them.
        private func skipBuildConfigurationIndexStores() throws -> Set<FilePath> {
            var stores: [(configuration: String, path: FilePath)] = []
            var missing: [String] = []
            for case let buildConfiguration? in buildConfigurations {
                do {
                    let store = try xcodebuild.indexStorePath(
                        project: project,
                        schemes: Array(schemes),
                        configuration: buildConfiguration,
                        buildArguments: configuration.buildArguments
                    )
                    let completed = try xcodebuild.hasCompletedBuild(
                        project: project,
                        schemes: Array(schemes),
                        configuration: buildConfiguration,
                        buildArguments: configuration.buildArguments
                    )
                    guard completed else {
                        missing.append(buildConfiguration)
                        continue
                    }

                    stores.append((buildConfiguration, store))
                } catch LethenError.indexStoreNotFound {
                    missing.append(buildConfiguration)
                }
            }

            guard missing.isEmpty else {
                let names = (missing.count == 1 ? "configuration " : "configurations ") + missing.map(Self.shellWord).joined(separator: " ")
                throw LethenError.usageError("--skip-build found no index from a completed Lethen build of \(names). Scan once with --configurations and without --skip-build, or pass each configuration's store with --index-store-path.")
            }

            if configuration.outputFormat.supportsAuxiliaryOutput {
                for (name, store) in stores {
                    logger.info("Using the index from Lethen's build of configuration \(name) at \(store), last written \(XcodeDerivedDataLocator.lastWritten(store).formatted(.iso8601)).")
                }
            }

            return stores.mapSet(\.path)
        }
    }

    extension XcodeProjectDriver {
        /// `--configurations` selects the configurations itself, so each must exist in the project and the build
        /// arguments must not pick another one.
        static func validateConfigurations(_ configuration: Configuration, project: XcodeProjectlike) throws {
            guard !configuration.configurations.isEmpty else { return }

            if configuration.buildArguments.contains("-configuration") {
                throw LethenError.usageError("--configurations already selects the build configuration; remove -configuration from the build arguments.")
            }

            let known = project.buildConfigurationNames
            let unknown = configuration.configurations.filter { !known.contains($0) }.removingDuplicates()
            if !unknown.isEmpty {
                let available = known.sorted().joined(separator: ", ")
                throw LethenError.usageError("--configurations names \(unknown.joined(separator: ", ")), which \(project.path.lastComponent?.string ?? "the project") does not define. Its build configurations are: \(available).")
            }
        }
    }

    extension XcodeProjectDriver {
        /// What a build of `scheme` compiles, such as "Building Wikipedia with configuration Test". The configuration is
        /// the listed one, then a `-configuration` in the build arguments, then the scheme's Test action configuration;
        /// a scheme without a file names none.
        static func buildDescription(
            scheme: String,
            listedConfiguration: String?,
            schemeConfigurations: XcodeSchemeConfigurations?,
            buildArguments: [String]
        ) -> String {
            let builtConfiguration = listedConfiguration
                ?? buildArguments.firstIndex(of: "-configuration").flatMap { buildArguments[safe: $0 + 1] }
                ?? schemeConfigurations?.test
            guard let builtConfiguration else { return "Building \(scheme)" }

            return "Building \(scheme) with configuration \(builtConfiguration)"
        }

        /// `build-for-testing` compiles the scheme's Test configuration, so code compiled only in the configuration the
        /// app runs with is invisible to the scan. Warns when the two differ and the user has not chosen a configuration.
        static func configurationMismatchWarning(
            scheme: String,
            schemeConfigurations: XcodeSchemeConfigurations?,
            configuration: Configuration
        ) -> String? {
            guard configuration.configurations.isEmpty,
                  !configuration.buildArguments.contains("-configuration"),
                  let test = schemeConfigurations?.test,
                  let launch = schemeConfigurations?.launch,
                  test != launch
            else { return nil }

            return "Scheme \(scheme) builds for testing with configuration \(test) but runs with \(launch), so code compiled only in \(launch), such as an #if branch, is reported as unused. Pass --configurations \(shellWord(test)) \(shellWord(launch)) to scan both."
        }

        /// `name` as one shell word, single-quoted when it holds anything but letters, digits, and `.`, `_`, `+`
        /// or `-`, so a configuration such as `App Store` can be pasted into a command line.
        static func shellWord(_ name: String) -> String {
            let plain = !name.isEmpty && name.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._+-".unicodeScalars.contains($0)
            }
            guard !plain else { return name }

            return "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private extension Array where Element: Hashable {
        func removingDuplicates() -> [Element] {
            var seen: Set<Element> = []
            return filter { seen.insert($0).inserted }
        }
    }
#endif
