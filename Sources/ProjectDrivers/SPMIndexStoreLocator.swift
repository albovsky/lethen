import Shared
import SystemPackage

/// Both native SwiftPM and swiftbuild place explicitly enabled indexes beneath
/// the active binary directory. swiftbuild's implicit auto-index store is elsewhere;
/// never fall back to it because it may belong to a previous configuration.
enum SPMIndexStoreLocator {
    static func indexStorePath(binPath: FilePath) throws -> FilePath {
        guard binPath.isAbsolute else {
            throw PeripheryError.packageError(message: "SwiftPM binary directory must be absolute: \(binPath)")
        }

        return binPath.appending("index/store")
    }
}
