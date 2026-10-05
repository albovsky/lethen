@testable import ConfigurationsProject
import XCTest

// Type aliases, not calls, so the test bundle needs nothing linked from the tool.
typealias UsedByEveryTestBuild = ReferencedOnlyFromTests
#if !DEBUG
    typealias UsedByReleaseTestBuild = ReferencedOnlyFromReleaseTests
#endif

final class ConfigurationsProjectTests: XCTestCase {
    func testNothing() {}
}
