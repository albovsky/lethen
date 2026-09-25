import Extensions
import Foundation

public struct SwiftVersion {
    static let minimumVersion = "6.1.2"

    public let version: VersionString
    public let fullVersion: String

    public init(shell: Shell) throws {
        fullVersion = try shell.exec(["swift", "-version"]).trimmed
        version = try SwiftVersionParser.parse(fullVersion)
    }

    public func validateVersion() throws {
        if version.isVersion(lessThan: Self.minimumVersion) {
            throw PeripheryError.swiftVersionUnsupportedError(
                version: fullVersion,
                minimumVersion: Self.minimumVersion
            )
        }
    }
}
