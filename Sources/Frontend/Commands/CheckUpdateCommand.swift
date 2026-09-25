import ArgumentParser
import Configuration
import Foundation
import Logger
import Shared

struct CheckUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-update",
        abstract: "Check for available update"
    )

    func run() throws {
        let configuration = Configuration()
        let logger = Logger(configuration: configuration)
        let checker = UpdateChecker(logger: logger, configuration: configuration)
        DispatchQueue.global().async { checker.run() }
        let boldLocalVersion = logger.colorize(PeripheryVersion, .bold)

        guard let latestVersion = try checker.wait().get() else {
            let kind = UpdateChecker.isDevelopmentBuild ? "" : "stable "
            logger.info("No \(kind)lethen release is published yet. You are using version \(boldLocalVersion).")
            return
        }

        let boldLatestVersion = logger.colorize(latestVersion.tag, .bold)
        let localVersion = UpdateChecker.localVersion

        if let localVersion, latestVersion > localVersion {
            logger.info(logger.colorize("* Update Available", .boldGreen))
            logger.info("Version \(boldLatestVersion) is now available, you are using version \(boldLocalVersion).")
        } else if let localVersion, localVersion > latestVersion {
            logger.info("You are using version \(boldLocalVersion), which is newer than the latest release, \(boldLatestVersion).")
        } else {
            logger.info("You are using the latest version, \(boldLatestVersion).")
        }
    }
}
