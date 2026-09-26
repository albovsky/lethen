import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
import XCTest

final class GenericProjectDriverTest: XCTestCase {
    private var directory: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-generic-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory.string)
        directory = nil
        try super.tearDownWithError()
    }

    func testMissingConfigIsReported() {
        XCTAssertThrowsError(try GenericProjectDriver(genericProjectConfig: directory.appending("missing.json"), configuration: Configuration())) { error in
            guard let error = error as? LethenError, case .pathDoesNotExist = error else {
                return XCTFail("Expected a missing path error, got: \(error)")
            }
        }
    }

    func testEveryKeyIsRequired() throws {
        let config = try write(#"{"indexstores": [], "plists": [], "xibs": [], "xcdatamodels": [], "test_targets": []}"#)
        XCTAssertThrowsError(try GenericProjectDriver(genericProjectConfig: config, configuration: Configuration())) { error in
            XCTAssertTrue(error is DecodingError, "Expected a decoding error, got: \(error)")
        }
    }

    func testPlanResolvesResourcePathsAndReadsNoStoresWhenNoneAreListed() throws {
        let config = try write("""
        {
            "indexstores": [],
            "plists": ["Info.plist"],
            "xibs": ["Views/Main.storyboard"],
            "xcdatamodels": ["Model.xcdatamodeld/Model.xcdatamodel"],
            "xcmappingmodels": [],
            "test_targets": ["AppTests"]
        }
        """)
        let driver = try GenericProjectDriver(genericProjectConfig: config, configuration: Configuration())
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let plan = try driver.plan(logger: logger.contextualized(with: "test"))

        XCTAssertTrue(plan.sourceFiles.isEmpty)
        XCTAssertEqual(plan.plistPaths.map(\.lastComponent?.string), ["Info.plist"])
        XCTAssertTrue(plan.plistPaths.allSatisfy(\.isAbsolute))
        XCTAssertEqual(plan.xibPaths.map(\.lastComponent?.string), ["Main.storyboard"])
        XCTAssertEqual(plan.xcDataModelPaths.map(\.lastComponent?.string), ["Model.xcdatamodel"])
        XCTAssertTrue(plan.xcMappingModelPaths.isEmpty)
    }

    // MARK: - Private

    private func write(_ json: String) throws -> FilePath {
        let path = directory.appending("config.json")
        try json.write(toFile: path.string, atomically: true, encoding: .utf8)
        return path
    }
}
