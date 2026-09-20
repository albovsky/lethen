public struct SynthesizedEqualityValue: Equatable {
    let number: Int
    let label: String
}

public struct ManualEqualityValue: Equatable {
    let compared: Int
    let ignored: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.compared == rhs.compared
    }
}

public func compareEqualityFixtures() -> Bool {
    let synthesized = SynthesizedEqualityValue(number: 1, label: "one")
    let manual = ManualEqualityValue(compared: 1, ignored: 2)
    return synthesized == SynthesizedEqualityValue(number: 2, label: "two")
        && manual == ManualEqualityValue(compared: 2, ignored: 3)
}

public struct ExtensionEqualityValue: Equatable {
    let compared: Int
    let ignored: Int
}

extension ExtensionEqualityValue {
    public static func ==(lhs: Self, rhs: Self) -> Bool { lhs.compared == rhs.compared }
}

public func compareExtensionEqualityFixtures() -> Bool {
    ExtensionEqualityValue(compared: 1, ignored: 2) == ExtensionEqualityValue(compared: 1, ignored: 3)
}

private struct UnreachableEqualityValue: Equatable {
    let number: Int
}

private func unreachableEqualityCaller() -> Bool {
    UnreachableEqualityValue(number: 1) == UnreachableEqualityValue(number: 2)
}

public protocol DefaultEquality: Equatable {}

extension DefaultEquality {
    public static func ==(lhs: Self, rhs: Self) -> Bool { true }
}

public struct DefaultEqualityValue: DefaultEquality {
    let ignored: Int
}

public func compareDefaultEqualityFixtures() -> Bool {
    DefaultEqualityValue(ignored: 1) == DefaultEqualityValue(ignored: 2)
}

public struct GlobalEqualityValue: Equatable {
    let compared: Int
    let ignored: Int
}

public func ==(lhs: GlobalEqualityValue, rhs: GlobalEqualityValue) -> Bool {
    lhs.compared == rhs.compared
}

public func compareGlobalEqualityFixtures() -> Bool {
    GlobalEqualityValue(compared: 1, ignored: 2) == GlobalEqualityValue(compared: 1, ignored: 3)
}

public protocol ExternalDefaultEquality: Equatable {}

extension Equatable where Self: ExternalDefaultEquality {
    public static func ==(lhs: Self, rhs: Self) -> Bool { true }
}

public struct ExternalDefaultEqualityValue: ExternalDefaultEquality {
    let ignored: Int
}

public struct ExtendedDefaultEqualityValue {
    let ignored: Int
}

extension ExtendedDefaultEqualityValue: ExternalDefaultEquality {}

public func compareExternalDefaultEqualityFixtures() -> Bool {
    ExternalDefaultEqualityValue(ignored: 1) == ExternalDefaultEqualityValue(ignored: 2)
        && ExtendedDefaultEqualityValue(ignored: 1) == ExtendedDefaultEqualityValue(ignored: 2)
}

public struct ConstructedOnlyEqualityValue: Equatable {
    let used: Int
    let ignored: Int
}

public struct GenericEqualityValue: Equatable { let value: Int }
public struct LibraryEqualityValue: Equatable { let value: Int }
public struct NestedEqualityLeaf: Equatable { let value: Int }
public struct NestedEqualityContainer: Equatable { let leaf: NestedEqualityLeaf }

private func identityEquality<T: Equatable>(_ value: T) -> T {
    let other = GenericEqualityValue(value: 1)
    print(other == GenericEqualityValue(value: 2))
    return value
}

private func genericEquality<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool { lhs == rhs }

public func equalityUsageControls() -> Bool {
    let constructed = ConstructedOnlyEqualityValue(used: 1, ignored: 2)
    print(constructed.used)
    print(identityEquality(constructed).used)
    let first = GenericEqualityValue(value: 1)
    let second = GenericEqualityValue(value: 2)
    let values = [LibraryEqualityValue(value: 1)]
    let needle = LibraryEqualityValue(value: 2)
    let nested = NestedEqualityContainer(leaf: NestedEqualityLeaf(value: 1))
    let other = NestedEqualityContainer(leaf: NestedEqualityLeaf(value: 2))
    return genericEquality(first, second) && values.contains(needle) && nested == other
}

public struct ClosureEqualityValue: Equatable { let value: Int }

public func closureEqualityControl() -> Bool {
    let compare = { (lhs: ClosureEqualityValue, rhs: ClosureEqualityValue) in lhs == rhs }
    return compare(ClosureEqualityValue(value: 1), ClosureEqualityValue(value: 2))
}

public struct DictionaryEqualityKey: Hashable { let value: Int }

public func dictionaryEqualityControl() -> Int? {
    let key = DictionaryEqualityKey(value: 1)
    var values: [DictionaryEqualityKey: Int] = [:]
    values[key] = 1
    return values[key]
}
