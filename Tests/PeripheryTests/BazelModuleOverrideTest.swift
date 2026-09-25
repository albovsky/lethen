@testable import ProjectDrivers
import XCTest

final class BazelModuleOverrideTest: XCTestCase {
    func testRegistryDependencyIsNotOverridden() {
        let moduleFile = """
        bazel_dep(name = "periphery", version = "3.8.0", dev_dependency = True)
        use_repo(use_extension("@periphery//bazel:generated.bzl", "generated"), "periphery_generated")
        """

        XCTAssertFalse(BazelProjectDriver.overridesPeripheryModule(moduleFile))
    }

    func testOverrideOfAnotherModuleDoesNotCount() {
        let moduleFile = """
        bazel_dep(name = "periphery", version = "3.8.0")
        git_override(
            module_name = "rules_swift",
            remote = "https://github.com/bazelbuild/rules_swift.git",
            commit = "abc123",
        )
        """

        XCTAssertFalse(BazelProjectDriver.overridesPeripheryModule(moduleFile))
    }

    func testCommentedOutOverrideDoesNotCount() {
        let moduleFile = """
        bazel_dep(name = "periphery")
        # git_override(module_name = "periphery", remote = "https://github.com/albovsky/lethen.git", tag = "x")
        """

        XCTAssertFalse(BazelProjectDriver.overridesPeripheryModule(moduleFile))
    }

    func testSourceOverridesCount() {
        let overrides = [
            """
            git_override(
                module_name = "periphery",
                remote = "https://github.com/albovsky/lethen.git",
                tag = "3.8.1-dev.1",
            )
            """,
            #"local_path_override(module_name = "periphery", path = "../lethen")"#,
            #"archive_override(module_name="periphery", urls = ["https://example.com/lethen.zip"])"#,
        ]

        for override in overrides {
            let moduleFile = "bazel_dep(name = \"periphery\")\n" + override
            XCTAssertTrue(BazelProjectDriver.overridesPeripheryModule(moduleFile), override)
        }
    }

    func testPeripheryModuleItselfCounts() {
        let moduleFile = """
        module(
            name = "periphery",
            version = "3.8.0",
        )
        """

        XCTAssertTrue(BazelProjectDriver.overridesPeripheryModule(moduleFile))
    }
}
