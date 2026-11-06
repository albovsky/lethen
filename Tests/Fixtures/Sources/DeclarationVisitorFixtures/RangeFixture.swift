/// Documentation comment.
@available(*, deprecated)
public struct RangeVisitorTestFixture<T>: Hashable {
    @discardableResult
    func method(a: Int) -> Int {
        a
    }

    var stored: Int = 1
    var computed: Int {
        get { 1 }
    }
    struct Nested {
        let inner = 2
    }
}

func freeFunction() {}
let first = 1, second = 2
