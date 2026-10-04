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

    /// The project's name, its `.xcodeproj` without the extension, which `qualifiedName` and the target options use
    /// to tell same-named targets of a workspace's projects apart.
    public var projectName: String {
        project.name
    }

    /// The path of the target's project, which with the name identifies the target.
    public var projectPath: FilePath {
        project.path.lexicallyNormalized()
    }

    /// The target as `Project/Target`, which names it among same-named targets of other projects.
    public var qualifiedName: String {
        "\(projectName)/\(name)"
    }

    /// The target as `path/Project.xcodeproj/Target`, for the targets of same-named projects in different folders,
    /// which `qualifiedName` does not tell apart.
    public var pathQualifiedName: String {
        "\(projectPath.string)/\(name)"
    }

    /// Whether an option such as `--exclude-targets` names this target: by its own name, which every target of that
    /// name matches, or by `qualifiedName` or `pathQualifiedName`, which narrow it to one project.
    public func isNamed(by option: String) -> Bool {
        option == name || isNamedByQualifiedName(option)
    }

    /// Whether the option is one of this target's qualified names rather than its plain name.
    public func isNamedByQualifiedName(_ option: String) -> Bool {
        option == qualifiedName || option == pathQualifiedName
    }

    /// A target this one depends on: its name, and the project it is in when a proxy says so, by name and by the
    /// path its file reference resolves to; both are `nil` for a target of this project.
    public struct Dependency: Hashable {
        public let name: String
        public let projectName: String?
        public let projectPath: FilePath?
    }

    /// The targets this one depends on: the explicit dependencies, which Xcode builds before it (a dependency on a
    /// target of another project of the workspace is a proxy whose `remoteInfo` is that target's name and whose
    /// container is that project), and the targets of this project whose product it links, which Xcode treats as
    /// implicit dependencies.
    public var dependencies: Set<Dependency> {
        let explicit = target.dependencies.compactMapSet { dependency -> Dependency? in
            if let target = dependency.target { return Dependency(name: target.name, projectName: nil, projectPath: nil) }
            guard let proxy = dependency.targetProxy, let name = proxy.remoteInfo else { return nil }

            // A proxy to the project itself, or to one Lethen cannot tell, names a target of this project.
            guard case let .fileReference(reference) = proxy.containerPortal else {
                return Dependency(name: name, projectName: nil, projectPath: nil)
            }

            let resolved = (try? reference.fullPath(sourceRoot: project.sourceRoot.string)).flatMap(\.self).map { FilePath($0).lexicallyNormalized() }
            let projectName = resolved?.stem ?? (reference.path ?? reference.name).map { FilePath($0).stem ?? $0 }
            if resolved == project.path.lexicallyNormalized() { return Dependency(name: name, projectName: nil, projectPath: nil) }

            return Dependency(name: name, projectName: projectName, projectPath: resolved)
        }
        let linkedFiles = target.buildPhases.compactMap { $0 as? PBXFrameworksBuildPhase }
            .flatMap { $0.files ?? [] }
            .compactMap(\.file)
        let linked = project.xcodeProject.pbxproj.nativeTargets
            .filter { candidate in candidate !== target && linkedFiles.contains { $0 === candidate.product } }
            .map { Dependency(name: $0.name, projectName: nil, projectPath: nil) }
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

        // A synchronized folder contributes every kind of file, sources and resources alike, only to the targets
        // that own it.
        try identifyFiles(in: synchronizedFiles(), kinds: ProjectFileKind.allCases)

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
    /// leave out. A folder another target owns contributes nothing to this one, and neither does one no target owns.
    private func synchronizedFiles() throws -> Set<FilePath> {
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
            // An exception names a file or a folder, which takes everything below it along.
            result.formUnion(files.filter { file in
                let path = file.lexicallyNormalized()
                return !excluded.contains { path.starts(with: $0) }
            })
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
        files[.infoPlist, default: []].formUnion(plistFiles.mapSet { parseInfoPlistSetting($0) })
    }

    private func parseInfoPlistSetting(_ setting: String) -> FilePath {
        var setting = setting.replacingOccurrences(of: "$(SRCROOT)", with: "")

        if setting.hasPrefix("/") {
            setting.removeFirst()
        }

        return project.sourceRoot.lexicallyNormalized().appending(setting)
    }
}

/// A target is identified by its project and its name, since two projects of a workspace can define targets of the
/// same name.
extension XcodeTarget: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(project.path.lexicallyNormalized().string)
        hasher.combine(target.name)
    }
}

extension XcodeTarget: Equatable {
    public static func == (lhs: XcodeTarget, rhs: XcodeTarget) -> Bool {
        lhs.target.name == rhs.target.name && lhs.project.path.lexicallyNormalized() == rhs.project.path.lexicallyNormalized()
    }
}
