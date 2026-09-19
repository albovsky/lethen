import Foundation
import SystemPackage

public extension FilePath {
    @inlinable static var current: FilePath {
        Self(fileManager.currentDirectoryPath)
    }

    @inlinable
    static func makeAbsolute(_ filePath: String, relativeTo relativePath: FilePath = .current) -> FilePath {
        makeAbsolute(FilePath(filePath), relativeTo: relativePath)
    }

    @inlinable
    static func makeAbsolute(_ filePath: FilePath, relativeTo relativePath: FilePath = .current) -> FilePath {
        var filePath = filePath
        _ = filePath.removePrefix("./")
        return relativePath.pushing(filePath)
    }

    @inlinable
    func makeAbsolute(relativeTo relativePath: FilePath = .current) -> FilePath {
        Self.makeAbsolute(self, relativeTo: relativePath)
    }

    @inlinable var exists: Bool {
        fileManager.fileExists(atPath: lexicallyNormalized().string)
    }

    @inlinable var url: URL {
        URL(fileURLWithPath: lexicallyNormalized().string)
    }

    /// Changes the process-global directory; callers must serialize access and keep
    /// the original directory present for the duration of the closure.
    @inlinable
    func chdir(closure: () throws -> Void) throws {
        let previous = Self.current
        guard fileManager.changeCurrentDirectoryPath(string) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSFilePathErrorKey: string,
                                     NSLocalizedDescriptionKey: "Failed to change working directory to \(string)."])
        }

        defer { _ = fileManager.changeCurrentDirectoryPath(previous.string) }
        try closure()
    }

    @inlinable
    func relativeTo(_ relativePath: FilePath) -> FilePath {
        let components = lexicallyNormalized().components.map(\.string)
        let relativePathComponents = relativePath.lexicallyNormalized().components.map(\.string)
        var commonPathComponents: [String] = []

        for component in components {
            guard relativePathComponents.count > commonPathComponents.count else { break }
            guard relativePathComponents[commonPathComponents.count] == component else { break }

            commonPathComponents.append(component)
        }

        let relative = Array(repeating: "..", count: relativePathComponents.count - commonPathComponents.count)
        let suffix = components.suffix(components.count - commonPathComponents.count)
        var newComponents = (relative + suffix).compactMap { Component($0) }

        if newComponents.isEmpty {
            newComponents = [Component(".")]
        }

        return FilePath(root: nil, newComponents)
    }

    // MARK: - Private

    @usableFromInline internal static var fileManager: FileManager {
        FileManager.default
    }

    @usableFromInline internal var fileManager: FileManager {
        Self.fileManager
    }
}

extension FilePath: Swift.Comparable {
    public static func < (lhs: FilePath, rhs: FilePath) -> Bool {
        lhs.lexicallyNormalized().string < rhs.lexicallyNormalized().string
    }
}
