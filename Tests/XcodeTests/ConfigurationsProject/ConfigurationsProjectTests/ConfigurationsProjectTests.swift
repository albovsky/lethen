@testable import ConfigurationsProject
import XCTest

final class ConfigurationsProjectTests: XCTestCase {
    /// Local type aliases are compiled away, so the test bundle needs nothing linked from the tool, and the index
    /// still records the references from this test method.
    func testNothing() {
        typealias UsedByEveryTestBuild = ReferencedOnlyFromTests
        #if !DEBUG
            typealias UsedByReleaseTestBuild = ReferencedOnlyFromReleaseTests
        #endif
    }
}
