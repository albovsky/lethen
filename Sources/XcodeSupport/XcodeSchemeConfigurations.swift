import Foundation
import SystemPackage
import XcodeProj

/// The build configurations a scheme's Test and Launch actions use. `build-for-testing` without `-configuration`
/// builds the Test configuration; the Launch configuration is the one the app runs with.
public struct XcodeSchemeConfigurations: Equatable, Sendable {
    public let test: String?
    public let launch: String?

    public init(test: String?, launch: String?) {
        self.test = test
        self.launch = launch
    }

    /// Reads the scheme named `scheme` from the first of `containers` (`.xcodeproj` or `.xcworkspace` paths) that
    /// defines it, looking at its shared schemes before `user`'s own; other users' private schemes are not visible to
    /// `xcodebuild` and are ignored. A scheme Xcode generates on the fly has no file and yields `nil`, as does one
    /// that does not parse.
    static func read(scheme: String, in containers: [FilePath], user: String = NSUserName()) -> Self? {
        // The scheme name is appended literally, never globbed, so a name such as `App[Dev]` matches only itself.
        let fileName = "\(scheme).xcscheme"
        let candidates = containers.flatMap { container in
            [
                container.appending("xcshareddata/xcschemes/\(fileName)"),
                container.appending("xcuserdata/\(user).xcuserdatad/xcschemes/\(fileName)"),
            ]
        }

        guard let path = candidates.first(where: \.exists),
              let scheme = try? XCScheme(pathString: path.string)
        else { return nil }

        return .init(test: scheme.testAction?.buildConfiguration, launch: scheme.launchAction?.buildConfiguration)
    }
}
