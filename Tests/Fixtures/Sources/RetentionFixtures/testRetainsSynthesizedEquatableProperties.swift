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
