import Logger
import Shared
import XCTest

final class SetupGuideHelpersTest: XCTestCase {
    func testSelectSingleReturnsChosenOption() throws {
        let helpers = makeHelpers(inputs: ["2"])
        XCTAssertEqual(try helpers.select(single: ["a", "b", "c"]), "b")
    }

    func testSelectSingleRepromptsAfterInvalidInput() throws {
        let helpers = makeHelpers(inputs: ["x", "9", " 3 "])
        XCTAssertEqual(try helpers.select(single: ["a", "b", "c"]), "c")
    }

    func testSelectSingleThrowsWhenInputEnds() {
        let helpers = makeHelpers(inputs: ["x"])
        XCTAssertThrowsError(try helpers.select(single: ["a"])) { error in
            assertGuidedSetupError(error)
        }
    }

    func testSelectMultipleReturnsChosenOptions() throws {
        let helpers = makeHelpers(inputs: ["1 3"])
        XCTAssertEqual(try helpers.select(multiple: ["a", "b", "c"]).selectedValues, ["a", "c"])
    }

    func testSelectMultipleRepromptsAfterInvalidInput() throws {
        let helpers = makeHelpers(inputs: ["1 9", "", "2"])
        XCTAssertEqual(try helpers.select(multiple: ["a", "b", "c"]).selectedValues, ["b"])
    }

    func testSelectMultipleThrowsWhenInputEnds() {
        let helpers = makeHelpers(inputs: [])
        XCTAssertThrowsError(try helpers.select(multiple: ["a"])) { error in
            assertGuidedSetupError(error)
        }
    }

    func testSelectBooleanAcceptsYesAndNo() throws {
        XCTAssertTrue(try makeHelpers(inputs: ["Y"]).selectBoolean())
        XCTAssertFalse(try makeHelpers(inputs: ["no"]).selectBoolean())
        XCTAssertTrue(try makeHelpers(inputs: ["maybe", "", "yes"]).selectBoolean())
    }

    func testSelectBooleanThrowsWhenInputEnds() {
        XCTAssertThrowsError(try makeHelpers(inputs: ["maybe"]).selectBoolean()) { error in
            assertGuidedSetupError(error)
        }
    }

    // MARK: - Private

    private func makeHelpers(inputs: [String]) -> SetupGuideHelpers {
        let helpers = SetupGuideHelpers(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        var remaining = inputs
        helpers.readInput = {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
        return helpers
    }

    private func assertGuidedSetupError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? PeripheryError, case .guidedSetupError = error else {
            return XCTFail("Expected a guided setup error, got: \(error)", file: file, line: line)
        }
    }
}
