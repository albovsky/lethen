import ArgumentParser
import Foundation
import Shared
import SystemPackage

struct ClearCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-cache",
        abstract: "Clear lethen's build cache"
    )

    func run() throws {
        try Self.removeCache(at: Constants.cachePath())
    }

    /// Removes the cache directory and everything in it; a cache that does not exist is already clear.
    static func removeCache(at path: FilePath) throws {
        guard path.exists else { return }

        try FileManager.default.removeItem(atPath: path.string)
    }
}
