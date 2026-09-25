import Configuration
import Foundation
import Indexer
import ProjectDrivers
import SystemPackage

class SPMSourceGraphTestCase: SourceGraphTestCase {
    /// Index plans of the packages this process has already built, keyed by project path.
    ///
    /// A managed build cleans and rebuilds a package whenever its products already exist, so
    /// every test class that shares a fixture package would otherwise rebuild it from scratch
    /// in its own class setup. The first class builds; later classes reuse its products and
    /// plan. Only builds with default build settings are shared, since those are the only
    /// ones whose products are interchangeable.
    private static var builtPlans: [FilePath: IndexPlan] = [:]

    static func build(projectPath: FilePath = ProjectRootPath, configuration: Configuration = .init()) throws {
        let isShareable = configuration.buildArguments.isEmpty
            && !configuration.cleanBuild
            && !configuration.skipBuild
            && configuration.indexStorePath.isEmpty

        if isShareable, let builtPlan = builtPlans[projectPath] {
            plan = builtPlan
            return
        }

        try projectPath.chdir {
            let driver = try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
            try driver.build()
            plan = try driver.plan(logger: logger.contextualized(with: "index"))
        }

        if isShareable, let plan {
            builtPlans[projectPath] = plan
        }
    }
}
