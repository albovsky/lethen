@testable import ConfigurationsProject
import XCTest

final class ConfigurationsProjectTests: XCTestCase {
    func testNothing() {
        calledOnlyFromTests()
        #if !DEBUG
            calledOnlyFromReleaseTests()
        #endif
    }
}
