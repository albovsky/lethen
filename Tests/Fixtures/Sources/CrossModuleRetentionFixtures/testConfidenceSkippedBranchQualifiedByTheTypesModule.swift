import Foundation
import CrossModuleRetentionAliasFixtures
import CrossModuleRetentionSupportFixtures

extension FixtureWidget11 {
    // A skipped construction qualified by the module that declares the type names this, an initializer of another module.
    init(fixtureTypesModule11 _: Int) { self.init() }
    // A skipped construction through a type alias of a third module names this.
    init(fixtureAliasModule11 _: Int) { self.init() }
    // A skipped construction qualified by a module that re-exports the type's module names this.
    init(fixtureReexported11 _: Int) { self.init() }
    // Control: a skipped construction qualified by an imported module that declares no such type.
    init(fixtureOtherModule11 _: Int) { self.init() }
}

// periphery:ignore
func fixtureQualifiedByTheTypesModule11() {
    #if os(Windows)
        _ = CrossModuleRetentionSupportFixtures.FixtureWidget11(fixtureTypesModule11: 1)
        _ = CrossModuleRetentionAliasFixtures.FixtureRenamed11(fixtureAliasModule11: 1)
        _ = CrossModuleRetentionAliasFixtures.FixtureWidget11(fixtureReexported11: 1)
        _ = Foundation.FixtureWidget11(fixtureOtherModule11: 1)
    #else
        _ = FixtureRenamed11()
    #endif
}
