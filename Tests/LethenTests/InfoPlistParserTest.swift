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
}
