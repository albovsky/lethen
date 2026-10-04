import Foundation

class FixtureStoreA5 {
    static let shared = FixtureStoreA5()
    static func make5() {}
}

class FixtureStoreB5 {
    static let shared = FixtureStoreB5()
    static func make5() {}
}

class FixtureStoreC5 {
    static let shared = FixtureStoreC5()
}

typealias FixtureAliasC5 = FixtureStoreC5

class FixtureBase5 {
    class func baseMake5() {}
}

class FixtureSub5: FixtureBase5 {}

class FixtureOverride5: FixtureBase5 {
    override class func baseMake5() {}
}

protocol FixtureProtocol5 {}

extension FixtureProtocol5 {
    static func protocolMake5() {}
}

struct FixtureConforming5: FixtureProtocol5 {}

class FixtureUnqualifiedA5 {
    var tick5 = 0
}

class FixtureUnqualifiedB5 {
    var tick5 = 0
}

class FixtureGenericA5 {
    static let generic5 = 0
}

class FixtureGenericB5 {
    static let generic5 = 0
}

class FixtureNeverNamed5 {
    static let shared = FixtureNeverNamed5()
}

public func fixtureReceivers5(object: AnyObject) {
    #if os(Windows)
        _ = FixtureStoreA5.shared
        FixtureStoreA5.make5()
        _ = FixtureAliasC5.shared
        FixtureSub5.baseMake5()
        FixtureOverride5.baseMake5()
        FixtureConforming5.protocolMake5()
        _ = object.tick5
        func generic<T: FixtureGenericA5>(_: T.Type) { _ = T.generic5 }
    #endif
}

// Referencing the types keeps them from being reported, which leaves their members to be.
public func fixtureTypes5() {
    _ = FixtureStoreA5.self
    _ = FixtureStoreB5.self
    _ = FixtureStoreC5.self
    _ = FixtureSub5.self
    _ = FixtureOverride5.self
    _ = FixtureConforming5.self
    _ = FixtureUnqualifiedA5.self
    _ = FixtureUnqualifiedB5.self
    _ = FixtureGenericA5.self
    _ = FixtureGenericB5.self
    _ = FixtureNeverNamed5.self
}
