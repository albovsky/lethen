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
    private let isInteractive: Bool

    /// `isInteractive` is false when standard input is not a terminal: the setup then prints what it detected
    /// and the command to run, and asks nothing.
    required init(
        configuration: Configuration,
        shell: Shell,
        logger: Logger,
        isInteractive: Bool,
        readInput: @escaping () -> String?
    ) {
        self.configuration = configuration
        self.shell = shell
        self.isInteractive = isInteractive
        super.init(logger: logger)
        self.readInput = readInput
    }

    func perform() throws -> Project {
        print(logger.colorize("Welcome to lethen!", .boldGreen))
        print("This guided setup will help you select the appropriate configuration for your project.\n")

        var projectGuides: [SetupGuide] = []

        // Every guide reads from the same input as this one.
        if let guide = SPMProjectSetupGuide.detect(configuration: configuration, shell: shell, logger: logger) {
            guide.readInput = readInput
            projectGuides.append(guide)
        }

        #if canImport(XcodeSupport)
            if let guide = XcodeProjectSetupGuide(configuration: configuration, shell: shell, logger: logger) {
                guide.readInput = readInput
                projectGuides.append(guide)
            }
        #endif

        if let guide = BazelProjectSetupGuide.detect(configuration: configuration, logger: logger) {
            guide.readInput = readInput
            projectGuides.append(guide)
        }

        guard !projectGuides.isEmpty else {
            throw LethenError.guidedSetupError(message: "Failed to identify a project in the current directory: no Package.swift, Xcode project or workspace, or Bazel module was found")
        }
        guard isInteractive else {
            try suggestCommands(for: projectGuides)
        }

        let projectGuide: SetupGuide

        if projectGuides.count > 1 {
            print(logger.colorize("Select which project to use:", .bold))
            let kindName = try select(single: projectGuides.map(\.projectKindName))
            projectGuide = projectGuides.first { $0.projectKindName == kindName } ?? projectGuides[0]
            print("")
        } else {
            projectGuide = projectGuides[0]
            print(logger.colorize("*", .boldGreen) + " Detected \(projectGuide.projectKindName) project")
        }

        print(logger.colorize("*", .boldGreen) + " Inspecting project...")

        let kind = try projectGuide.perform()
        let project = Project(kind: kind, configuration: configuration, shell: shell, logger: logger)

        let commonGuide = CommonSetupGuide(configuration: configuration, logger: logger)
        commonGuide.readInput = readInput
        try commonGuide.perform(detectedRetainPublic: projectGuide.detectedRetainPublic)

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

    /// Prints each detected project with the command that scans it, then fails: nothing can answer the
    /// questions, and scanning with guessed answers would hide that from a script or CI job.
    private func suggestCommands(for projectGuides: [SetupGuide]) throws -> Never {
        let commonGuide = CommonSetupGuide(configuration: configuration, logger: logger)
        print(logger.colorize("*", .boldYellow) + " Standard input is not a terminal, so the guided setup cannot ask its questions.")

        for guide in projectGuides {
            print(logger.colorize("\n*", .boldGreen) + " Detected \(guide.projectKindName) project")
            var options = guide.suggestedCommandLineOptions

            if let known = commonGuide.knownRetainPublic(detected: guide.detectedRetainPublic) {
                print(logger.colorize("*", .boldGreen) + " " + known.description)
                if known.value {
                    options.append("--retain-public")
                }
            } else {
                print("  Add --retain-public if the project is a framework or library without a main application target.")
            }

            print(logger.colorize("*", .boldGreen) + " Command to run:")
            print(logger.colorize(formatScanCommand(options: options, didSave: false), .bold))
        }

        print("")
        // Standard output is buffered when it is not a terminal; keep the command above the error in logs.
        fflush(stdout)
        throw LethenError.guidedSetupError(message: "The guided setup needs an interactive terminal; run the command above instead, or run 'lethen scan --setup' in a terminal")
    }

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
