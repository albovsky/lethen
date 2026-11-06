// The right-hand side of a type alias is a reference the index records without a containing declaration. The alias
// shares its line with a live declaration that starts earlier on the line, so attributing the reference to a
// declaration on the same line, rather than to the alias whose range contains it, keeps the target alive.
struct FixtureDanglingLiveNeighbor1 {}; typealias FixtureDanglingDeadAlias1 = FixtureDanglingDeadTarget1

struct FixtureDanglingDeadTarget1 {}

public func fixtureDanglingRetainer1() {
    _ = FixtureDanglingLiveNeighbor1()
}
