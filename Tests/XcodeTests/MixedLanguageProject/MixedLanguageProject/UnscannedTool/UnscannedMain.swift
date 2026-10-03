import MixedFramework

/// A command-line tool that no scheme builds. It uses the framework's public API, and names a type
/// from `SharedBetweenTargets.swift`, which the scanned tool compiles too.
@main
enum UnscannedMain {
    static func main() {
        FrameworkSwiftClass().onlyCalledFromUnscannedTarget()
        let store = PublicStore()
        store.usedFromScannedTarget()
        _ = store.memberReadFromUnscannedTarget
        _ = SharedWidget()
        internalNamedFromUnscannedTarget()
        Self.memberNamedWithoutItsType()
        // Declaring a local of the framework function's name is not a use of it.
        let notCalledFromUnscannedTarget = 1
        if case .matchedOnly = PublicMode.constructed {}
    }

    /// A function of the tool's own that shares its name with an internal one of the framework.
    private static func internalNamedFromUnscannedTarget() {}

    /// Shares its name with a member of the framework's `UnnamedStore`, which the tool never names.
    private static func memberNamedWithoutItsType() {}
}
