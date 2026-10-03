import Configuration
import Foundation
import Logger
import Shared
import SourceGraph
import SyntaxAnalysis
import SystemPackage

/// Reads the names that the Swift files of targets the scanned schemes do not build use.
///
/// Those files have no index unit, so a use they make of scanned code is not a reference in the graph and
/// the declaration is reported as certainly unused. A declaration's name in such a file is evidence that it
/// may be used, so the names go into the graph for `SourceGraph.assessConfidence` to downgrade the
/// declarations they match. They are read from syntax alone, so a use from an Objective-C file of the target
/// is not seen.
final class UnscannedTargetIndexer: Indexer {
    private let targets: [UnscannedTarget]
    private let graph: SourceGraphMutex
    private let logger: ContextualLogger
    private let projectRoot: FilePath

    required init(targets: [UnscannedTarget], graph: SourceGraphMutex, logger: ContextualLogger, configuration: Configuration) {
        self.targets = targets
        self.graph = graph
        self.logger = logger.contextualized(with: "unscanned-target")
        projectRoot = configuration.projectRoot
        super.init(configuration: configuration)
    }

    func perform() throws {
        for target in targets {
            graph.withLock {
                $0.addUnscannedTargetNames(names: [:], members: [:], construction: [:], target: target.name, sharedSourceFiles: target.sharedSourceFiles)
            }
        }

        // A file a scanned target compiles too is indexed there, with the uses it makes of its own declarations.
        let jobs = targets.flatMap { target in target.swiftSourceFiles.subtracting(target.sharedSourceFiles).sorted { $0.string < $1.string }.map { (target.name, $0) } }
        try JobPool(jobs: jobs).forEach { [weak self] targetName, file in
            guard let self else { return }

            let uses: [NameUseCollector.FileUse]
            do {
                uses = try NameUseCollector.uses(inFileAt: file)
            } catch {
                logger.debug("Skipping \(file.string) of target \(targetName): \(error)")
                return
            }

            let path = projectRoot.isEmpty ? file : file.relativeTo(FilePath.makeAbsolute(projectRoot))
            var names: [String: String] = [:]
            var members: [String: String] = [:]
            var construction: [String: String] = [:]
            for use in uses {
                let site = "\(path.string):\(use.line)"
                Self.keepSmallest(site, for: use.name, in: &names)
                if use.isMember { Self.keepSmallest(site, for: use.name, in: &members) }
                if use.isConstruction { Self.keepSmallest(site, for: use.name, in: &construction) }
            }
            graph.withLock {
                $0.addUnscannedTargetNames(names: names, members: members, construction: construction, target: targetName)
            }
            logger.debug("\(file.string): \(names.count) names")
        }
    }

    private static func keepSmallest(_ site: String, for name: String, in sites: inout [String: String]) {
        if sites[name].map({ $0 > site }) ?? true { sites[name] = site }
    }
}
