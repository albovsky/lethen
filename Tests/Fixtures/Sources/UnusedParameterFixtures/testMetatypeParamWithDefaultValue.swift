import Foundation

class SyntaxFixture25 {
    func decode<Value>(_ type: Value.Type = Value.self, from data: Int) -> Int { data }
    func decodeOptional<Value>(_ type: Value.Type? = nil, from data: Int) -> Int { data }
    func decodeIgnoringInput<Value>(_ type: Value.Type = Value.self, input: Int) {}
}
