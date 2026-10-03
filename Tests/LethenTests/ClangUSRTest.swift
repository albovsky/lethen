import Configuration
@testable import Indexer
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class ClangUSRTest: XCTestCase {
    func testDropsTheModuleOfASwiftClassAndItsMembers() {
        XCTAssertEqual(ClangUSR.normalized("c:@M@App@objc(cs)Store"), "c:objc(cs)Store")
        XCTAssertEqual(ClangUSR.normalized("c:@M@App@objc(cs)Store(im)loadFrom:"), "c:objc(cs)Store(im)loadFrom:")
        XCTAssertEqual(ClangUSR.normalized("c:@M@App@objc(cs)Store(cpy)shared"), "c:objc(cs)Store(cpy)shared")
        XCTAssertEqual(ClangUSR.normalized("c:@M@App@objc(pl)Loading"), "c:objc(pl)Loading")
        XCTAssertEqual(ClangUSR.normalized("c:@M@App@E@Mode@ModeFast"), "c:@E@Mode@ModeFast")
    }

    func testDropsTheModuleOfAnExtensionMember() {
        XCTAssertEqual(ClangUSR.normalized("c:@CM@App@objc(cs)Store(im)reload"), "c:objc(cs)Store(im)reload")
        XCTAssertEqual(ClangUSR.normalized("c:@CM@App@@objc(cs)NSObject(im)reload"), "c:objc(cs)NSObject(im)reload")
    }

    func testLeavesOtherUSRsUnchanged() {
        XCTAssertEqual(ClangUSR.normalized("c:objc(cs)Store"), "c:objc(cs)Store")
        XCTAssertEqual(ClangUSR.normalized("c:@F@main"), "c:@F@main")
        XCTAssertEqual(ClangUSR.normalized("s:3App5StoreC"), "s:3App5StoreC")
        XCTAssertEqual(ClangUSR.normalized("c:@M@"), "c:@M@")
        XCTAssertEqual(ClangUSR.normalized("c:@M@App"), "c:@M@App")
    }

    func testNamesTheModuleOfASwiftGeneratedUSR() {
        XCTAssertEqual(ClangUSR.module(of: "c:@M@WMFData@E@ImageWidth@ImageWidthW3840"), "WMFData")
        XCTAssertEqual(ClangUSR.module(of: "c:@M@App@objc(cs)Store(im)loadFrom:"), "App")
        XCTAssertEqual(ClangUSR.module(of: "c:@CM@App@objc(cs)Store(im)reload"), "App")
        XCTAssertEqual(ClangUSR.module(of: "c:@CM@App@@objc(cs)NSObject(im)reload"), "App")
        XCTAssertNil(ClangUSR.module(of: "c:objc(cs)Store"))
        XCTAssertNil(ClangUSR.module(of: "c:@E@Mode@ModeFast"))
        XCTAssertNil(ClangUSR.module(of: "c:@M@"))
        XCTAssertNil(ClangUSR.module(of: "c:@M@App"))
        XCTAssertNil(ClangUSR.module(of: "s:3App5StoreC"))
    }

    func testResolvesByTheUSRThenByTheModulelessForm() {
        let graph = makeGraph()
        let store = add(to: graph, "Store", usr: "c:@M@App@objc(cs)Store")
        let resolver = ObjCReferenceIndexer.USRResolver(graph: graph)

        XCTAssertTrue(resolver.resolve("c:@M@App@objc(cs)Store")?.declaration === store)
        let moduleless = resolver.resolve("c:objc(cs)Store")
        XCTAssertTrue(moduleless?.declaration === store)
        XCTAssertEqual(moduleless?.usr, "c:@M@App@objc(cs)Store")
        XCTAssertNil(resolver.resolve("c:objc(cs)Other"))
    }

    /// Two modules exposing the same Objective-C name leave the module-less USR ambiguous.
    func testAmbiguousModulelessUSRResolvesToNothing() {
        let graph = makeGraph()
        let app = add(to: graph, "Store", usr: "c:@M@App@objc(cs)Store")
        add(to: graph, "Store", usr: "c:@M@Kit@objc(cs)Store")
        let resolver = ObjCReferenceIndexer.USRResolver(graph: graph)

        XCTAssertNil(resolver.resolve("c:objc(cs)Store"))
        XCTAssertTrue(resolver.resolve("c:@M@App@objc(cs)Store")?.declaration === app)
    }

    /// Only declarations exposed to Objective-C take part in the module-less lookup.
    func testDeclarationNotExposedToObjectiveCIsNotResolvedByModulelessForm() {
        let graph = makeGraph()
        add(to: graph, "Store", usr: "c:@M@App@objc(cs)Store", isObjcAccessible: false)
        let resolver = ObjCReferenceIndexer.USRResolver(graph: graph)

        XCTAssertNil(resolver.resolve("c:objc(cs)Store"))
    }

    // MARK: - Private

    private func makeGraph() -> SourceGraph {
        SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
    }

    @discardableResult
    private func add(to graph: SourceGraph, _ name: String, usr: String, isObjcAccessible: Bool = true) -> Declaration {
        let module = String(usr.split(separator: "@")[2])
        let location = Location(file: SourceFile(path: FilePath("/\(module)/\(name).swift"), modules: [module]), line: 1, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: [usr], location: location)
        declaration.isObjcAccessible = isObjcAccessible
        graph.add(declaration)
        return declaration
    }
}
