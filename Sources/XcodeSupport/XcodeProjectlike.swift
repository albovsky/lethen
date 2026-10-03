import Foundation
import SystemPackage

public protocol XcodeProjectlike: AnyObject {
    var path: FilePath { get }
    var targets: Set<XcodeTarget> { get }
    var type: String { get }
    var name: String { get }
    var sourceRoot: FilePath { get }
    /// The source roots of every project this container loads.
    var projectSourceRoots: [FilePath] { get }
    /// The files every project this container loads declares as file references, such as an `.xcconfig`,
    /// or as Run Script inputs.
    var declaredInputFiles: Set<FilePath> { get }
    /// Whether a Run Script phase of any project this container loads reads or writes a path that cannot be resolved,
    /// or writes a tracked file that no checked root or declared input reaches, so a build's inputs cannot all be checked.
    var hasUnenumerableBuildInputs: Bool { get }
    /// The project-level build configurations of every project this one loads, such as Debug and Release.
    var buildConfigurationNames: Set<String> { get }

    /// The names of the shared schemes this container defines, sorted; see `XcodeSharedSchemes`.
    var sharedSchemes: [String] { get }

    func schemes(additionalArguments: [String]) throws -> Set<String>
    /// The Test and Launch configurations of the scheme named `scheme`, if a scheme file defines it.
    func schemeConfigurations(named scheme: String) -> XcodeSchemeConfigurations?
}

public extension XcodeProjectlike {
    var projectSourceRoots: [FilePath] {
        [sourceRoot]
    }

    var declaredInputFiles: Set<FilePath> {
        []
    }

    var hasUnenumerableBuildInputs: Bool {
        false
    }

    var name: String {
        path.lastComponent?.stem ?? ""
    }
}
