// The alias names `Target`, the type it is declared in. The reference belongs to the alias, its lexical container, and
// is dropped later because `Target` is an ancestor of the alias. Skipping the alias and `Target` as candidates would
// promote the reference to the live namespace, which is not `Target`'s descendant, and retain `Target`.
enum FixtureDanglingNamespace4 {
    struct Target {
        typealias Dead = Target
    }
}

public func fixtureDanglingRetainer4() {
    _ = FixtureDanglingNamespace4.self
}
