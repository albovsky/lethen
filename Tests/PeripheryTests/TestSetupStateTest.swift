@testable import TestShared
import XCTest

final class TestSetupStateTest: XCTestCase {
    func testSetupStateKeepsFirstFailureAndSkipsLaterCaptures() {
        enum Expected: Error { case first, second }
        let state = TestSetupState()
        XCTAssertNoThrow(try state.check())
        state.capture { throw Expected.first }
        var ranLaterCapture = false
        state.capture {
            ranLaterCapture = true
            throw Expected.second
        }
        XCTAssertFalse(ranLaterCapture)
        XCTAssertThrowsError(try state.check()) { error in
            guard case Expected.first = error else { return XCTFail("Expected the first failure, got: \(error)") }
        }
    }
}
