import Configuration
import Foundation
import Logger
import Shared
import SystemPackage
import XcodeProj

public final class XcodeWorkspace: XcodeProjectlike {
    public let type: String = "workspace"
    public let path: FilePath
    public let sourceRoot: FilePath

    private let xcodebuild: Xcodebuild
    private let configuration: Configuration
    private let xcworkspace: XCWorkspace
    private var projects: [XcodeProject] = []
    /// Where each project the workspace lists is, including one that was missing when it loaded.
    private var declaredProjectPaths: [FilePath] = []

    public private(set) var targets: Set<XcodeTarget> = []
    public private(set) var buildConfigurationNames: Set<String> = []

    public required init(path: FilePath, xcodebuild: Xcodebuild, configuration: Configuration, logger: Logger, shell: Shell) throws {
        logger.contextualized(with: "xcode:workspace").debug("Loading \(path)")

        self.path = path
        self.xcodebuild = xcodebuild
        self.configuration = configuration
        sourceRoot = self.path.removingLastComponent()

        do {
            xcworkspace = try XCWorkspace(pathString: self.path.string)
        } catch {
            throw LethenError.underlyingError(error)
        }

        let projectPaths = collectProjectPaths(in: xcworkspace.data.children)
        declaredProjectPaths = projectPaths.map { sourceRoot.pushing($0) }
        var loadedProjectPaths: Set<FilePath> = []
        projects = try declaredProjectPaths.compactMap {
            try XcodeProject(path: $0, loadedProjectPaths: &loadedProjectPaths, referencedBy: self.path, shell: shell, logger: logger)
        }

        targets = projects.reduce(into: .init()) { result, project in
            result.formUnion(project.targets)
        }
        buildConfigurationNames = projects.flatMapSet { $0.buildConfigurationNames }
    }

    /// The roots of the projects the workspace lists. A listed project that no longer exists keeps its directory
    /// here, so its removal counts as a change.
    public var projectSourceRoots: [FilePath] {
        declaredProjectPaths.map { $0.removingLastComponent() } + projects.flatMap(\.projectSourceRoots)
    }

    public var declaredInputFiles: Set<FilePath> {
        projects.flatMapSet(\.declaredInputFiles)
    }

    public var hasUnenumerableBuildInputs: Bool {
        projects.contains(where: \.hasUnenumerableBuildInputs)
    }

    public func schemes(additionalArguments: [String]) throws -> Set<String> {
        try xcodebuild.schemes(project: self, additionalArguments: additionalArguments)
    }

    /// Workspace schemes come first, then those of each project in the order the workspace lists them.
    public func schemeConfigurations(named scheme: String) -> XcodeSchemeConfigurations? {
        XcodeSchemeConfigurations.read(scheme: scheme, in: [path] + projects.flatMap(\.schemeContainerPaths))
    }

    /// The workspace's own and those of each project it lists, as `xcodebuild -list -workspace` lists.
    public var sharedSchemes: [String] {
        XcodeSharedSchemes.names(in: [path] + projects.map(\.path))
    }

    // MARK: - Private

    private func collectProjectPaths(in elements: [XCWorkspaceDataElement], groups: [XCWorkspaceDataGroup] = []) -> [FilePath] {
        var paths: [FilePath] = []

        for child in elements {
            switch child {
            case let .file(ref):
                let basePath = FilePath(groups.map(\.location.path).filter { !$0.isEmpty }.joined(separator: "/"))
                let path = FilePath(ref.location.path)
                let fullPath = basePath.pushing(path)

                if fullPath.extension == "xcodeproj", shouldLoadProject(fullPath) {
                    paths.append(fullPath)
                }
            case let .group(group):
                paths += collectProjectPaths(in: group.children, groups: groups + [group])
            }
        }

        return paths
    }

    private func shouldLoadProject(_ path: FilePath) -> Bool {
        if configuration.guidedSetup, path.string.contains("Pods.xcodeproj") {
            return false
        }

        return true
    }
}
