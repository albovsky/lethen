// A witness of a requirement declared outside the scanned modules has its signature fixed by that requirement, so its
// unused parameters cannot be removed, even when the conforming type is internal. The index records no relation to
// underscored standard library requirements, so those witnesses are recognised by name and conformance.
struct FixtureStruct238: Collection {
    var startIndex: Int { 0 }
    var endIndex: Int { 0 }

    subscript(position: Int) -> Int { position }

    func index(after i: Int) -> Int { i + 1 }

    // Retained: witnesses the underscored stdlib requirement Collection._failEarlyRangeCheck(_:bounds:).
    func _failEarlyRangeCheck(_ index: Int, bounds: Range<Int>) {}

    // Retained: witnesses the stdlib requirement Collection.distance(from:to:), which the index relates.
    func distance(from start: Int, to end: Int) -> Int { 0 }

    // Reported: a helper that witnesses nothing, on a type that conforms to an external protocol.
    func helper(unused: Int) {}

    // Reported: an underscored helper that witnesses nothing, on a type that conforms to an external protocol.
    func _helper(unused: Int) {}
}

struct FixtureStruct238Extension {}

extension FixtureStruct238Extension: Collection {
    var startIndex: Int { 0 }
    var endIndex: Int { 0 }

    subscript(position: Int) -> Int { position }

    func index(after i: Int) -> Int { i + 1 }

    // Retained: the conformance is declared in an extension.
    func _failEarlyRangeCheck(_ index: Int, bounds: ClosedRange<Int>) {}
}

protocol FixtureProtocol238Refined: Collection where Index == Int {}

struct FixtureStruct238Refined: FixtureProtocol238Refined {
    var startIndex: Int { 0 }
    var endIndex: Int { 0 }

    subscript(position: Int) -> Int { position }

    func index(after i: Int) -> Int { i + 1 }

    // Retained: the type conforms to Collection through an internal refined protocol.
    func _failEarlyRangeCheck(_ range: Range<Int>, bounds: Range<Int>) {}

    // Used-but-not-compared control: the witness reads its parameter, so it is used rather than retained.
    func _failEarlyRangeCheck(_ index: Int, bounds: Range<Int>) {
        precondition(bounds.contains(index))
    }
}

struct FixtureStruct238Hashable: Hashable {
    // Retained: witnesses the stdlib requirement Hashable.hash(into:), which the index relates.
    func hash(into hasher: inout Hasher) {}

    // Retained: witnesses the underscored stdlib requirement Hashable._rawHashValue(seed:).
    func _rawHashValue(seed: Int) -> Int { 0 }
}

protocol FixtureProtocol238 {
    func internalRequirement(unused: Int)
}

struct FixtureStruct238Internal: FixtureProtocol238 {
    // Reported: witnesses an internal requirement and no witness reads the parameter.
    func internalRequirement(unused: Int) {}

    // Reported: a near-miss of Collection._failEarlyRangeCheck(_:bounds:) on a type that conforms to no external
    // protocol.
    func _failEarlyRangeCheck(_ index: Int, bounds: Range<Int>) {}
}

public func fixtureStruct238Entry() {
    let collection = FixtureStruct238()
    _ = collection.distance(from: 0, to: 0)
    collection._failEarlyRangeCheck(0, bounds: 0 ..< 0)
    collection.helper(unused: 0)
    collection._helper(unused: 0)
    FixtureStruct238Extension()._failEarlyRangeCheck(0, bounds: 0 ... 0)
    let refined = FixtureStruct238Refined()
    refined._failEarlyRangeCheck(0 ..< 0, bounds: 0 ..< 0)
    refined._failEarlyRangeCheck(0, bounds: 0 ..< 1)
    _ = Set([FixtureStruct238Hashable()])
    _ = FixtureStruct238Hashable()._rawHashValue(seed: 0)
    let witness: FixtureProtocol238 = FixtureStruct238Internal()
    witness.internalRequirement(unused: 0)
    FixtureStruct238Internal()._failEarlyRangeCheck(0, bounds: 0 ..< 0)
}
