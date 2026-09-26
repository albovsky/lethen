import Configuration
import Foundation
import Logger
@testable import PeripheryKit
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class OutputFormatterTest: XCTestCase {
    private let root = FilePath.current
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    func testXcodeFormatUsesAbsolutePathsByDefault() throws {
        let output = try format(.xcode, [unusedClass()])
        XCTAssertEqual(output, "\(root.string)/Sources/A.swift:3:5: warning: Unused class 'Foo'")
    }

    func testXcodeFormatUsesRelativePathsWhenRequested() throws {
        let output = try format(.xcode, [unusedClass()], relativeResults: true)
        XCTAssertEqual(output, "Sources/A.swift:3:5: warning: Unused class 'Foo'")
    }

    func testXcodeFormatDescribesEveryHint() throws {
        let assignOnly = ScanResult(declaration: declaration(name: "count", kind: .varInstance, usr: "s:count"), annotation: .assignOnlyProperty)
        let redundantPublic = ScanResult(declaration: declaration(name: "Bar", kind: .struct, usr: "s:Bar"), annotation: .redundantPublicAccessibility(modules: ["App"]))
        let superfluous = ScanResult(declaration: declaration(name: "Baz", kind: .enum, usr: "s:Baz"), annotation: .superfluousIgnoreCommand)
        let output = try format(.xcode, [assignOnly, redundantPublic, superfluous], relativeResults: true)
        XCTAssertEqual(output.components(separatedBy: "\n"), [
            "Sources/A.swift:3:5: warning: Assign-only property 'count' is assigned, but never used",
            "Sources/A.swift:3:5: warning: Redundant public accessibility for struct 'Bar' (not used outside of App)",
            "Sources/A.swift:3:5: warning: Superfluous ignore comment for enum 'Baz' (declaration is referenced and should not be ignored)",
        ])
    }

    func testXcodeFormatWithNoResults() throws {
        XCTAssertEqual(try format(.xcode, []), "* No unused code detected.")
    }

    func testJsonFormatIncludesIdentityAndLocation() throws {
        let objects = try json(format(.json, [unusedClass()]))
        XCTAssertEqual(objects.count, 1)
        let object = try XCTUnwrap(objects.first)
        XCTAssertEqual(object["kind"] as? String, "class")
        XCTAssertEqual(object["name"] as? String, "Foo")
        XCTAssertEqual(object["modules"] as? [String], ["App"])
        XCTAssertEqual(object["modifiers"] as? [String], ["final"])
        XCTAssertEqual(object["accessibility"] as? String, "public")
        XCTAssertEqual(object["ids"] as? [String], ["s:Foo"])
        XCTAssertEqual(object["hints"] as? [String], ["unused"])
        XCTAssertEqual(object["location"] as? String, "\(root.string)/Sources/A.swift:3:5")
    }

    func testJsonFormatReportsRedundantConformancesAsSeparateEntries() throws {
        let objects = try json(format(.json, [redundantProtocol()]))
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["hints"] as? [String], ["redundantProtocol"])
        XCTAssertEqual(objects[1]["hints"] as? [String], ["redundantConformance(replace with: 'Q')"])
        XCTAssertEqual(objects[1]["ids"] as? [String], ["s:Conformance"])
        XCTAssertEqual(objects[1]["location"] as? String, "\(root.string)/Sources/B.swift:9:1")
    }

    func testCsvFormatWritesColumnsInHeaderOrder() throws {
        let lines = try format(.csv, [unusedClass()]).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Kind,Name,Modifiers,Attributes,Accessibility,IDs,Location,Hints")
        XCTAssertEqual(lines[1], "class,Foo,final,,public,s:Foo,\(root.string)/Sources/A.swift:3:5,unused")
    }

    func testGitHubActionsFormatRequiresRelativeResults() {
        let formatter = OutputFormat.githubActions.formatter.init(configuration: Configuration(), logger: logger)
        XCTAssertThrowsError(try formatter.format([unusedClass()], colored: false)) { error in
            guard let error = error as? PeripheryError, case .usageError = error else {
                return XCTFail("Expected a usage error, got: \(error)")
            }
        }
    }

    func testGitHubActionsFormatEmitsWorkflowCommands() throws {
        let output = try format(.githubActions, [unusedClass()], relativeResults: true)
        XCTAssertEqual(output, "::warning file=Sources/A.swift,line=3,col=5,title=unused::Unused class 'Foo'")
    }

    func testCheckstyleFormatEscapesMarkup() throws {
        let output = try format(.checkstyle, [unusedClass(named: "Foo<T>")], relativeResults: true)
        XCTAssertTrue(output.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<checkstyle version=\"4.3\">"))
        XCTAssertTrue(output.contains("<file name=\"Sources/A.swift\">"))
        XCTAssertTrue(output.contains("<error line=\"3\" column=\"5\" severity=\"warning\" message=\"Unused class "))
        XCTAssertTrue(output.contains("Foo&lt;T&gt;"))
        XCTAssertFalse(output.contains("Foo<T>"))
    }

    func testGitLabCodeQualityFormatFingerprintsBySymbol() throws {
        let object = try XCTUnwrap(json(format(.gitlabCodeQuality, [unusedClass()], relativeResults: true)).first)
        XCTAssertEqual(object["check_name"] as? String, "unused")
        XCTAssertEqual(object["fingerprint"] as? String, "s:Foo")
        XCTAssertEqual(object["severity"] as? String, "info")
        XCTAssertEqual(object["description"] as? String, "Unused class 'Foo'")
        let location = try XCTUnwrap(object["location"] as? [String: Any])
        XCTAssertEqual(location["path"] as? String, "Sources/A.swift")
        XCTAssertEqual((location["lines"] as? [String: Any])?["begin"] as? Int, 3)
    }

    func testCodeClimateFormatFingerprintsBySymbol() throws {
        let object = try XCTUnwrap(json(format(.codeclimate, [unusedClass()], relativeResults: true)).first)
        XCTAssertEqual(object["fingerprint"] as? String, "s:Foo")
        XCTAssertEqual(object["severity"] as? String, "major")
        XCTAssertEqual(object["description"] as? String, "Unused class 'Foo'")
    }

    func testGitHubMarkdownFormatCollapsesBeyondTenResults() throws {
        let one = try format(.githubMarkdown, [unusedClass()], relativeResults: true)
        XCTAssertTrue(one.hasPrefix("| 1 Result |\n| :- |\n"))
        XCTAssertFalse(one.contains("<details>"))

        let results = (0 ..< 12).map { unusedClass(named: "Foo\($0)", usr: "s:Foo\($0)", line: $0 + 1) }
        let many = try format(.githubMarkdown, results, relativeResults: true)
        XCTAssertTrue(many.hasPrefix("| 12 Results |"))
        XCTAssertTrue(many.contains("<summary>Show remaining 2 results</summary>"))
        XCTAssertEqual(try format(.githubMarkdown, []), "No unused code detected.")
    }

    // MARK: - Private

    private func format(_ format: OutputFormat, _ results: [ScanResult], relativeResults: Bool = false) throws -> String {
        let configuration = Configuration()
        configuration.relativeResults = relativeResults
        let formatter = format.formatter.init(configuration: configuration, logger: logger)
        return try XCTUnwrap(formatter.format(results, colored: false))
    }

    private func json(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func location(_ relativePath: String = "Sources/A.swift", line: Int = 3, column: Int = 5) -> Location {
        Location(file: SourceFile(path: root.appending(relativePath), modules: ["App"]), line: line, column: column)
    }

    private func declaration(name: String, kind: Declaration.Kind, usr: String, line: Int = 3) -> Declaration {
        let declaration = Declaration(name: name, kind: kind, usrs: [usr], location: location(line: line))
        declaration.modifiers = ["final"]
        declaration.accessibility = .init(value: .public, isExplicit: true)
        return declaration
    }

    private func unusedClass(named name: String = "Foo", usr: String = "s:Foo", line: Int = 3) -> ScanResult {
        ScanResult(declaration: declaration(name: name, kind: .class, usr: usr, line: line), annotation: .unused)
    }

    private func redundantProtocol() -> ScanResult {
        let conformance = Reference(name: "P", kind: .related, declarationKind: .protocol, usr: "s:Conformance", location: location("Sources/B.swift", line: 9, column: 1))
        let protocolDeclaration = Declaration(name: "P", kind: .protocol, usrs: ["s:P"], location: location())
        return ScanResult(declaration: protocolDeclaration, annotation: .redundantProtocol(references: [conformance], inherited: ["Q"]))
    }
}
