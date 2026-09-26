import Configuration
@testable import PeripheryKit
import Shared
import SystemPackage
import XCTest

class FixtureSourceGraphTestCase: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        setupState.capture {
            try build(projectPath: FixturesProjectPath)
        }
    }

    @discardableResult
    func analyze(
        retainPublic: Bool = false,
        noRetainSPI: [String] = [],
        retainObjcAccessible: Bool = false,
        retainObjcAnnotated: Bool = false,
        disableRedundantPublicAnalysis: Bool = false,
        superfluousIgnoreComments: Bool = true,
        retainCodableProperties: Bool = false,
        retainEncodableProperties: Bool = false,
        retainEquatableProperties: Bool = false,
        retainHashableProperties: Bool = false,
        retainUnusedProtocolFuncParams: Bool = false,
        retainAssignOnlyProperties: Bool = false,
        retainAssignOnlyPropertyTypes: [String] = [],
        externalCodableProtocols: [String] = [],
        additionalFilesToIndex: [FilePath] = [],
        externalTestCaseClasses: [String] = [],
        retainFiles: [String] = [],
        testBlock: () throws -> Void
    ) throws -> [ScanResult] {
        let configuration = Configuration()
        configuration.retainPublic = retainPublic
        configuration.noRetainSPI = noRetainSPI
        configuration.retainObjcAccessible = retainObjcAccessible
        configuration.retainObjcAnnotated = retainObjcAnnotated
        configuration.retainAssignOnlyProperties = retainAssignOnlyProperties
        configuration.disableRedundantPublicAnalysis = disableRedundantPublicAnalysis
        configuration.superfluousIgnoreComments = superfluousIgnoreComments
        configuration.externalCodableProtocols = externalCodableProtocols
        configuration.retainCodableProperties = retainCodableProperties
        configuration.retainEncodableProperties = retainEncodableProperties
        configuration.retainEquatableProperties = retainEquatableProperties
        configuration.retainHashableProperties = retainHashableProperties
        configuration.retainUnusedProtocolFuncParams = retainUnusedProtocolFuncParams
        configuration.retainAssignOnlyPropertyTypes = retainAssignOnlyPropertyTypes
        configuration.externalTestCaseClasses = externalTestCaseClasses
        configuration.retainFiles = retainFiles

        configuration.buildFilenameMatchers()

        if !testFixturePath.exists {
            throw LethenError.packageError(message: "Test fixture \(testFixturePath.string) does not exist")
        }

        try Self.index(sourceFiles: [testFixturePath] + additionalFilesToIndex, configuration: configuration)
        try testBlock()
        return Self.results
    }
}
