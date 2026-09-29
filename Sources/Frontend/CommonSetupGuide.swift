import Configuration
import Foundation
import Logger
import Shared

final class CommonSetupGuide: SetupGuideHelpers {
    private let configuration: Configuration

    required init(configuration: Configuration, logger: Logger) {
        self.configuration = configuration
        super.init(logger: logger)
    }

    func perform(detectedRetainPublic: DetectedAnswer<Bool>?) throws {
        if let known = knownRetainPublic(detected: detectedRetainPublic) {
            configuration.retainPublic = known.value
            print(logger.colorize("*", .boldGreen) + " " + known.description)
            return
        }

        print(logger.colorize("\nAssume all 'public' declarations are in use?", .bold))
        print("Choose 'Yes' if your project is a framework/library without a main application target.")
        configuration.retainPublic = try selectBoolean()
    }

    /// Whether public declarations count as used, with a line saying why, when `--retain-public` was passed or
    /// the project answers it; nil when only the user can answer.
    func knownRetainPublic(detected: DetectedAnswer<Bool>?) -> (value: Bool, description: String)? {
        if configuration.retainPublic {
            return (true, "Assuming all 'public' declarations are in use, as --retain-public was passed")
        }

        guard let detected else { return nil }

        let description = detected.value
            ? "Assuming all 'public' declarations are in use (--retain-public): \(detected.reason)"
            : "Reporting unused 'public' declarations: \(detected.reason)"
        return (detected.value, description)
    }

    var commandLineOptions: [String] {
        var options: [String] = []

        if configuration.retainPublic {
            options.append("--retain-public")
        }

        return options
    }
}
