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
