import Foundation
import SourceGraph
import SystemPackage
import XcodeProj

public final class XcodeTarget {
    let project: XcodeProject

    private let target: PBXTarget
    private var files: [ProjectFileKind: Set<FilePath>] = [:]
    private var identifiedFiles = false

    required init(project: XcodeProject, target: PBXTarget) {
        self.project = project
        self.target = target
    }

    public var isTestTarget: Bool {
        target.productType?.rawValue.contains("test") ?? false
    }

    public var name: String {
        target.name
    }

    /// The names of the targets this one depends on: the explicit dependencies, which Xcode builds before it
    /// (a dependency on a target of another project of the workspace is a proxy whose `remoteInfo` is that
    /// target's name), and the targets of this project whose product it links, which Xcode treats as implicit
    /// dependencies.
    public var dependencyNames: Set<String> {
        let explicit = target.dependencies.compactMapSet { $0.target?.name ?? $0.targetProxy?.remoteInfo }
        let linkedFiles = target.buildPhases.compactMap { $0 as? PBXFrameworksBuildPhase }
            .flatMap { $0.files ?? [] }
            .compactMap(\.file)
        let linked = project.xcodeProject.pbxproj.nativeTargets
            .filter { candidate in candidate !== target && linkedFiles.contains { $0 === candidate.product } }
            .map(\.name)
        return explicit.union(linked)
    }

    /// The names the target's Swift module can have, which its index units carry: each plain
    /// `PRODUCT_MODULE_NAME` a configuration sets, and Xcode's default, the target name as a C identifier,
    /// for a configuration that sets none. Which configuration a unit came from is not known here.
    public var moduleNames: Set<String> {
        let configurations = target.buildConfigurationList?.buildConfigurations ?? []
        var names: Set<String> = []
        for configuration in configurations {
            if let configured = configuration.buildSettings["PRODUCT_MODULE_NAME"]?.stringValue, !configured.contains("$(") {
                names.insert(configured)
            } else {
                names.insert(Self.defaultModuleName(forTarget: name))
            }
        }
        return names.isEmpty ? [Self.defaultModuleName(forTarget: name)] : names
    }

    /// The module Xcode names a target by default: its name with every character that is not an ASCII
    /// letter or digit replaced by `_`, and a `_` ahead of a leading digit.
    public static func defaultModuleName(forTarget name: String) -> String {
        let identifier = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return identifier.first?.isNumber == true ? "_" + identifier : identifier
    }

    public func identifyFiles() throws {
        guard !identifiedFiles else { return }

        // A synchronized folder contributes compiled sources only to the targets that own it; resources
        // keep the project-wide behavior.
        try identifyFiles(in: project.fileSystemSynchronizedFiles(), kinds: ProjectFileKind.allCases.filter { !Self.compiledSourceKinds.contains($0) })
        try identifyFiles(in: synchronizedSourceFiles(), kinds: Array(Self.compiledSourceKinds))

        let sourcesBuildPhases = project.xcodeProject.pbxproj.sourcesBuildPhases
        let resourcesBuildPhases = project.xcodeProject.pbxproj.resourcesBuildPhases

        try identifyFiles(kind: .xcDataModel, in: sourcesBuildPhases)
        try identifyFiles(kind: .xcMappingModel, in: sourcesBuildPhases)
        try identifyFiles(kind: .swiftSource, in: sourcesBuildPhases)
        try identifyFiles(kind: .clangSource, in: sourcesBuildPhases)
        try identifyFiles(kind: .interfaceBuilder, in: resourcesBuildPhases)
        try identifyInfoPlistFiles()
        identifiedFiles = true
    }

    public func files(kind: ProjectFileKind) -> Set<FilePath> {
        files[kind, default: []]
    }

    // MARK: - Private

    private static let compiledSourceKinds: Set<ProjectFileKind> = [.swiftSource, .clangSource]

    private func identifyFiles(kind: ProjectFileKind, in buildPhases: [PBXBuildPhase]) throws {
        let targetPhases = buildPhases.filter { target.buildPhases.contains($0) }
        let sourceRoot = project.sourceRoot.lexicallyNormalized()

        let foundFiles = try targetPhases.flatMapSet {
            try ($0.files ?? []).compactMapSet {
                if let stringPath = try $0.file?.fullPath(sourceRoot: sourceRoot.string) {
                    let path = FilePath(stringPath)
                    if let ext = path.extension, kind.extensions.contains(ext.lowercased()) {
                        return path
                    }
                }

                return nil
            }
        }
        files[kind, default: []].formUnion(foundFiles)
    }

    private func identifyFiles(in paths: Set<FilePath>, kinds: [ProjectFileKind]) throws {
        for path in paths {
            for kind in kinds {
                if let ext = path.extension, kind.extensions.contains(ext.lowercased()) {
                    files[kind, default: []].insert(path)
                }
            }
        }
    }

    /// The files of the synchronized folders this target owns, less the files its membership exceptions
    /// leave out. A folder another target owns compiles nothing into this one.
    private func synchronizedSourceFiles() throws -> Set<FilePath> {
        let root = project.sourceRoot.lexicallyNormalized()
        var result: Set<FilePath> = []

        for group in target.fileSystemSynchronizedGroups ?? [] {
            guard let groupPath = try group.fullPath(sourceRoot: root.string) else { continue }

            let groupRoot = FilePath(groupPath)
            let excluded = (group.exceptions ?? [])
                .compactMap { $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet }
                .filter { $0.target === target }
                .flatMap { $0.membershipExceptions ?? [] }
                .mapSet { groupRoot.appending($0).lexicallyNormalized() }
            let files = FilePath.glob(groupRoot.appending("**/*").string)
            result.formUnion(files.filter { !excluded.contains($0.lexicallyNormalized()) })
        }

        return result
    }

    private func identifyInfoPlistFiles() throws {
        let plistFiles = target.buildConfigurationList?.buildConfigurations.flatMap {
            if let setting = $0.buildSettings["INFOPLIST_FILE"] {
                switch setting {
                case let .string(value):
                    return [value]
                case let .array(values):
                    return values
                }
            }

            return []
        } ?? []
        files[.infoPlist] = plistFiles.mapSet { parseInfoPlistSetting($0) }
    }

    private func parseInfoPlistSetting(_ setting: String) -> FilePath {
        var setting = setting.replacingOccurrences(of: "$(SRCROOT)", with: "")

        if setting.hasPrefix("/") {
            setting.removeFirst()
        }

        return project.sourceRoot.lexicallyNormalized().appending(setting)
    }
}

extension XcodeTarget: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(target.name)
    }
}

extension XcodeTarget: Equatable {
    public static func == (lhs: XcodeTarget, rhs: XcodeTarget) -> Bool {
        lhs.name == rhs.name
    }
}
