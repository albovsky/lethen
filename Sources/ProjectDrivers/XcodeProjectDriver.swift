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

            let requestedSchemes: [String]
            if configuration.schemes.isEmpty {
                let scheme = try Self.defaultScheme(
                    for: project,
                    listedSchemes: { try project.schemes(additionalArguments: configuration.xcodeListArguments) }
                )
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let projectName = project.path.lastComponent?.string ?? project.path.string
                    logger.info("Scanning scheme \(Self.shellWord(scheme)), the only shared scheme of \(projectName) (pass '--schemes' to choose others).")
                }
                requestedSchemes = [scheme]
            } else {
                requestedSchemes = configuration.schemes
            }

            let schemes: Set<String>

            if configuration.skipSchemesValidation {
                schemes = Set(requestedSchemes)
            } else {
                // Ensure schemes exist within the project
                schemes = try project.schemes(
                    additionalArguments: configuration.xcodeListArguments
                ).filter { requestedSchemes.contains($0) }
                let validSchemeNames = schemes.mapSet { $0 }

                if let scheme = Set(requestedSchemes).subtracting(validSchemeNames).first {
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

            // Only a store this scan built says that a target with no units was not compiled.
            let trustsAbsentUnits = !configuration.skipBuild && configuration.indexStorePath.isEmpty
            let projectTargets = targets
                .filter { !excludedTestTargets.contains($0.name) && !configuration.excludeTargets.contains($0.name) }
            let indexedFiles = Set(sourceFiles.sourceFiles.keys.map(\.path)).union(sourceFiles.clangSourceFiles.keys.map(\.path))
            let coverage = ClangCoverage.assess(
                targets: projectTargets.map { target in
                    let files = target.files(kind: .swiftSource).union(target.files(kind: .clangSource))
                    return ClangCoverage.Target(sourceFiles: files.filter(isCollectable))
                },
                indexedFiles: indexedFiles,
                trustsAbsentUnits: trustsAbsentUnits
            )
            if let warning = coverage.warning {
                self.logger.warn(warning)
            }

            let indexedModules = Dictionary(
                (sourceFiles.sourceFiles.keys.map { ($0.path, $0.modules) } + sourceFiles.clangSourceFiles.keys.map { ($0.path, $0.modules) }),
                uniquingKeysWith: { $0.union($1) }
            )
            let (unscannedTargets, unscannedDependencies) = trustsAbsentUnits
                ? self.unscannedTargets(among: projectTargets, indexedModules: indexedModules)
                : ([], [:])
            for warning in Self.unscannedTargetWarnings(for: unscannedTargets, scannedDependencies: unscannedDependencies) {
                self.logger.warn(warning)
            }

            return IndexPlan(
                sourceFiles: sourceFiles.sourceFiles,
                clangSourceFiles: sourceFiles.clangSourceFiles,
                plistPaths: infoPlistPaths,
                xibPaths: xibPaths,
                xcDataModelPaths: xcDataModelPaths,
                xcMappingModelPaths: xcMappingModelPaths,
                clangCoverage: coverage,
                unscannedTargets: unscannedTargets.filter { Self.unscannedTargetWarning(for: $0, scannedDependencies: unscannedDependencies[$0.name] ?? []) != nil }
            )
        }

        // MARK: - Private

        /// Whether the collector can read a unit for the file: it drops the files that match an index
        /// exclusion and the ones missing on disk.
        private func isCollectable(_ file: FilePath) -> Bool {
            file.exists && !configuration.indexExcludeMatchers.anyMatch(filename: file.string)
        }

        /// The targets of the project that no scanned scheme built: they compile Swift files, and no index unit
        /// belongs to any of them. Targets without a Swift file are left out, since only Swift files are read for the
        /// names they use. Also returns, by target name, the scanned targets each depends on.
        ///
        /// A file compiled into several targets has a unit for each target that built it, named by module, so a
        /// unit counts for a target unless the file's modules show another target of the project compiled it
        /// instead. A unit whose module matches no target, such as a clang one, counts for every target that
        /// compiles the file, which errs toward scanned.
        private func unscannedTargets(
            among projectTargets: Set<XcodeTarget>,
            indexedModules: [FilePath: Set<String>]
        ) -> ([UnscannedTarget], [String: [String]]) {
            let modules = Dictionary(indexedModules.map { ($0.key.lexicallyNormalized(), $0.value) }, uniquingKeysWith: { $0.union($1) })
            func compiledFiles(_ target: XcodeTarget) -> Set<FilePath> {
                target.files(kind: .swiftSource).union(target.files(kind: .clangSource)).filter(isCollectable).mapSet { $0.lexicallyNormalized() }
            }

            let compiled = Dictionary(uniqueKeysWithValues: projectTargets.map { ($0.name, compiledFiles($0)) })
            func isIndexed(_ file: FilePath, for target: XcodeTarget) -> Bool {
                guard let fileModules = modules[file] else { return false }

                let ownModule = Self.moduleName(forTarget: target.name)
                guard !fileModules.contains(ownModule) else { return true }

                let builtByAnother = projectTargets.contains {
                    $0.name != target.name && fileModules.contains(Self.moduleName(forTarget: $0.name)) && compiled[$0.name]?.contains(file) == true
                }
                return !builtByAnother
            }

            let scanned = projectTargets.filter { target in compiled[target.name, default: []].contains { isIndexed($0, for: target) } }
            let scannedNames = scanned.mapSet(\.name)
            let scannedSwiftFiles = scanned.flatMapSet { $0.files(kind: .swiftSource).filter(isCollectable).mapSet { $0.lexicallyNormalized() } }
            var unscanned: [UnscannedTarget] = []
            var dependencies: [String: [String]] = [:]
            for target in projectTargets where !scannedNames.contains(target.name) {
                guard compiled[target.name, default: []].isEmpty == false else { continue }

                let swiftFiles = target.files(kind: .swiftSource).filter(isCollectable).mapSet { $0.lexicallyNormalized() }
                guard !swiftFiles.isEmpty else { continue }

                unscanned.append(UnscannedTarget(name: target.name, swiftSourceFiles: swiftFiles, sharedSourceFiles: swiftFiles.intersection(scannedSwiftFiles)))
                dependencies[target.name] = target.dependencyNames.intersection(scannedNames).sorted()
            }
            return (unscanned.sorted { $0.name < $1.name }, dependencies)
        }

        /// The module Xcode names a target's Swift module by default: its name with every character that is not
        /// an ASCII letter or digit replaced by `_`, and a `_` ahead of a leading digit.
        static func moduleName(forTarget name: String) -> String {
            let identifier = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
            return identifier.first?.isNumber == true ? "_" + identifier : identifier
        }

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
        /// The warnings for the unscanned targets that use scanned code, sorted by target name.
        static func unscannedTargetWarnings(for targets: [UnscannedTarget], scannedDependencies: [String: [String]]) -> [String] {
            targets.sorted { $0.name < $1.name }.compactMap {
                unscannedTargetWarning(for: $0, scannedDependencies: scannedDependencies[$0.name] ?? [])
            }
        }

        /// A target no scanned scheme builds has no index unit, so what it uses of scanned code is invisible. That
        /// matters when it depends on a scanned target, or compiles a file a scanned target compiles too; says so,
        /// and what happens to the declarations its files name. `nil` for a target with neither tie.
        static func unscannedTargetWarning(for target: UnscannedTarget, scannedDependencies: [String]) -> String? {
            var ties: [String] = []
            if !scannedDependencies.isEmpty {
                ties.append("depends on \(scannedDependencies.joined(separator: ", "))")
            }
            if !target.sharedSourceFiles.isEmpty {
                let count = target.sharedSourceFiles.count
                ties.append("compiles \(count) \(count == 1 ? "file" : "files") the scanned targets compile")
            }
            guard !ties.isEmpty else { return nil }

            return "Target \(target.name) is in the project but not built by the scanned schemes, and it \(ties.joined(separator: " and ")), so its uses of scanned code are invisible; declarations it names are reported as likely rather than certain. Add a scheme that builds it to --schemes to scan it, or pass --exclude-targets \(shellWord(target.name)) to silence this."
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
        /// The scheme a scan without `--schemes` builds: the project's only shared scheme. With several, or none,
        /// the error lists what to pass; `listedSchemes` runs `xcodebuild -list` and is called only when no
        /// scheme is shared, since Xcode then usually still lists the user's own schemes.
        static func defaultScheme(for project: XcodeProjectlike, listedSchemes: () throws -> Set<String>) throws -> String {
            let name = project.path.lastComponent?.string ?? project.path.string
            let prefix = "The '--schemes' option is required: \(name)"
            let shared = project.sharedSchemes
            if shared.count == 1, let scheme = shared.first {
                return scheme
            }

            if shared.count > 1 {
                throw LethenError.usageError("\(prefix) shares several schemes. Pass one or more of: \(shared.map(shellWord).joined(separator: ", ")).")
            }

            let listed = try listedSchemes().sorted()
            if listed.isEmpty {
                throw LethenError.usageError("\(prefix) shares no scheme and xcodebuild lists none. Share a scheme in Xcode (Product > Scheme > Manage Schemes) or pass '--schemes'.")
            }

            throw LethenError.usageError("\(prefix) shares no scheme. Pass one or more of the schemes xcodebuild lists: \(listed.map(shellWord).joined(separator: ", ")).")
        }

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
