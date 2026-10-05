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
        /// Whether a configuration's store is the one an earlier Lethen build left, which `build()` found unchanged
        /// instead of building again. `plan()` then checks each file against its unit and builds when one is stale.
        private var reusedBuild = false

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
            // An option that cannot be applied stops the scan before a build that `plan()` would only then find useless.
            try validateQualifiedTargetOptions(among: project.targets)
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

            reusedBuild = false
            let reusable = reusableConfigurations()
            reusedBuild = !reusable.isEmpty
            try runBuilds(for: buildConfigurations.filter { !reusable.contains($0) })
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
            try validateQualifiedTargetOptions(among: targets)
            retainQualifiedPublicTargets(among: targets)
            let excludedTargets = targets.filter { Self.isExcluded($0, excludeTests: configuration.excludeTests, options: configuration.excludeTargets) }
            let excludedTestTargets = configuration.excludeTests ? Self.excludedTestModules(excluded: excludedTargets, among: targets) : []
            let excludedUnits = Self.excludedUnits(excluded: excludedTargets, among: targets, options: configuration.excludeTargets, excludeTests: configuration.excludeTests)
            func collector(requireFreshUnits: Bool) -> SourceFileCollector {
                SourceFileCollector(
                    indexStorePaths: indexStorePaths,
                    excludedTestTargets: excludedTestTargets,
                    excludedUnits: excludedUnits,
                    requireFreshUnits: requireFreshUnits,
                    logger: logger,
                    configuration: configuration
                )
            }

            // A store lethen did not just build may predate edits; an explicit path stays authoritative. A reused
            // build is checked the same way, and gives way to a build when a unit predates its file.
            let sourceFiles: CollectedSourceFiles
            do {
                sourceFiles = try collector(requireFreshUnits: (configuration.skipBuild && configuration.indexStorePath.isEmpty) || reusedBuild).collect()
            } catch let error as LethenError where reusedBuild {
                switch error {
                case let .staleIndexStore(_, staleFiles):
                    self.logger.info("The index from the last build is stale (\(staleFiles.count) \(staleFiles.count == 1 ? "file" : "files")); building.")
                case .indexStoreNotFound:
                    self.logger.info("The index from the last build is missing; building.")
                default:
                    throw error
                }

                try runBuilds(for: buildConfigurations)
                reusedBuild = false
                sourceFiles = try collector(requireFreshUnits: false).collect()
            }
            let infoPlistPaths = Self.files(ofKind: .infoPlist, in: targets, excluding: excludedTargets)
            let xibPaths = Self.files(ofKind: .interfaceBuilder, in: targets, excluding: excludedTargets)
            let xcDataModelPaths = Self.files(ofKind: .xcDataModel, in: targets, excluding: excludedTargets)
            let xcMappingModelPaths = Self.files(ofKind: .xcMappingModel, in: targets, excluding: excludedTargets)

            // Only a store this scan built says that a target with no units was not compiled.
            let trustsAbsentUnits = !configuration.skipBuild && configuration.indexStorePath.isEmpty
            let projectTargets = targets.subtracting(excludedTargets)
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

        /// A `Project/Target` option names one target, so it cannot be used when two projects of that name in different
        /// folders both define the target: their `path/Project.xcodeproj/Target` forms are the ones to pass.
        func validateQualifiedTargetOptions(among targets: Set<XcodeTarget>) throws {
            for (flag, options) in [("--exclude-targets", configuration.excludeTargets), ("--retain-public-targets", configuration.retainPublicTargets)] {
                for option in options where option.contains("/") {
                    let matches = targets.filter { $0.qualifiedName == option }
                    guard Set(matches.map(\.projectPath)).count > 1 else { continue }

                    let forms = matches.map(\.pathQualifiedName).sorted().map(Self.shellWord).joined(separator: ", ")
                    throw LethenError.usageError("\(flag) \(Self.shellWord(option)) names targets of projects in different folders; pass one of \(forms).")
                }
            }
        }

        /// `--retain-public-targets Project/Target` names one target, but declarations carry only their module, so the
        /// target's module names are retained too; a module a retained and another target share is retained for both.
        func retainQualifiedPublicTargets(among targets: Set<XcodeTarget>) {
            let retained = targets.filter { target in configuration.retainPublicTargets.contains { $0 != target.name && target.isNamedByQualifiedName($0) } }
            for target in retained.sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
                for module in target.moduleNames.sorted() {
                    if let other = targets.first(where: { !retained.contains($0) && $0.moduleNames.contains(module) && !configuration.retainPublicTargets.contains($0.name) }) {
                        logger.warn("\(target.qualifiedName) and \(other.qualifiedName) share the module \(module), which declarations carry instead of a target, so the public declarations of both are retained.")
                    }
                    if !configuration.retainPublicTargets.contains(module) {
                        configuration.retainPublicTargets.append(module)
                    }
                }
            }
        }

        /// Builds every scheme into each of `configurations`, which are marked complete once all their builds succeed.
        private func runBuilds(for configurations: [String?]) throws {
            guard !configurations.isEmpty else { return }

            // Every scheme builds into each configuration's one DerivedData directory, so a configuration is complete
            // only once all of them have built.
            for buildConfiguration in configurations {
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

                let actions = Self.buildActions(listed: listedConfigurations, schemeConfigurations: schemeConfigurations)
                for buildConfiguration in configurations {
                    let action = actions.first { $0.configuration == buildConfiguration }?.action ?? .buildForTesting
                    if configuration.outputFormat.supportsAuxiliaryOutput {
                        let asterisk = logger.colorize("*", .boldGreen)
                        logger.info("\(asterisk) \(Self.buildDescription(scheme: scheme, listedConfiguration: buildConfiguration, schemeConfigurations: schemeConfigurations, buildArguments: configuration.buildArguments, action: action))...")
                    }

                    try BuildProgress(configuration: configuration, logger: logger).run { onOutputLine in
                        try xcodebuild.build(project: project,
                                             scheme: scheme,
                                             allSchemes: Array(schemes),
                                             configuration: buildConfiguration,
                                             action: action,
                                             additionalArguments: configuration.buildArguments,
                                             onOutputLine: onOutputLine)
                    }
                }
            }

            for buildConfiguration in configurations {
                try xcodebuild.completeBuild(
                    project: project,
                    schemes: Array(schemes),
                    configuration: buildConfiguration,
                    buildArguments: configuration.buildArguments
                )
            }
        }

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
        /// compiles the file, which errs toward scanned. A target's module is any `PRODUCT_MODULE_NAME` its
        /// configurations set, otherwise the default derived from its name.
        func unscannedTargets(
            among projectTargets: Set<XcodeTarget>,
            indexedModules: [FilePath: Set<String>]
        ) -> ([UnscannedTarget], [String: [String]]) {
            let modules = Dictionary(indexedModules.map { ($0.key.lexicallyNormalized(), $0.value) }, uniquingKeysWith: { $0.union($1) })
            func compiledFiles(_ target: XcodeTarget) -> Set<FilePath> {
                target.files(kind: .swiftSource).union(target.files(kind: .clangSource)).filter(isCollectable).mapSet { $0.lexicallyNormalized() }
            }

            let compiled = Dictionary(uniqueKeysWithValues: projectTargets.map { ($0, compiledFiles($0)) })
            func isIndexed(_ file: FilePath, for target: XcodeTarget) -> Bool {
                guard let fileModules = modules[file] else { return false }

                let matched = fileModules.intersection(target.moduleNames)
                guard matched.isEmpty else {
                    // A unit whose module two targets share cannot say which of them built the file, so it proves
                    // neither; each of them still counts as scanned through a file only it compiles. Units of
                    // distinct modules each belong to their own target.
                    return !projectTargets.contains {
                        $0 != target && !matched.isDisjoint(with: $0.moduleNames) && compiled[$0]?.contains(file) == true
                    }
                }

                let builtByAnother = projectTargets.contains {
                    $0 != target && !fileModules.isDisjoint(with: $0.moduleNames) && compiled[$0]?.contains(file) == true
                }
                return !builtByAnother
            }

            // Targets are told apart by their project, so same-named targets of two projects stay two. They are
            // labelled by name, by `Project/Target` when a name is shared, and by their project's path when even that
            // is shared, so warnings and evidence name one.
            let nameCounts = Dictionary(projectTargets.map { ($0.name, 1) }, uniquingKeysWith: +)
            let qualifiedCounts = Dictionary(projectTargets.map { ($0.qualifiedName, 1) }, uniquingKeysWith: +)
            func label(_ target: XcodeTarget) -> String {
                if nameCounts[target.name, default: 0] <= 1 { return target.name }

                return qualifiedCounts[target.qualifiedName, default: 0] > 1 ? target.pathQualifiedName : target.qualifiedName
            }
            // A dependency names its target and, through a proxy, the project it is in; without one it is in the
            // dependent's own project. A project that has no such target among those left in the scan, because it was
            // excluded, has none, rather than another project's target of that name.
            func labels(ofDependency dependency: XcodeTarget.Dependency, of target: XcodeTarget) -> [String] {
                let candidates = projectTargets.filter { $0.name == dependency.name }
                let inProject: [XcodeTarget] = if let path = dependency.projectPath {
                    candidates.filter { $0.projectPath == path }
                } else if let name = dependency.projectName {
                    candidates.filter { $0.projectName == name }
                } else {
                    candidates.filter { $0.projectPath == target.projectPath }
                }
                return inProject.map(label)
            }

            let scanned = projectTargets.filter { target in compiled[target, default: []].contains { isIndexed($0, for: target) } }
            let scannedLabels = scanned.mapSet(label)
            let dependencyLabels = Dictionary(projectTargets.map { target in
                (label(target), target.dependencies.flatMapSet { dependency -> Set<String> in
                    let resolved = labels(ofDependency: dependency, of: target)
                    // Not a label of any target, so a dependency that is gone reaches nothing.
                    return resolved.isEmpty ? ["?\(dependency.name)"] : Set(resolved)
                })
            }, uniquingKeysWith: { $0.union($1) })
            let scannedSwiftFiles = scanned.flatMapSet { $0.files(kind: .swiftSource).filter(isCollectable).mapSet { $0.lexicallyNormalized() } }
            var unscanned: [UnscannedTarget] = []
            var dependencies: [String: [String]] = [:]
            for target in projectTargets where !scanned.contains(target) {
                guard compiled[target, default: []].isEmpty == false else { continue }

                let swiftFiles = target.files(kind: .swiftSource).filter(isCollectable).mapSet { $0.lexicallyNormalized() }
                guard !swiftFiles.isEmpty else { continue }

                unscanned.append(UnscannedTarget(name: label(target), swiftSourceFiles: swiftFiles, sharedSourceFiles: swiftFiles.intersection(scannedSwiftFiles)))
                dependencies[label(target)] = Self.scannedDependencies(of: label(target), dependencies: dependencyLabels, scanned: scannedLabels)
            }
            return (unscanned.sorted { $0.name < $1.name }, dependencies)
        }

        /// The configurations whose last completed Lethen build is still valid: nothing it compiled, and nothing that
        /// says what it compiles, changed since it started. Never with a clean build, which exists to discard them, or
        /// without a build, which has its own checks.
        private func reusableConfigurations() -> [String?] {
            guard !configuration.cleanBuild, !configuration.skipBuild, configuration.indexStorePath.isEmpty else { return [] }
            guard !project.hasUnenumerableBuildInputs else {
                logger.debug("Building: a Run Script phase reads or writes a path that cannot be resolved")
                return []
            }
            guard let inputs = XcodeBuildInputs.scanInputs(of: project) else { return [] }

            return buildConfigurations.filter { buildConfiguration in
                guard let dates = try? xcodebuild.completedBuildDates(
                    project: project,
                    schemes: Array(schemes),
                    configuration: buildConfiguration,
                    buildArguments: configuration.buildArguments
                ) else { return false }
                guard let recorded = try? xcodebuild.recordedBuildInputs(
                    project: project,
                    schemes: Array(schemes),
                    configuration: buildConfiguration,
                    buildArguments: configuration.buildArguments
                ) else {
                    logger.debug("Building: the last build recorded no list of its inputs")
                    return false
                }

                if let change = XcodeBuildInputs.firstChange(
                    roots: inputs.roots,
                    files: inputs.files,
                    recorded: recorded,
                    started: dates.started,
                    completed: dates.completed
                ) {
                    logger.debug("Building: \(change) changed after the last build")
                    return false
                }

                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let names = schemes.sorted().map(Self.shellWord).joined(separator: ", ")
                    let described = buildConfiguration.map { " with configuration \($0)" } ?? ""
                    logger.info("Reusing the build of \(names)\(described) from \(dates.completed.formatted(.iso8601)); nothing it compiled has changed.")
                }
                return true
            }
        }

        /// The configurations to build, each into its own DerivedData; `nil` builds the scheme's Test action configuration.
        private var listedConfigurations: [String] {
            configuration.configurations.removingDuplicates()
        }

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
        /// Whether `--exclude-targets` or `--exclude-tests` leaves the target out of the scan. An option names every target
        /// of that name, or one target as `Project/Target`.
        static func isExcluded(_ target: XcodeTarget, excludeTests: Bool, options: [String]) -> Bool {
            (excludeTests && target.isTestTarget) || options.contains(where: target.isNamed(by:))
        }

        /// The files of that kind of the targets that stay in the scan.
        static func files(ofKind kind: ProjectFileKind, in targets: Set<XcodeTarget>, excluding excluded: Set<XcodeTarget>) -> Set<FilePath> {
            targets.subtracting(excluded).flatMapSet { $0.files(kind: kind) }
        }

        /// The names `--exclude-tests` leaves out of the index as modules: those of the excluded test targets, but not one
        /// a target that stays in the scan shares, which `excludedUnits` leaves out by file instead.
        static func excludedTestModules(excluded: Set<XcodeTarget>, among targets: Set<XcodeTarget>) -> Set<String> {
            let retainedModules = targets.subtracting(excluded).flatMapSet(\.moduleNames)
            return excluded.filter { $0.isTestTarget && $0.moduleNames.isDisjoint(with: retainedModules) }.mapSet(\.name)
        }

        /// The units to leave out for the targets named by a qualified `--exclude-targets` option, and for test targets
        /// that `--exclude-tests` leaves out, which cannot be left out by module as a plain name is when a same-named
        /// target shares it. A file only they compile is left out
        /// whole (an empty set); one a retained target compiles too is left out only for the modules of the excluded
        /// target that the retained one does not share, and stays when no module tells them apart.
        static func excludedUnits(excluded: Set<XcodeTarget>, among targets: Set<XcodeTarget>, options: [String], excludeTests: Bool = false) -> [FilePath: Set<String>] {
            let qualified = excluded.filter { target in
                (excludeTests && target.isTestTarget) || options.contains { $0 != target.name && target.isNamedByQualifiedName($0) }
            }
            func files(_ target: XcodeTarget) -> Set<FilePath> {
                target.files(kind: .swiftSource).union(target.files(kind: .clangSource)).mapSet { $0.lexicallyNormalized() }
            }

            let retained = targets.subtracting(excluded)
            var units: [FilePath: Set<String>] = [:]
            for target in qualified {
                for file in files(target) {
                    let others = retained.filter { files($0).contains(file) }
                    if others.isEmpty {
                        units[file] = []
                        continue
                    }

                    let distinct = target.moduleNames.subtracting(others.flatMapSet(\.moduleNames))
                    if !distinct.isEmpty, units[file]?.isEmpty != true {
                        units[file, default: []].formUnion(distinct)
                    }
                }
            }
            return units
        }

        /// The scanned targets the target reaches through its dependencies, directly or through other unscanned
        /// targets, which may re-export what they depend on. Sorted by name.
        static func scannedDependencies(of target: String, dependencies: [String: Set<String>], scanned: Set<String>) -> [String] {
            var seen: Set<String> = [target]
            var pending = Array(dependencies[target] ?? [])
            var reached: Set<String> = []
            while let next = pending.popLast() {
                guard seen.insert(next).inserted else { continue }

                if scanned.contains(next) {
                    reached.insert(next)
                } else {
                    pending.append(contentsOf: dependencies[next] ?? [])
                }
            }
            return reached.sorted()
        }

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
            buildArguments: [String],
            action: BuildAction = .buildForTesting
        ) -> String {
            let builtConfiguration = listedConfiguration
                ?? buildArguments.firstIndex(of: "-configuration").flatMap { buildArguments[safe: $0 + 1] }
                ?? schemeConfigurations?.test
            guard let builtConfiguration else { return "Building \(scheme)" }

            let described = "Building \(scheme) with configuration \(builtConfiguration)"
            return action == .build ? "\(described) (its tests are not built in this configuration)" : described
        }

        /// How each listed configuration builds `scheme`. Exactly one builds for testing, so the test targets are
        /// compiled and indexed once: the scheme's Test action configuration when it is listed, else the first listed.
        /// The others build the scheme's Run action, which needs no test target to compile there.
        static func buildActions(
            listed: [String],
            schemeConfigurations: XcodeSchemeConfigurations?
        ) -> [(configuration: String, action: BuildAction)] {
            let testing = schemeConfigurations?.test.flatMap { listed.contains($0) ? $0 : nil } ?? listed.first
            return listed.map { ($0, $0 == testing ? .buildForTesting : .build) }
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
