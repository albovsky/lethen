// The old and the new attribution agree here: each alias is the only declaration on its line, so the reference on
// that line belongs to it however it is found. A used alias keeps its target and an unused one does not.
typealias FixtureDanglingUsedAlias3 = FixtureDanglingUsedTarget3
typealias FixtureDanglingUnusedAlias3 = FixtureDanglingUnusedTarget3

struct FixtureDanglingUsedTarget3 {}
struct FixtureDanglingUnusedTarget3 {}

public func fixtureDanglingRetainer3() {
    let _: FixtureDanglingUsedAlias3? = nil
}
