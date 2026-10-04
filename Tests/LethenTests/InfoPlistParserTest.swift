import Foundation
@testable import Indexer
import SystemPackage
import XCTest

final class InfoPlistParserTest: XCTestCase {
    func testReadsDocumentClassInsideDocumentTypes() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>NotAClass</string>
          <key>NSPrincipalClass</key><string>MyApp.Application</string>
          <key>CFBundleDocumentTypes</key>
          <array><dict>
            <key>CFBundleTypeName</key><string>Text</string>
            <key>NSDocumentClass</key><string>MyApp.TextDocument</string>
          </dict></array>
        </dict></plist>
        """
        let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-\(UUID().uuidString).plist").path)
        try plist.write(toFile: path.string, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let names = try InfoPlistParser(path: path).parse().map(\.name).sorted()
        XCTAssertEqual(names, ["Application", "TextDocument"])
    }

    /// A binary property list, which a synchronized folder's `.plist` resource may be, is read like an XML one.
    func testReadsBinaryPropertyLists() throws {
        let plist: [String: Any] = ["CFBundleName": "NotAClass", "NSPrincipalClass": "MyApp.Application"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertTrue(data.starts(with: Data("bplist".utf8)))
        let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-\(UUID().uuidString).plist").path)
        try data.write(to: path.url)
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        XCTAssertEqual(try InfoPlistParser(path: path).parse().map(\.name), ["Application"])
    }

    func testReadsOpenStepPropertyLists() throws {
        let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-\(UUID().uuidString).plist").path)
        try "{ CFBundleName = NotAClass; NSPrincipalClass = \"MyApp.Application\"; }".write(toFile: path.string, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        XCTAssertEqual(try InfoPlistParser(path: path).parse().map(\.name), ["Application"])
    }

    /// The control: text that is no property list in any format still fails, as before.
    func testNonPropertyListStillThrows() throws {
        let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-\(UUID().uuidString).plist").path)
        try "not a plist, just some words".write(toFile: path.string, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        XCTAssertThrowsError(try InfoPlistParser(path: path).parse())
    }
}
