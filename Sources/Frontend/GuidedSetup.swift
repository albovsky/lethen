import Configuration
import Foundation
import Logger
import Shared

#if canImport(XcodeSupport)
    import XcodeSupport
#endif

final class GuidedSetup: SetupGuideHelpers {
    private let configuration: Configuration
    private let shell: Shell

    required init(configuration: Configuration, shell: Shell, logger: Logger, readInput: @escaping () -> String?) {
        self.configuration = configuration
        self.shell = shell
        super.init(logger: logger)
        self.readInput = readInput
    }

    func perform() throws -> Project {
        print(logger.colorize("Welcome to lethen!", .boldGreen))
        print("This guided setup will help you select the appropriate configuration for your project.\n")

        var projectGuides: [SetupGuide] = []

        // Every guide reads from the same input as this one.
        if let guide = SPMProjectSetupGuide.detect(logger: logger) {
            guide.readInput = readInput
            projectGuides.append(guide)
        }

        #if canImport(XcodeSupport)
            if let guide = XcodeProjectSetupGuide(configuration: configuration, shell: shell, logger: logger) {
                guide.readInput = readInput
                projectGuides.append(guide)
            }
        #endif

        if let guide = BazelProjectSetupGuide.detect(logger: logger) {
            guide.readInput = readInput
            projectGuides.append(guide)
        }

        var projectGuide_: SetupGuide?

        if projectGuides.count > 1 {
            print(logger.colorize("Select which project to use:", .bold))
            let kindName = try select(single: projectGuides.map(\.projectKindName))
            projectGuide_ = projectGuides.first { $0.projectKindName == kindName }
            print("")
        } else if let singleGuide = projectGuides.first {
            print(logger.colorize("*", .boldGreen) + " Detected \(singleGuide.projectKindName) project")
            projectGuide_ = singleGuide
        }

        guard let projectGuide = projectGuide_ else {
            throw LethenError.guidedSetupError(message: "Failed to identify a project in the current directory: no Package.swift, Xcode project or workspace, or Bazel module was found")
        }

        print(logger.colorize("*", .boldGreen) + " Inspecting project...")

        let kind = try projectGuide.perform()
        let project = Project(kind: kind, configuration: configuration, shell: shell, logger: logger)

        let commonGuide = CommonSetupGuide(configuration: configuration, logger: logger)
        commonGuide.readInput = readInput
        try commonGuide.perform()

        let options = projectGuide.commandLineOptions + commonGuide.commandLineOptions
        var shouldSave = false

        if configuration.hasNonDefaultValues {
            print(logger.colorize("\nSave configuration to \(Configuration.defaultConfigurationFile)?", .bold))
            shouldSave = try selectBoolean()

            if shouldSave {
                try configuration.save()
            }
        }

        print(logger.colorize("\n*", .boldGreen) + " Executing command:")
        print(logger.colorize(formatScanCommand(options: options, didSave: shouldSave) + "\n", .bold))

        return project
    }

    // MARK: - Private

    private func formatScanCommand(options: [String], didSave: Bool) -> String {
        let bareCommand = "lethen scan"

        if didSave {
            return bareCommand
        }

        let parts = [bareCommand] + options

        if options.count > 1 {
            return parts.joined(separator: " \\\n  ")
        }

        return parts.joined(separator: " ")
    }
}
