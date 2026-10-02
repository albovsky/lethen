import Foundation
import SystemPackage

public protocol XcodeProjectlike: AnyObject {
    var path: FilePath { get }
    var targets: Set<XcodeTarget> { get }
    var type: String { get }
    var name: String { get }
    var sourceRoot: FilePath { get }
    /// The project-level build configurations of every project this one loads, such as Debug and Release.
    var buildConfigurationNames: Set<String> { get }

    /// The names of the shared schemes this container defines, sorted; see `XcodeSharedSchemes`.
    var sharedSchemes: [String] { get }

    func schemes(additionalArguments: [String]) throws -> Set<String>
    /// The Test and Launch configurations of the scheme named `scheme`, if a scheme file defines it.
    func schemeConfigurations(named scheme: String) -> XcodeSchemeConfigurations?
}

public extension XcodeProjectlike {
    var name: String {
        path.lastComponent?.stem ?? ""
    }
}
