import Foundation
import Logger
import ProjectDrivers
import Shared
import SystemPackage

final class BazelProjectSetupGuide: SetupGuideHelpers, SetupGuide {
    static func detect(logger: Logger) -> Self? {
        guard BazelProjectDriver.isSupported else { return nil }

        return Self(logger: logger)
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

        return .bazel
    }

    var commandLineOptions: [String] {
        ["--bazel"]
    }
}
