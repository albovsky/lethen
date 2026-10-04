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
        _ = PublicStore(label: "labelled")
        _ = store[0]
        _ = SharedWidget()
        internalNamedFromUnscannedTarget()
        Self.memberNamedWithoutItsType()
        _ = SharedPrivate()
        // Declaring a local of the framework function's name is not a use of it.
        let notCalledFromUnscannedTarget = 1
        if case .matchedOnly = PublicMode.constructed {}
        CallableHandler()()
        _ = AliasSecond.sharedThroughAliasChain
        _ = OverridingBase()
    }

    /// A function of the tool's own that shares its name with an internal one of the framework.
    private static func internalNamedFromUnscannedTarget() {}

    /// Shares its name with a member of the framework's `UnnamedStore`, which the tool never names.
    private static func memberNamedWithoutItsType() {}
}

/// Overrides one member of the framework's open class.
private class OverridingBase: OverridableBase {
    override func overriddenInUnscannedTarget() {}
}

/// The tool's own type of the name a private struct in `SharedBetweenTargets.swift` has.
private struct SharedPrivate {}
