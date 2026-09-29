import Foundation

struct SyntaxFixture27<Value> {
    init(_ type: Value.Type) {}

    func outer<Element>(_ element: Element) -> Element {
        func inner(_ type: Element.Type = Element.self) {}
        inner()
        return element
    }
}

extension SyntaxFixture27 {
    func make(_ type: Value.Type = Value.self) {}
}
