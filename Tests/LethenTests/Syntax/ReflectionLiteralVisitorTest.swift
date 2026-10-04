import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage
import XCTest

final class ReflectionLiteralVisitorTest: XCTestCase {
    func testLiteralsPassedToReflectionAPIsAreCollectedWithTheirSites() {
        let sites = collect("""
        let a = NSClassFromString("App.Foo")
        let b = NSSelectorFromString("handleTap:")
        let c = Selector("refresh")
        let d = Bundle.main.classNamed("Bar")
        let e = object.value(forKey: "title")
        object.setValue(1, forKeyPath: "user.name")
        let f = storyboard.instantiateViewController(withIdentifier: "DetailController")
        let g = UINib(nibName: "CardView", bundle: nil)
        """)
        XCTAssertEqual(sites, [
            "App": "NSClassFromString at Test.swift:1",
            "Foo": "NSClassFromString at Test.swift:1",
            "handleTap": "NSSelectorFromString at Test.swift:2",
            "refresh": "Selector at Test.swift:3",
            "Bar": "classNamed at Test.swift:4",
            "title": "value(forKey:) at Test.swift:5",
            "user": "setValue(forKeyPath:) at Test.swift:6",
            "name": "setValue(forKeyPath:) at Test.swift:6",
            "DetailController": "instantiateViewController(withIdentifier:) at Test.swift:7",
            "CardView": "UINib(nibName:) at Test.swift:8",
        ])
    }

    func testMirrorLabelComparisonIsCollected() {
        let sites = collect("""
        for child in Mirror(reflecting: value).children where child.label == "secret" {}
        """)
        XCTAssertEqual(sites, ["secret": "a Mirror label comparison at Test.swift:1"])
    }

    /// A bare literal, whatever it says, is not a reflection call: log messages, coding keys and fixtures stay out.
    func testBareLiteralsAndOtherCallsAreNotCollected() {
        let sites = collect("""
        let key = "username"
        log("userName")
        let other = lookup(name: "Widget")
        if kind == "Widget" {}
        let interpolated = NSClassFromString("App.\\(name)")
        let prose = NSClassFromString("not a symbol")
        """)
        XCTAssertEqual(sites, [:])
    }

    func testTheSmallestSiteWinsForAName() {
        let sites = collect("""
        let b = NSSelectorFromString("go")
        let a = NSClassFromString("go")
        """)
        XCTAssertEqual(sites, ["go": "NSClassFromString at Test.swift:2"])
    }

    private func collect(_ source: String) -> [String: String] {
        let file = SourceFile(path: FilePath("/tmp/Test.swift"), modules: ["Test"])
        let syntax = Parser.parse(source: source)
        let locationBuilder = SourceLocationBuilder(
            file: file, locationConverter: SourceLocationConverter(fileName: "Test.swift", tree: syntax)
        )
        let visitor = ReflectionLiteralVisitor(locationBuilder: locationBuilder)
        visitor.walk(syntax)
        return visitor.sites
    }
}
