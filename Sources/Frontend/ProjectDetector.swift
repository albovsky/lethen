import Foundation
import Shared
import SystemPackage

/// Finds the project in a directory when no option names one.
///
/// A `Package.swift` wins. Otherwise the Xcode workspaces and projects directly inside the directory are
/// considered, never nested ones, so example projects and `Pods/Pods.xcodeproj` are not picked. A single
/// candidate is used, and a single workspace is preferred over the projects it references. A `MODULE.bazel`
/// selects Bazel. Anything ambiguous is a usage error that lists the options to pass.
struct ProjectDetector {
    enum Detection: Equatable {
        case spm
        case xcode(FilePath)
        case bazel
    }

    let directory: FilePath

    func detect() throws -> Detection? {
        if directory.appending("Package.swift").exists {
            return .spm
        }

        let xcodePaths = try xcodeCandidates()
        let hasBazelModule = directory.appending("MODULE.bazel").exists

        if hasBazelModule, !xcodePaths.isEmpty {
            throw ambiguity(
                "Found both a Bazel module and an Xcode project in the current directory. Pass one of:",
                options: ["--bazel"] + xcodePaths.map(projectOption)
            )
        }

        if xcodePaths.count == 1, let path = xcodePaths.first {
            return .xcode(path)
        }

        if xcodePaths.count > 1 {
            throw ambiguity(
                "Found several Xcode projects in the current directory. Pass one of:",
                options: xcodePaths.map(projectOption)
            )
        }

        return hasBazelModule ? .bazel : nil
    }

    // MARK: - Private

    /// The workspaces and projects to choose between, sorted. A lone workspace absorbs the projects it references.
    private func xcodeCandidates() throws -> [FilePath] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.string)
            .filter { !$0.hasPrefix(".") && $0 != "Pods.xcodeproj" }
            .filter { isDirectory(directory.appending($0)) }
            .sorted()
        let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }.map { directory.appending($0) }
        var projects = names.filter { $0.hasSuffix(".xcodeproj") }.map { directory.appending($0) }

        if workspaces.count == 1, let workspace = workspaces.first {
            let referenced = Self.referencedProjectPaths(inWorkspace: workspace)
            projects.removeAll { referenced.contains($0.lexicallyNormalized()) }
        }

        return workspaces + projects
    }

    private func isDirectory(_ path: FilePath) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func projectOption(_ path: FilePath) -> String {
        let name = path.lastComponent?.string ?? path.string
        let needsQuotes = name.contains { $0 == " " || $0 == "'" || $0 == "\"" }
        return needsQuotes ? "--project \"\(name.withEscapedQuotes)\"" : "--project \(name)"
    }

    private func ambiguity(_ message: String, options: [String]) -> LethenError {
        .usageError(([message] + options.map { "  \($0)" }).joined(separator: "\n"))
    }

    /// The absolute, normalized paths of the projects a workspace's `contents.xcworkspacedata` references,
    /// resolving `group:` locations against their enclosing groups.
    static func referencedProjectPaths(inWorkspace workspace: FilePath) -> Set<FilePath> {
        let contentsPath = workspace.appending("contents.xcworkspacedata")
        guard let contents = try? String(contentsOfFile: contentsPath.string, encoding: .utf8) else { return [] }

        return referencedProjectPaths(inWorkspaceContents: contents, sourceRoot: workspace.removingLastComponent())
    }

    static func referencedProjectPaths(inWorkspaceContents contents: String, sourceRoot: FilePath) -> Set<FilePath> {
        let element = #/<(?<closing>/?)(?<name>Group|FileRef)\b(?<attributes>[^>]*?)(?<selfClosing>/?)>/#
        let location = #/\blocation\s*=\s*"(?<type>[a-z]+):(?<path>[^"]*)"/#

        var groupPaths: [FilePath] = [sourceRoot]
        var paths: Set<FilePath> = []

        for match in contents.matches(of: element) {
            let isGroup = match.name == "Group"

            if !match.closing.isEmpty {
                if isGroup, groupPaths.count > 1 {
                    groupPaths.removeLast()
                }
                continue
            }

            let parent = groupPaths.last ?? sourceRoot
            var resolved: FilePath?

            if let attribute = match.attributes.firstMatch(of: location) {
                let path = unescapingXML(String(attribute.path))

                switch attribute.type {
                case "group":
                    resolved = parent.pushing(FilePath(path))
                case "container":
                    resolved = sourceRoot.pushing(FilePath(path))
                case "absolute":
                    resolved = FilePath(path)
                default:
                    resolved = nil
                }
            }

            if isGroup {
                if match.selfClosing.isEmpty {
                    groupPaths.append(resolved ?? parent)
                }
            } else if let resolved, resolved.extension == "xcodeproj" {
                paths.insert(resolved.lexicallyNormalized())
            }
        }

        return paths
    }

    private static func unescapingXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
