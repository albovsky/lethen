public class FixtureClass233 {
    subscript(row: Int, column: Int) -> Int { row }
    let transform: (Int, Int) -> Int = { used, unused in used }

    public func use() -> Int {
        self[0, 1] + transform(1, 2)
    }
}

// Control: a subscript that satisfies an external protocol's requirement keeps its signature.
public struct FixtureStruct233Collection: Collection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }

    public func index(after index: Int) -> Int {
        index + 1
    }

    public subscript(position: Int) -> Int {
        0
    }
}
