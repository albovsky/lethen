infix operator <~~>: AdditionPrecedence
infix operator <!!>: AdditionPrecedence
infix operator <??>: AdditionPrecedence
prefix operator ^^^

func <~~> (lhs: Int, rhs: Int) -> Int { lhs + rhs }
func <!!> (lhs: Int, rhs: Int) -> Int { lhs - rhs }
func <??> (lhs: Int, rhs: Int) -> Int { lhs * rhs }
prefix func ^^^ (value: Int) -> Int { -value }

public func fixtureOperators312(_ value: Int) -> Int {
    var result = value
    #if !os(Windows)
        result = result <??> 2
    #endif
    #if os(Windows)
        result = result <~~> 2
        result = ^^^result
    #endif
    return result
}
