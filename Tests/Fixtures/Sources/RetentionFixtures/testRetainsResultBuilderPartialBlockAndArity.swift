import Foundation

@resultBuilder
struct FixtureStruct225 {
    static func buildPartialBlock(first: Int) -> Int { first }
    static func buildPartialBlock(accumulated: Int, next: Int) -> Int { accumulated + next }
    static func buildBlock(_ first: Int, _ second: Int, _ third: Int) -> Int { first + second + third }
    static func buildExpression(_ expression: Int, scale: Int = 1) -> Int { expression * scale }
    // Control: not part of the result builder protocol, must be reported.
    static func buildSomethingElse() -> Int { 0 }
}

// Control: the names alone must not retain anything on a type that is not a result builder.
struct FixtureStruct225NotABuilder {
    static func buildBlock(_ component: Int) -> Int { component }
}

public class FixtureClass224Retainer {
    public func build() -> Int {
        _ = FixtureStruct225NotABuilder()
        return make { 1 }
    }

    func make(@FixtureStruct225 _ content: () -> Int) -> Int {
        content()
    }
}
