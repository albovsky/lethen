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
    /// defines it, looking at its shared schemes before any user's. A scheme Xcode generates on the fly has no
    /// file and yields `nil`, as does one that does not parse.
    static func read(scheme: String, in containers: [FilePath]) -> Self? {
        let fileName = "\(scheme).xcscheme"
        let candidates = containers.flatMap { container in
            // The scheme name is appended literally, never globbed, so a name such as `App[Dev]` matches only itself.
            let userDirectories = (try? FileManager.default.contentsOfDirectory(atPath: container.appending("xcuserdata").string)) ?? []
            let userSchemes = userDirectories
                .filter { $0.hasSuffix(".xcuserdatad") }
                .sorted()
                .map { container.appending("xcuserdata/\($0)/xcschemes/\(fileName)") }
            return [container.appending("xcshareddata/xcschemes/\(fileName)")] + userSchemes
        }

        guard let path = candidates.first(where: \.exists),
              let scheme = try? XCScheme(pathString: path.string)
        else { return nil }

        return .init(test: scheme.testAction?.buildConfiguration, launch: scheme.launchAction?.buildConfiguration)
    }
}
