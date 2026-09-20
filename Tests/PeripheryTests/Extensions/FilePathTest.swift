import Foundation
import SystemPackage
import XCTest

final class FilePathTest: XCTestCase {
    func testChdirRestoresDirectoryAfterError() throws {
        enum Expected: Error { case failure }
        let original = FilePath.current
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(original.string)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertThrowsError(try FilePath(directory.path).chdir { throw Expected.failure }) {
            XCTAssertTrue($0 is Expected)
        }
        XCTAssertEqual(FilePath.current, original)
    }

    func testChdirRejectsMissingDirectory() {
        var executed = false
        let missing = FilePath("/tmp/lethen-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try missing.chdir { executed = true })
        XCTAssertFalse(executed)
    }

    func testChdirDoesNotMisreportExistingFileAsMissing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try FilePath(file.path).chdir {}) {
            XCTAssertNotEqual(($0 as NSError).code, NSFileReadNoSuchFileError)
            XCTAssertTrue(String(describing: $0).contains(file.path))
        }
    }

    func testMakeAbsolute() {
        let current = FilePath("/current")
        XCTAssertEqual(FilePath.makeAbsolute("/a", relativeTo: current).string, "/a")
        XCTAssertEqual(FilePath.makeAbsolute("a", relativeTo: current).string, "/current/a")
        XCTAssertEqual(FilePath.makeAbsolute("./a", relativeTo: current).string, "/current/a")
    }

    func testRelativeTo() {
        XCTAssertEqual(FilePath("/a/b/c").relativeTo(FilePath("/a/b/c")).string, ".")
        XCTAssertEqual(FilePath("/a/b/c/d").relativeTo(FilePath("/a/b")).string, "c/d")
        XCTAssertEqual(FilePath("/a/b/c/d").relativeTo(FilePath("/a/b/c")).string, "d")
        XCTAssertEqual(FilePath("/a/b").relativeTo(FilePath("/a/b/c/d")).string, "../..")
    }
}
