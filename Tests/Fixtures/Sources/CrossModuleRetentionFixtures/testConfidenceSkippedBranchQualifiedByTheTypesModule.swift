import CrossModuleRetentionSupportFixtures

extension FixtureWidget11 {
    // A skipped construction qualified by the module that declares the type names this, an initializer of another module.
    init(fixtureTypesModule11 _: Int) { self.init() }
    // Control: a skipped construction qualified by a module that declares no such type.
    init(fixtureOtherModule11 _: Int) { self.init() }
}

// periphery:ignore
func fixtureQualifiedByTheTypesModule11() {
    #if os(Windows)
        _ = CrossModuleRetentionSupportFixtures.FixtureWidget11(fixtureTypesModule11: 1)
        _ = Elsewhere.FixtureWidget11(fixtureOtherModule11: 1)
    #else
        _ = FixtureWidget11()
    #endif
}
