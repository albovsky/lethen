import Configuration
@testable import TestShared

/// `Extra.storyboard`, which references `ExtraController`, sits in a synchronized folder that only the `Target With
/// Spaces` target owns, so it reaches the index through that target alone.
final class SynchronizedResourcesTest: XcodeSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        let configuration = Configuration()
        configuration.schemes = ["UIKitProject"]

        setupState.capture {
            try build(projectPath: UIKitProjectPath, configuration: configuration)
            try index(configuration: configuration)
        }
    }

    /// The control: nothing is excluded, so the storyboard's owner is scanned and the class it names is retained.
    func testRetainsClassReferencedByAStoryboardOfAnOwnedSynchronizedFolder() {
        assertReferenced(.class("ExtraController")) {
            self.assertReferenced(.functionMethodInstance("extraAction(_:)"))
            // Not connected in the storyboard.
            self.assertNotReferenced(.functionMethodInstance("unusedExtraAction(_:)"))
        }
    }
}

/// With `--exclude-targets "Target With Spaces"` the storyboard belongs to a target that is not scanned. The app, which
/// compiles `ExtraController`, does not own its folder, so the class is no longer referenced from it.
final class SynchronizedResourcesExcludedOwnerTest: XcodeSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        let configuration = Configuration()
        configuration.schemes = ["UIKitProject"]
        configuration.excludeTargets = ["Target With Spaces"]

        setupState.capture {
            try build(projectPath: UIKitProjectPath, configuration: configuration)
            try index(configuration: configuration)
        }
    }

    func testReportsClassOnlyAnExcludedTargetsStoryboardReferences() {
        assertNotReferenced(.class("ExtraController"))
    }
}

/// `Inclusion.storyboard` sits in the folder `Target With Spaces` owns, and the app's exception set for that folder
/// includes it, so excluding the owner leaves the app compiling it: the class it names is still referenced.
final class SynchronizedInclusionExcludedOwnerTest: XcodeSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        let configuration = Configuration()
        configuration.schemes = ["UIKitProject"]
        configuration.excludeTargets = ["Target With Spaces"]

        setupState.capture {
            try build(projectPath: UIKitProjectPath, configuration: configuration)
            try index(configuration: configuration)
        }
    }

    func testRetainsClassReferencedByAStoryboardTheAppIncludesFromAnotherTargetsFolder() {
        assertReferenced(.class("InclusionController")) {
            self.assertReferenced(.functionMethodInstance("inclusionAction(_:)"))
        }
    }
}
