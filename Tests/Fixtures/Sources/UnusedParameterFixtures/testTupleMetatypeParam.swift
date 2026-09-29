import Foundation

class SyntaxFixture26 {
    func read<T1, T2>(as type: (T1, T2).Type = (T1, T2).self) -> Int { 0 }
    func readOptional<T>(as type: T?.Type = T?.self) -> Int { 0 }
}
