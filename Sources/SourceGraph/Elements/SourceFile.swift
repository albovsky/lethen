import Foundation
import SystemPackage

public final class SourceFile {
    public let path: FilePath
    public let modules: Set<String>
    public var importStatements: [ImportStatement] = []
    public var importsSwiftTesting = false
    /// Qualified names of the modules (and submodules) whose C or Objective-C symbols the file's clang
    /// units reference, as read from the index; empty for Swift files. Swift declarations referenced
    /// from Objective-C are references in the graph, like Swift ones.
    public var clangReferencedModules: Set<String> = []

    public init(path: FilePath, modules: Set<String>) {
        self.path = path
        self.modules = modules
    }
}

extension SourceFile: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

extension SourceFile: Equatable {
    public static func == (lhs: SourceFile, rhs: SourceFile) -> Bool {
        lhs.path == rhs.path
    }
}

extension SourceFile: Comparable {
    public static func < (lhs: SourceFile, rhs: SourceFile) -> Bool {
        lhs.path.string < rhs.path.string
    }
}
