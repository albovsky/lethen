import Foundation

@objc public class FrameworkSwiftClass: NSObject {
    @objc public func ping() {}
}

/// A case of an `@objc` enum nested in a class is recorded by the Swift index under its Swift USR only,
/// so no Swift declaration resolves to the clang USR an Objective-C use names.
@objc public class FrameworkSizes: NSObject {
    @objc public enum FrameworkWidth: Int {
        case w100 = 100
    }
}
