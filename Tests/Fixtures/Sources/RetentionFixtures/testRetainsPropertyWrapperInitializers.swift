import Foundation

@propertyWrapper
struct Fixture225Wrapper {
    var wrappedValue: Int
    var projectedValue: Fixture225Wrapper { self }

    init(wrappedValue: Int) {
        self.wrappedValue = wrappedValue
    }

    init(wrappedValue: Int, clampedTo limit: Int) {
        self.wrappedValue = min(wrappedValue, limit)
    }

    init(projectedValue: Fixture225Wrapper) {
        self = projectedValue
    }

    // Control: not part of the property wrapper contract, must be reported.
    init(other: Int) {
        wrappedValue = other
    }
}

public class Fixture225 {
    @Fixture225Wrapper var value = 1

    public func use() {
        print(value)
    }
}
