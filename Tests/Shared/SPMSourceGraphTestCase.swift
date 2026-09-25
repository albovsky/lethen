import Configuration
import Foundation
import Indexer
import ProjectDrivers
import SystemPackage

class SPMSourceGraphTestCase: SourceGraphTestCase {
    /// Index plans of the packages this process has already built with an entirely default
    /// configuration, keyed by project path.
    ///
    /// A managed build cleans and rebuilds a package whenever its products already exist, so
    /// every test class that shares a fixture package would otherwise rebuild it from scratch
    /// in its own class setup. The first class builds; later classes reuse its products and
    /// plan. Only a configuration with every setting at its default is shared, so a build
    /// with any custom setting that shapes the products or the plan (build arguments,
    /// clean or skipped build, index store path, excluded tests or targets, index excludes,
    /// manifest path) always gets its own build.
    private static var builtPlans: [FilePath: IndexPlan] = [:]

    static func build(projectPath: FilePath = ProjectRootPath, configuration: Configuration = .init()) throws {
        let isShareable = !configuration.hasNonDefaultValues

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
