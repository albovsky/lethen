import Foundation

protocol SyntaxFixture28Protocol {}

class SyntaxFixture28 {
    func concrete(_ type: Int.Type = Int.self) {}
    func unrelated<T>(_ type: String.Type, value: T) -> T { value }
    func protocolMetatype(_ type: SyntaxFixture28Protocol.Protocol) {}
    func genericArgument<T>(_ type: [T].Type, value: T) -> T { value }
}
