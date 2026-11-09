import CrossModuleRetentionShadowFixtures
import CrossModuleRetentionSupportFixtures

extension FixtureWidget11 {
    init(fixtureNested13 _: Int) { self.init() }
    init(fixtureUnused13 _: Int) { self.init() }
    init(fixtureLive13 _: Int) { self.init() }
}

// periphery:ignore
func fixtureUnscannedModuleQualifier13() {
    #if os(Windows)
        _ = CrossModuleRetentionShadowFixtures.FixtureWidget11(fixtureNested13: 1)
    #else
        _ = CrossModuleRetentionShadowFixtures.self
        _ = FixtureWidget11(fixtureLive13: 1)
    #endif
}

extension Int16 {
    init(fixtureImported13 _: Int) { self = 0 }
    init(fixtureInt16Live13 _: Int) { self = 0 }
}

// periphery:ignore
func fixtureImportedShadow13() {
    #if os(Windows)
        _ = CShort(fixtureImported13: 1)
    #else
        _ = Int16(fixtureInt16Live13: 2)
    #endif
}
