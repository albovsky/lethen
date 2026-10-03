import Foundation
import Logger
import Shared
import SystemPackage
import XcodeProj

public final class XcodeProject: XcodeProjectlike {
    public let type: String = "project"
    public let path: FilePath
    public let sourceRoot: FilePath
    public let name: String
    public private(set) var targets: Set<XcodeTarget> = []
    public private(set) var buildConfigurationNames: Set<String> = []

    let xcodeProject: XcodeProj

    private let xcodebuild: Xcodebuild
    private var subProjects: [XcodeProject] = []
    /// Every project the project file references, including one that was missing when it loaded.
    private var declaredSubProjectPaths: [FilePath] = []
    private var synchronizedRootGroupFiles: Set<FilePath>?

    /// Every file in the project's file system synchronized groups. Each target reads the same groups,
    /// so the tree is walked once per project rather than once per target.
    func fileSystemSynchronizedFiles() throws -> Set<FilePath> {
        if let synchronizedRootGroupFiles {
            return synchronizedRootGroupFiles
        }

        let root = sourceRoot.lexicallyNormalized()
        let files = try xcodeProject.pbxproj.fileSystemSynchronizedRootGroups.flatMapSet {
            if let stringPath = try $0.fullPath(sourceRoot: root.string) {
                return FilePath.glob(FilePath(stringPath).appending("**/*").string)
            }

            return []
        }
        synchronizedRootGroupFiles = files
        return files
    }

    convenience init?(
        path: FilePath,
        loadedProjectPaths: inout Set<FilePath>,
        referencedBy refPath:
        FilePath,
        shell: Shell,
        logger: Logger
    ) throws {
        if !path.exists {
            logger.warn("No such project exists at '\(path.lexicallyNormalized())', referenced by '\(refPath)'.")
            return nil
        }

        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        try self.init(
            path: path,
            loadedProjectPaths: &loadedProjectPaths,
            xcodebuild: xcodebuild,
            shell: shell,
            logger: logger
        )
    }

    public required init(
        path: FilePath,
        loadedProjectPaths: inout Set<FilePath>,
        xcodebuild: Xcodebuild,
        shell: Shell,
        logger: Logger
    ) throws {
        logger.contextualized(with: "xcode:project").debug("Loading \(path)")

        self.path = path
        self.xcodebuild = xcodebuild
        name = self.path.lastComponent?.stem ?? ""
        sourceRoot = self.path.removingLastComponent()

        do {
            xcodeProject = try XcodeProj(pathString: self.path.lexicallyNormalized().string)
        } catch {
            throw LethenError.underlyingError(error)
        }

        loadedProjectPaths.insert(path)

        // Don't search for sub projects within CocoaPods.
        if !path.components.contains("Pods.xcodeproj") {
            let referenced = try xcodeProject.pbxproj.fileReferences
                .filter { $0.path?.hasSuffix(".xcodeproj") ?? false }
                .compactMap { try $0.fullPath(sourceRoot: sourceRoot.string) }
                .map { FilePath($0) }
            declaredSubProjectPaths = referenced
            subProjects = try referenced
                .compactMap { projectPath in
                    // Prevent infinite loading of circular references.
                    guard !loadedProjectPaths.contains(projectPath) else { return nil }

                    return try XcodeProject(
                        path: projectPath,
                        loadedProjectPaths: &loadedProjectPaths,
                        referencedBy: path,
                        shell: shell,
                        logger: logger
                    )
                }
        }

        targets = xcodeProject.pbxproj.nativeTargets
            .mapSet { XcodeTarget(project: self, target: $0) }
            .union(subProjects.flatMapSet { $0.targets })
        buildConfigurationNames = Set(xcodeProject.pbxproj.rootObject?.buildConfigurationList?.buildConfigurations.map(\.name) ?? [])
            .union(subProjects.flatMapSet { $0.buildConfigurationNames })
    }

    public func schemes(additionalArguments: [String]) throws -> Set<String> {
        try xcodebuild.schemes(project: self, additionalArguments: additionalArguments)
    }

    public func schemeConfigurations(named scheme: String) -> XcodeSchemeConfigurations? {
        XcodeSchemeConfigurations.read(scheme: scheme, in: schemeContainerPaths)
    }

    /// Only this project's, as `xcodebuild -list -project` lists.
    public var sharedSchemes: [String] {
        XcodeSharedSchemes.names(in: [path])
    }

    /// This project's source root, the directories it declares that the walk of that root does not reach, and those
    /// of every project it references, depth first. The declared directories are local Swift packages, folder
    /// references and Run Script inputs, listed through symbolic links. A declared package, folder or project that
    /// no longer exists stays listed, so its removal counts as a change.
    public var projectSourceRoots: [FilePath] {
        [sourceRoot] + declaredDirectories + declaredSubProjectPaths.map { $0.removingLastComponent() }
            + subProjects.flatMap(\.projectSourceRoots)
    }

    /// Every file the project declares as a file reference, such as an `.xcconfig`, or as a Run Script input, in
    /// this project and the ones it references. Each changes what a build compiles, wherever it lives. A file that
    /// no longer exists stays listed, so its removal counts as a change.
    public var declaredInputFiles: Set<FilePath> {
        let root = sourceRoot.lexicallyNormalized()
        let own = Set(declaredReferencePaths.filter { file in
            var isDirectory: ObjCBool = false
            return !(FileManager.default.fileExists(atPath: file.string, isDirectory: &isDirectory) && isDirectory.boolValue)
        })
        let scripts = scriptInputs(root: root).files
        return own.union(scripts).union(subProjects.flatMapSet(\.declaredInputFiles))
    }

    /// Whether a Run Script input of this project or one it references names a path Lethen cannot resolve, such as
    /// one with a build setting other than `SRCROOT` or `PROJECT_DIR`, or an input file list it cannot read, or
    /// whether such a phase is set to run on every build, which no file time can vouch for.
    public var hasUnenumerableBuildInputs: Bool {
        scriptInputs(root: sourceRoot.lexicallyNormalized()).unenumerable
            || xcodeProject.pbxproj.shellScriptBuildPhases.contains(where: \.alwaysOutOfDate)
            || subProjects.contains(where: \.hasUnenumerableBuildInputs)
    }

    /// The path of every file reference that resolves to one, whether or not it exists.
    private var declaredReferencePaths: [FilePath] {
        let root = sourceRoot.lexicallyNormalized()
        return xcodeProject.pbxproj.fileReferences.compactMap { reference in
            (try? reference.fullPath(sourceRoot: root.string)).flatMap(\.self).map { FilePath($0).lexicallyNormalized() }
        }
    }

    /// The local Swift packages, folder references and Run Script input directories that do not lie inside the
    /// source root once symbolic links are resolved. The walk of the root does not follow a link, so a declared
    /// directory reached through one is walked as its target.
    private var declaredDirectories: [FilePath] {
        let root = sourceRoot.lexicallyNormalized()
        let packages = (xcodeProject.pbxproj.rootObject?.localPackages ?? []).map {
            FilePath($0.relativePath).isAbsolute ? FilePath($0.relativePath) : root.appending($0.relativePath)
        }
        let folders = declaredReferencePaths.filter { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.string, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let resolvedRoot = Self.resolvingSymlinks(root)
        return (packages.map { $0.lexicallyNormalized() } + folders + scriptInputs(root: root).directories)
            .map(Self.resolvingSymlinks)
            .filter { !$0.starts(with: resolvedRoot) }
    }

    private static func resolvingSymlinks(_ path: FilePath) -> FilePath {
        FilePath(path.url.resolvingSymlinksInPath().path)
    }

    private func scriptInputs(root: FilePath) -> ScriptInputs {
        var inputs = ScriptInputs()
        for phase in xcodeProject.pbxproj.shellScriptBuildPhases {
            for entry in phase.inputPaths {
                inputs.add(entry, root: root)
            }
            for list in phase.inputFileListPaths ?? [] {
                inputs.addList(list, root: root)
            }
        }
        return inputs
    }

    /// This project followed by every project it references, depth first.
    var schemeContainerPaths: [FilePath] {
        [path] + subProjects.flatMap(\.schemeContainerPaths)
    }
}

extension XcodeProject: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path.lexicallyNormalized().string)
    }
}

extension XcodeProject: Equatable {
    public static func == (lhs: XcodeProject, rhs: XcodeProject) -> Bool {
        lhs.path == rhs.path
    }
}

/// The paths the Run Script phases of one project name as inputs.
private struct ScriptInputs {
    var files: Set<FilePath> = []
    var directories: [FilePath] = []
    /// Set when an input names a path that cannot be resolved or read.
    var unenumerable = false

    mutating func add(_ entry: String, root: FilePath) {
        guard !entry.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let path = Self.resolve(entry, root: root) else {
            unenumerable = true
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory), isDirectory.boolValue {
            directories.append(path)
        } else {
            files.insert(path)
        }
    }

    /// An input file list is an input itself, and each of its lines names one more.
    mutating func addList(_ entry: String, root: FilePath) {
        guard let list = Self.resolve(entry, root: root) else {
            unenumerable = true
            return
        }

        files.insert(list)
        guard let text = try? String(contentsOfFile: list.string, encoding: .utf8) else {
            unenumerable = true
            return
        }

        for line in text.split(whereSeparator: \.isNewline) {
            add(String(line), root: root)
        }
    }

    /// `nil` when a build setting other than the source root's remains.
    private static func resolve(_ entry: String, root: FilePath) -> FilePath? {
        var text = entry.trimmingCharacters(in: .whitespaces)
        for name in ["SRCROOT", "PROJECT_DIR"] {
            text = text.replacingOccurrences(of: "$(\(name))", with: root.string)
                .replacingOccurrences(of: "${\(name)}", with: root.string)
        }
        guard !text.contains("$("), !text.contains("${") else { return nil }

        let path = FilePath(text)
        return (path.isAbsolute ? path : root.appending(text)).lexicallyNormalized()
    }
}
