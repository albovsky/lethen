import Foundation

extension NSObject {
    // A skipped `NSString(fixtureSubclass12:)` inherits this: the build references `NSString` as a class.
    convenience init(fixtureSubclass12 _: Int) { self.init() }
    // A skipped `Foundation.NSString(fixtureQualifiedSubclass12:)` inherits this too.
    convenience init(fixtureQualifiedSubclass12 _: Int) { self.init() }
    // Control: a skipped `NSLog(fixtureFunction12:)` names a function the build references, not a type.
    convenience init(fixtureFunction12 _: Int) { self.init() }
    // Control: a skipped `FixtureNeverReferenced12(fixtureUnknown12:)` names nothing the build references.
    convenience init(fixtureUnknown12 _: Int) { self.init() }
}

extension String {
    // A skipped `StringLiteralType(fixtureAlias12:)` may reach this: the build references it as a type alias.
    init(fixtureAlias12 _: Int) { self = "" }
    // Control: a skipped `NSString(fixtureClassForStruct12:)` names a class, which no struct has as a subclass.
    init(fixtureClassForStruct12 _: Int) { self = "" }
}

public func fixtureUnscannedRelatives12() {
    #if os(Windows)
        _ = NSString(fixtureSubclass12: 1)
        _ = Foundation.NSString(fixtureQualifiedSubclass12: 1)
        _ = NSLog(fixtureFunction12: 1)
        _ = FixtureNeverReferenced12(fixtureUnknown12: 1)
        _ = StringLiteralType(fixtureAlias12: 1)
        _ = NSString(fixtureClassForStruct12: 1)
    #else
        let alias: StringLiteralType = "compiled"
        NSLog("%@", NSString(string: alias))
    #endif
}
