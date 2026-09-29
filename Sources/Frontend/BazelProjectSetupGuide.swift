import Configuration
import Foundation
import Logger
import ProjectDrivers
import Shared
import SystemPackage

final class BazelProjectSetupGuide: SetupGuideHelpers, SetupGuide {
    private let configuration: Configuration

    static func detect(configuration: Configuration, logger: Logger) -> Self? {
        guard BazelProjectDriver.isSupported else { return nil }

        return Self(configuration: configuration, logger: logger)
    }

    required init(configuration: Configuration, logger: Logger) {
        self.configuration = configuration
        super.init(logger: logger)
    }

    var projectKindName: String {
        "Bazel"
    }

    func perform() throws -> ProjectKind {
        // lethen is not published to the Bazel Central Registry, where the 'periphery' module is upstream
        // Periphery. The override makes Bazel build the scanner from lethen's source instead.
        print(logger.colorize("\nAdd the following snippet to your MODULE.bazel file:", .bold))
        print(logger.colorize("""
        bazel_dep(name = "periphery", dev_dependency = True)
        git_override(
            module_name = "periphery",
            remote = "https://github.com/albovsky/lethen.git",
            tag = "\(LethenVersion)",
        )
        use_repo(use_extension("@periphery//bazel:generated.bzl", "generated"), "periphery_generated")
        """, .lightGray))
        print(logger.colorize("\nEnter to continue when ready ", .bold), terminator: "")
        _ = readInput()

        // A saved configuration must select Bazel too, or the bare 'lethen scan' printed after saving would
        // look for another project kind.
        configuration.bazel = true
        return .bazel
    }

    var commandLineOptions: [String] {
        ["--bazel"]
    }

    var suggestedCommandLineOptions: [String] {
        ["--bazel"]
    }
}
