import Foundation
import SystemPackage
@testable import TestShared

var UIKitProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/UIKitProject/UIKitProject.xcodeproj")
}

var ConfigurationsProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/ConfigurationsProject/ConfigurationsProject.xcodeproj")
}

var SwiftUIProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/SwiftUIProject/SwiftUIProject.xcodeproj")
}
