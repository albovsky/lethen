import Foundation
import SystemPackage

/// The schemes shared through `xcshareddata/xcschemes` of `.xcodeproj` and `.xcworkspace` containers, which
/// are the ones every user of the project and `xcodebuild -list` see. A user's private schemes live in
/// `xcuserdata`, so they never decide which scheme a scan builds on its own.
enum XcodeSharedSchemes {
    /// Sorted, deduplicated scheme names from every container's shared scheme directory. A container with no
    /// such directory contributes nothing; files without the `.xcscheme` extension are ignored, as is a
    /// `Pods.xcodeproj` container, whose schemes CocoaPods generates.
    static func names(in containers: [FilePath]) -> [String] {
        let suffix = ".xcscheme"
        var names: Set<String> = []
        for container in containers where container.lastComponent?.string != "Pods.xcodeproj" {
            let directory = container.appending("xcshareddata/xcschemes").string
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in files where file.hasSuffix(suffix) {
                names.insert(String(file.dropLast(suffix.count)))
            }
        }

        return names.sorted()
    }
}
