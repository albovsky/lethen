// The other file's skipped clause spells `self.fixturePrivateGlobal6`, which no file but this one can
// resolve to this global, and no member access can resolve to a global at all.
private let fixturePrivateGlobal6 = 0
let fixtureInternalGlobal6 = 0
// Named by a bare identifier in the same clause, which is how a global is named: the control for both.
let fixtureBareGlobal6 = 0

class FixtureOwnFile6 {
    // Read only in a skipped clause of this file, the one file that can see it.
    private var tick6 = 0
    // Used-but-not-compared control: read in the clause this build did compile.
    var taken6 = 0

    func read6() -> Int {
        #if os(Windows)
            return self.tick6
        #else
            return taken6
        #endif
    }
}

public func fixtureOwnFile6() {
    _ = FixtureOwnFile6().read6()
}
