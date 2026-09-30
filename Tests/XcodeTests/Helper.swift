import Foundation
import SystemPackage
@testable import TestShared

var UIKitProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/UIKitProject/UIKitProject.xcodeproj")
}

var ConfigurationsProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/ConfigurationsProject/ConfigurationsProject.xcodeproj")
}

var MixedLanguageProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/MixedLanguageProject/MixedLanguageProject.xcodeproj")
}

var SwiftUIProjectPath: FilePath {
    ProjectRootPath.appending("Tests/XcodeTests/SwiftUIProject/SwiftUIProject.xcodeproj")
}
