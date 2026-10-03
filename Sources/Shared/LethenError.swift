import Foundation
import SystemPackage

public enum LethenError: Error, LocalizedError, CustomStringConvertible {
    case shellCommandFailed(cmd: [String], status: Int32, output: String)
    case shellOutputEncodingFailed(cmd: [String], encoding: String.Encoding)
    case usageError(String)
    case underlyingError(Error)
    case invalidScheme(name: String, project: String)
    case sourceGraphIntegrityError(message: String)
    case guidedSetupError(message: String)
    case updateCheckError(message: String)
    case xcodebuildNotConfigured
    case pathDoesNotExist(path: String)
    case foundIssues(count: Int)
    case packageError(message: String)
    case swiftVersionParseError(fullVersion: String)
    case swiftVersionUnsupportedError(version: String, minimumVersion: String)
    case jsonDeserializationError(error: Error, json: String)
    case indexStoreNotFound(derivedDataPath: String)
    case staleIndexStore(path: String, staleFiles: [String])
    case changeCurrentDirectoryFailed(FilePath)
    case unsafeDirectory(path: FilePath, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .shellCommandFailed(cmd, status, output):
            return "Shell command '\(cmd.shellRendered)' returned exit status '\(status)':\n\(output)"
        case let .shellOutputEncodingFailed(cmd, encoding):
            return "Shell command '\(cmd.shellRendered)' output encoding to \(encoding) failed."
        case let .usageError(message):
            return message
        case let .underlyingError(error):
            return describe(error)
        case let .invalidScheme(name, project):
            return "Scheme '\(name)' does not exist in '\(project)'."
        case let .sourceGraphIntegrityError(message):
            return message
        case let .guidedSetupError(message):
            return "\(message). Please refer to the documentation for instructions on configuring lethen manually - https://github.com/albovsky/lethen#readme"
        case let .updateCheckError(message):
            return message
        case .xcodebuildNotConfigured:
            return "Xcode is not configured for command-line use. Please run 'sudo xcode-select -s /Applications/Xcode.app'."
        case let .pathDoesNotExist(path):
            return "No such file or directory: \(path)."
        case let .foundIssues(count):
            return "Found \(count) \(count > 1 ? "issues" : "issue")."
        case let .packageError(message):
            return message
        case let .swiftVersionParseError(fullVersion):
            return "Failed to parse Swift version from: \(fullVersion)"
        case let .swiftVersionUnsupportedError(version, minimumVersion):
            return "This version of lethen only supports Swift >= \(minimumVersion), you're using \(version)."
        case let .jsonDeserializationError(error, json):
            return "JSON deserialization failed: \(describe(error))\nJSON:\n\(json)"
        case let .indexStoreNotFound(derivedDataPath):
            return "Failed to find index datastore at path: \(derivedDataPath)"
        case let .staleIndexStore(path, staleFiles):
            let examples = staleFiles.prefix(3).joined(separator: ", ")
            return "The index store at \(path) is stale: \(staleFiles.count) source files are newer than every index unit for them (\(examples)). Build the project again, or scan without --skip-build."
        case let .changeCurrentDirectoryFailed(path):
            return "Failed to change current directory to: \(path)"
        case let .unsafeDirectory(path, reason):
            return "Refusing to write to \(path): \(reason). Remove it and scan again."
        }
    }

    public var description: String {
        errorDescription!
    }

    // MARK: - Private

    private func describe(_ error: Error) -> String {
        "(\(type(of: error))) \(String(describing: error))"
    }
}
