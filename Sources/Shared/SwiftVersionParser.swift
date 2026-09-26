import Extensions
import Foundation

enum SwiftVersionParser {
    static func parse(_ fullVersion: String) throws -> VersionString {
        let components = fullVersion.components(separatedBy: "Swift version")

        guard components.count > 1,
              let rawVersion = components.last?.trimmed.split(separator: " ").first,
              rawVersion.first?.isNumber == true
        else {
            throw LethenError.swiftVersionParseError(fullVersion: fullVersion)
        }

        let version = rawVersion.split(separator: "-").first ?? rawVersion
        return String(version)
    }
}
