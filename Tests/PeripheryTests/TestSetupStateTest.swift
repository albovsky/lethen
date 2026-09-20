@testable import TestShared
import XCTest

final class TestSetupStateTest: XCTestCase {
    func testSetupStatePreservesErrorAndRecovers() {
        enum Expected: Error { case failure }
        let state = TestSetupState()
        state.capture { throw Expected.failure }
        XCTAssertThrowsError(try state.check()) { XCTAssertTrue($0 is Expected) }
        state.capture {}
        XCTAssertNoThrow(try state.check())
    }
}
