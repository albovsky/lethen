// Same shape as the dead alias fixture with the roles swapped: the declaration that starts the line is dead and the
// alias after it is live, so the target is used only through the alias. Attributing the reference to the dead
// neighbor reports a target that is in use.
struct FixtureDanglingDeadNeighbor2 {}; typealias FixtureDanglingLiveAlias2 = FixtureDanglingUsedTarget2

struct FixtureDanglingUsedTarget2 {}

public func fixtureDanglingRetainer2() {
    let _: FixtureDanglingLiveAlias2? = nil
}
