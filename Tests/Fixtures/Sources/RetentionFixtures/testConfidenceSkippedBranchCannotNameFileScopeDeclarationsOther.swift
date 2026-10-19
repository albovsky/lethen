// The Pett shape: a type in another file whose members are spelled `self.<name>` in a clause this build
// skipped, where the same names are also declared at file scope.
class FixtureOtherFile6 {
    let fixturePrivateGlobal6 = 0
    let fixtureInternalGlobal6 = 0

    func report6() {
        #if os(Windows)
            _ = self.fixturePrivateGlobal6
            _ = self.fixtureInternalGlobal6
            _ = fixtureBareGlobal6
            _ = fixtureSetPrivateGlobal6
        #endif
    }
}

public func fixtureOtherFile6() {
    FixtureOtherFile6().report6()
}
