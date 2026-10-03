import Foundation

@objc public class FrameworkSwiftClass: NSObject {
    @objc public func ping() {}

    /// Called only from `UnscannedTool`, which no scheme builds.
    public func onlyCalledFromUnscannedTarget() {}
}

/// A case of an `@objc` enum nested in a class is recorded by the Swift index under its Swift USR only,
/// so no Swift declaration resolves to the clang USR an Objective-C use names.
@objc public class FrameworkSizes: NSObject {
    @objc public enum FrameworkWidth: Int {
        case w100 = 100
    }
}

public class PublicStore {
    public init() {}

    /// Read from `UnscannedTool` only.
    public var memberReadFromUnscannedTarget = 0

    /// The control: called from the scanned tool, and also named in `UnscannedTool`.
    public func usedFromScannedTarget() {}
}

/// `UnscannedTool` spells this member's name on another type and never names `UnnamedStore`.
public class UnnamedStore {
    public init() {}

    public func memberNamedWithoutItsType() {}
}

public enum PublicMode {
    case constructed
    /// Matched in a pattern by `UnscannedTool`, never constructed.
    case matchedOnly
}

/// `UnscannedTool` spells this name only as a local variable, which is not a use.
public func notCalledFromUnscannedTarget() {}

/// Internal and not compiled into `UnscannedTool`, which declares a function of the same name.
func internalNamedFromUnscannedTarget() {}
