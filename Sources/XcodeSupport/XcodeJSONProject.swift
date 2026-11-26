import Foundation
import Shared
import SystemPackage
import XcodeProj

/// Reads a project stored in Xcode 27.2's JSON project format, `project.xcproj`, into the object graph XcodeProj
/// reads from `project.pbxproj`, so the rest of Lethen sees a converted project exactly as it saw the original: the
/// same targets and product types, file memberships, synchronized folders and their exceptions, build phases, Run
/// Script paths, local packages and per-configuration build settings.
///
/// The format is the one Apple's `apple/xcode-project-format` package models. Only what Lethen reads is carried
/// over: header roles, compiler flags, platform filters, package products, build rules and script bodies are not.
enum XcodeJSONProject {
    static let fileName = "project.xcproj"

    static func read(bundle: FilePath) throws -> XcodeProj {
        let file = bundle.appending(fileName)
        let data: Data
        do {
            data = try Data(contentsOf: file.url)
        } catch {
            throw LethenError.underlyingError(error)
        }

        do {
            // The format allows a trailing comma after the last element of an array or object, which JSON5 accepts.
            let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            let builder = Builder()
            try builder.build(project: Object(root, at: "project"))
            return XcodeProj(workspace: XCWorkspace(), pbxproj: builder.pbxproj)
        } catch let error as FormatError {
            throw LethenError.usageError("Cannot read \(file): \(error.message)")
        } catch let error as LethenError {
            throw error
        } catch {
            throw LethenError.usageError("Cannot read \(file): \(error.localizedDescription)")
        }
    }
}

private struct FormatError: Error {
    let message: String
}

/// A JSON object, with the path to it for error messages.
private struct Object {
    let values: [String: Any]
    let location: String

    init(_ value: Any, at location: String) throws {
        guard let values = value as? [String: Any] else { throw FormatError(message: "\(location) is not an object") }

        self.values = values
        self.location = location
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let string = value as? String else { throw FormatError(message: "\(location).\(key) is not a string") }

        return string
    }

    func requiredString(_ key: String) throws -> String {
        guard let string = try string(key) else { throw FormatError(message: "\(location) has no \(key)") }

        return string
    }

    func bool(_ key: String) -> Bool? {
        values[key] as? Bool
    }

    func array(_ key: String) throws -> [Any] {
        guard let value = values[key] else { return [] }
        guard let array = value as? [Any] else { throw FormatError(message: "\(location).\(key) is not an array") }

        return array
    }

    func strings(_ key: String) throws -> [String] {
        try array(key).enumerated().map { index, value in
            guard let string = value as? String else { throw FormatError(message: "\(location).\(key)[\(index)] is not a string") }

            return string
        }
    }

    func objects(_ key: String) throws -> [Object] {
        try array(key).enumerated().map { index, value in try Object(value, at: "\(location).\(key)[\(index)]") }
    }

    func object(_ key: String) throws -> Object? {
        guard let value = values[key] else { return nil }

        return try Object(value, at: "\(location).\(key)")
    }
}

/// A name path through the file tree or to a build phase: `a/b/c`, an array of names, or `id:` and an object ID.
private enum Reference {
    case id(String)
    case names([String])

    init(_ value: Any, at location: String) throws {
        if let string = value as? String {
            if string.hasPrefix("id:") {
                self = .id(String(string.dropFirst(3)))
            } else {
                self = .names(string.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            }
        } else if let components = value as? [Any] {
            // A component that cannot be written in the string form, such as one with a `/`, is an object with a name.
            self = try .names(components.enumerated().map { index, component in
                if let name = component as? String { return name }

                return try Object(component, at: "\(location)[\(index)]").requiredString("name")
            })
        } else {
            throw FormatError(message: "\(location) is not a reference")
        }
    }
}

/// An element of the file tree as the format names it, which name paths walk.
private final class Node {
    let name: String
    let element: PBXFileElement
    var children: [Node] = []

    init(name: String, element: PBXFileElement) {
        self.name = name
        self.element = element
    }
}

private final class Builder {
    let pbxproj = PBXProj()

    private var configurationNames: [String] = []
    private var topLevelNodes: [Node] = []
    private var elementsByID: [String: PBXFileElement] = [:]
    private var targetsByName: [String: PBXTarget] = [:]
    private var phasesByID: [String: PBXBuildPhase] = [:]
    private var phasesByTarget: [String: [(kind: String, name: String?, phase: PBXBuildPhase)]] = [:]
    /// The files of each build phase, in the order the file tree lists them.
    private var buildFiles: [ObjectIdentifier: (phase: PBXBuildPhase, files: [PBXBuildFile])] = [:]
    private var memberships: [(element: PBXFileElement, entry: Any, location: String)] = []
    private var folders: [(folder: PBXFileSystemSynchronizedRootGroup, object: Object)] = []

    private func add<T: PBXObject>(_ object: T) -> T {
        pbxproj.add(object: object)
        return object
    }

    func build(project: Object) throws {
        let unsupported = try project.strings("required-capabilities")
        if !unsupported.isEmpty {
            throw FormatError(message: "the project requires capabilities Lethen does not know: \(unsupported.joined(separator: ", "))")
        }

        configurationNames = try project.array("configurations").enumerated().map { index, value in
            if let name = value as? String { return name }

            return try Object(value, at: "project.configurations[\(index)]").requiredString("name")
        }

        guard project.values["files"] is [Any] else { throw FormatError(message: "the project has no files") }

        let mainGroup = add(PBXGroup(children: [], sourceTree: .group))
        topLevelNodes = try project.objects("files").map { try node(for: $0, parent: mainGroup, inVariantGroup: false) }
        mainGroup.children = topLevelNodes.map(\.element)

        let targetObjects = try project.objects("targets")
        // Every target exists before any dependency names one.
        let targets = try targetObjects.map { try target(for: $0) }
        for (target, object) in zip(targets, targetObjects) {
            target.dependencies = try object.array("dependencies").enumerated().compactMap { index, entry in
                try dependency(entry, at: "\(object.location).dependencies[\(index)]")
            }
        }

        for membership in memberships {
            try addMembership(of: membership.element, entry: membership.entry, at: membership.location)
        }
        for (phase, files) in buildFiles.values {
            phase.files = files
        }
        for (folder, object) in folders {
            try configure(folder, from: object)
        }

        let productsGroup = try project.values["products-group"].map { try element(for: Reference($0, at: "project.products-group")) }
            ?? topLevelNodes.first { $0.name == "Products" }?.element
        let projectConfigurations = try configurationList(settings: project.object("build-settings"))
        let root = add(PBXProject(
            name: "",
            buildConfigurationList: projectConfigurations,
            compatibilityVersion: nil,
            preferredProjectObjectVersion: nil,
            minimizedProjectReferenceProxies: nil,
            mainGroup: mainGroup,
            productsGroup: productsGroup as? PBXGroup,
            targets: targets
        ))
        root.localPackages = try project.objects("packages").compactMap { package in
            guard try package.string("kind") == "local" else { return nil }

            return try add(XCLocalSwiftPackageReference(relativePath: package.requiredString("path")))
        }
        pbxproj.rootObject = root
    }

    // MARK: - File tree

    private func node(for object: Object, parent: PBXFileElement, inVariantGroup: Bool) throws -> Node {
        let (sourceTree, path) = try Self.location(object.string("path") ?? "", at: object.location)
        let defaultName = path.map { ($0 as NSString).lastPathComponent }
        let explicitName = try object.string("name")
        let kind = try object.string("kind") ?? "file-reference"
        let element: PBXFileElement
        var childObjects: [Object] = []

        switch kind {
        case "file-reference":
            // Inside a variant group a file is one localization, which the project names by its language.
            let language = inVariantGroup ? path.flatMap(Self.language(inLocalizedPath:)) : nil
            element = try add(PBXFileReference(
                sourceTree: sourceTree,
                name: language,
                explicitFileType: object.string("type"),
                path: path,
                includeInIndex: object.bool("index")
            ))
        case "group":
            element = add(PBXGroup(sourceTree: sourceTree, name: explicitName, path: path))
            childObjects = try object.objects("children")
        case "variant-group":
            element = add(PBXVariantGroup(sourceTree: sourceTree, name: explicitName, path: path))
            childObjects = try object.objects("children")
        case "version-group":
            element = try add(XCVersionGroup(path: path, name: explicitName, sourceTree: sourceTree, versionGroupType: object.string("type")))
            childObjects = try object.objects("children")
        case "folder":
            let folder = add(PBXFileSystemSynchronizedRootGroup(sourceTree: sourceTree, path: path, name: explicitName))
            folders.append((folder, object))
            element = folder
        default:
            throw FormatError(message: "\(object.location) has an unknown kind \(kind)")
        }

        element.parent = parent
        if let id = try object.string("id") {
            elementsByID[id] = element
        }
        for (index, entry) in try object.array("target-membership").enumerated() where kind != "folder" {
            memberships.append((element, entry, "\(object.location).target-membership[\(index)]"))
        }

        let node = Node(name: explicitName ?? defaultName ?? "", element: element)
        node.children = try childObjects.map { try self.node(for: $0, parent: element, inVariantGroup: kind == "variant-group") }
        let children = node.children.map(\.element)
        if let group = element as? PBXGroup {
            group.children = children
        }
        if let versionGroup = element as? XCVersionGroup, let current = try object.string("current-version") {
            versionGroup.currentVersion = node.children.first { $0.name == current }?.element as? PBXFileReference
        }
        return node
    }

    /// The source tree and path of a path in the format: relative to the group, `<PROJECT>/`, `<PRODUCTS>/`,
    /// `<DEVELOPER>/` or `<SDK>/`, `<USER:SETTING>/`, or absolute.
    private static func location(_ text: String, at location: String) throws -> (PBXSourceTree, String?) {
        if text.isEmpty { return (.group, nil) }

        if text.hasPrefix("<USER:") {
            var setting = ""
            var index = text.index(text.startIndex, offsetBy: 6)
            while index < text.endIndex, text[index] != ">" {
                if text[index] == "\\" { index = text.index(after: index) }
                guard index < text.endIndex else { break }

                setting.append(text[index])
                index = text.index(after: index)
            }
            let rest = index < text.endIndex ? text[text.index(after: index)...] : ""
            guard rest.hasPrefix("/") else { throw FormatError(message: "\(location) has an invalid path \(text)") }

            return (.custom(setting), String(rest.dropFirst()))
        }

        if text.hasPrefix("<") {
            guard let end = text.range(of: ">/") else { throw FormatError(message: "\(location) has an invalid path \(text)") }

            let base = text[text.index(after: text.startIndex) ..< end.lowerBound]
            let path = String(text[end.upperBound...])
            switch base {
            case "PROJECT": return (.sourceRoot, path)
            case "PRODUCTS": return (.buildProductsDir, path)
            case "DEVELOPER": return (.developerDir, path)
            case "SDK": return (.sdkRoot, path)
            default: throw FormatError(message: "\(location) has an unknown path base \(base)")
            }
        }

        if text.hasPrefix("/") || text.hasPrefix("~") { return (.absolute, text) }

        return (.group, unescaped(text))
    }

    /// A relative path escapes `<` and `\` with a backslash.
    private static func unescaped(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        var result = ""
        var escaping = false
        for character in text {
            if !escaping, character == "\\" {
                escaping = true
            } else {
                result.append(character)
                escaping = false
            }
        }
        return result
    }

    private static func language(inLocalizedPath path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
    }

    private func element(for reference: Reference) throws -> PBXFileElement {
        switch reference {
        case let .id(id):
            guard let element = elementsByID[id] else { throw FormatError(message: "no file has the ID \(id)") }

            return element
        case let .names(names):
            var candidates = topLevelNodes
            var found: Node?
            for name in names {
                let matches = candidates.filter { $0.name == name }
                guard matches.count == 1, let match = matches.first else {
                    throw FormatError(message: "the file path \(names.joined(separator: "/")) does not name exactly one file")
                }

                found = match
                candidates = match.children
            }
            guard let found else { throw FormatError(message: "an empty file path") }

            return found.element
        }
    }

    // MARK: - Targets

    private func target(for object: Object) throws -> PBXTarget {
        let name = try object.requiredString("name")
        let kind = try object.string("kind") ?? "native"
        let productType = try object.string("product-type").map { "com.apple.product-type.\($0)" } ?? object.string("full-product-type")
        let product = try object.values["product"].map { try element(for: Reference($0, at: "\(object.location).product")) }
        let configurations = try configurationList(settings: object.object("build-settings"))

        let target: PBXTarget
        switch kind {
        case "native":
            target = add(PBXNativeTarget(
                name: name,
                buildConfigurationList: configurations,
                productName: name,
                product: product as? PBXFileReference,
                productType: productType.flatMap(PBXProductType.init(rawValue:))
            ))
        case "aggregate":
            target = add(PBXAggregateTarget(name: name, buildConfigurationList: configurations, productName: name))
        case "external-build-system":
            target = try add(PBXLegacyTarget(name: name, buildToolPath: object.string("build-tool-path"), buildConfigurationList: configurations))
        default:
            throw FormatError(message: "\(object.location) has an unknown kind \(kind)")
        }
        guard targetsByName.updateValue(target, forKey: name) == nil else {
            throw FormatError(message: "two targets are named \(name)")
        }

        target.buildPhases = try object.array("build-phases").enumerated().map { index, entry in
            try buildPhase(entry, of: name, at: "\(object.location).build-phases[\(index)]")
        }
        return target
    }

    private func buildPhase(_ entry: Any, of targetName: String, at location: String) throws -> PBXBuildPhase {
        let object = entry is String ? nil : try Object(entry, at: location)
        guard let kind = try (entry as? String) ?? object?.requiredString("kind") else {
            throw FormatError(message: "\(location) is not a build phase")
        }

        let name = try object?.string("name")
        let phase: PBXBuildPhase
        switch kind {
        case "compile-sources": phase = add(PBXSourcesBuildPhase())
        case "resources": phase = add(PBXResourcesBuildPhase())
        case "frameworks": phase = add(PBXFrameworksBuildPhase())
        case "headers": phase = add(PBXHeadersBuildPhase())
        case "rez": phase = add(PBXRezBuildPhase())
        case "copy", "java-archive", "apple-script": phase = add(PBXCopyFilesBuildPhase(name: name))
        case "script":
            let script = try object.map { object in
                try add(PBXShellScriptBuildPhase(
                    name: name,
                    inputPaths: object.strings("input-paths"),
                    outputPaths: object.strings("output-paths"),
                    inputFileListPaths: object.strings("input-file-list-paths"),
                    outputFileListPaths: object.strings("output-file-list-paths"),
                    shellPath: object.string("shell") ?? "/bin/sh",
                    alwaysOutOfDate: object.bool("run-on-every-build") ?? false
                ))
            }
            guard let script else { throw FormatError(message: "\(location) is a script phase with no script") }

            phase = script
        default:
            throw FormatError(message: "\(location) has an unknown kind \(kind)")
        }

        if let id = try object?.string("id") {
            phasesByID[id] = phase
        }
        phasesByTarget[targetName, default: []].append((kind, name, phase))
        return phase
    }

    private func dependency(_ entry: Any, at location: String) throws -> PBXTargetDependency? {
        if let name = entry as? String {
            return try add(PBXTargetDependency(target: localTarget(named: name, at: location)))
        }

        let object = try Object(entry, at: location)
        switch try object.string("kind") ?? "localTarget" {
        case "localTarget":
            return try add(PBXTargetDependency(target: localTarget(named: object.requiredString("target"), at: location)))
        case "remoteTarget":
            // A target of another project: the proxy names it and points at the project's file reference.
            let name = try object.requiredString("target")
            guard let projectValue = object.values["project"],
                  let project = try element(for: Reference(projectValue, at: "\(location).project")) as? PBXFileReference
            else { throw FormatError(message: "\(location) names no project") }

            let proxy = try add(PBXContainerItemProxy(
                containerPortal: .fileReference(project),
                remoteGlobalID: .string(object.requiredString("target-id")),
                proxyType: .nativeTarget,
                remoteInfo: name
            ))
            return add(PBXTargetDependency(name: name, targetProxy: proxy))
        default:
            // A package product is no target, and Lethen reads none from the property list either.
            return nil
        }
    }

    private func localTarget(named name: String, at location: String) throws -> PBXTarget {
        guard let target = targetsByName[name] else { throw FormatError(message: "\(location) names no target of the project: \(name)") }

        return target
    }

    // MARK: - Membership

    /// A file's membership in a build phase: `Target/kind` or `Target/kind/name`, `id:` and the phase's ID, or an
    /// object whose `build-phase` is one of those.
    private func addMembership(of element: PBXFileElement, entry: Any, at location: String) throws {
        let phaseValue: Any? = entry is String || entry is [Any] ? entry : try Object(entry, at: location).values["build-phase"]
        guard let phaseValue else { throw FormatError(message: "\(location) names no build phase") }

        let phase: PBXBuildPhase
        switch try Reference(phaseValue, at: location) {
        case let .id(id):
            guard let found = phasesByID[id] else { throw FormatError(message: "\(location) names no build phase with the ID \(id)") }

            phase = found
        case let .names(names):
            guard (2 ... 3).contains(names.count) else { throw FormatError(message: "\(location) is not a build phase reference") }

            let kind = names[1]
            let name = names.count == 3 ? names[2] : nil
            let candidates = (phasesByTarget[names[0]] ?? []).filter { $0.kind == kind && (name == nil || $0.name == name) }
            guard let found = candidates.first else {
                throw FormatError(message: "\(location) names no build phase of the project: \(names.joined(separator: "/"))")
            }

            phase = found.phase
        }

        buildFiles[ObjectIdentifier(phase), default: (phase, [])].files.append(add(PBXBuildFile(file: element)))
    }

    /// A folder's targets, and its exception sets: files of the folder that a target owning it leaves out, or that a
    /// target not owning it takes in, which the property list records alike as membership exceptions.
    private func configure(_ folder: PBXFileSystemSynchronizedRootGroup, from object: Object) throws {
        let owners = try object.strings("target-membership")
        for name in owners {
            let target = try localTarget(named: name, at: "\(object.location).target-membership")
            target.fileSystemSynchronizedGroups = (target.fileSystemSynchronizedGroups ?? []) + [folder]
        }

        folder.exceptions = try object.objects("membership-exceptions").compactMap { exception in
            // A build phase exception set only changes how a member is built, such as a header's visibility.
            guard let name = try exception.string("target") else { return nil }

            let target = try localTarget(named: name, at: "\(exception.location).target")
            let members = try exception.strings("exclusions") + exception.strings("inclusions")
            return add(PBXFileSystemSynchronizedBuildFileExceptionSet(
                target: target,
                membershipExceptions: members,
                publicHeaders: nil,
                privateHeaders: nil,
                additionalCompilerFlagsByRelativePath: nil,
                attributesByRelativePath: nil
            ))
        }
    }

    // MARK: - Build settings

    /// One configuration per project configuration. The format writes a setting that differs between configurations
    /// with a `[config=Name]` condition, which the property list instead puts in that configuration's settings.
    private func configurationList(settings: Object?) throws -> XCConfigurationList {
        let settings = try (settings?.values ?? [:]).mapValues { value -> BuildSetting in
            if let string = value as? String { return .string(string) }
            if let array = value as? [String] { return .array(array) }

            throw FormatError(message: "\(settings?.location ?? "build-settings") has a setting that is neither a string nor an array of strings")
        }
        let configurations = configurationNames.map { name in
            add(XCBuildConfiguration(name: name, buildSettings: Self.settings(settings, for: name)))
        }
        return add(XCConfigurationList(buildConfigurations: configurations))
    }

    private static func settings(_ settings: [String: BuildSetting], for configuration: String) -> BuildSettings {
        var unconditional: BuildSettings = [:]
        var specific: BuildSettings = [:]
        for (key, value) in settings {
            guard let range = key.range(of: "[config=") else {
                unconditional[key] = value
                continue
            }
            guard let end = key[range.upperBound...].firstIndex(of: "]") else {
                unconditional[key] = value
                continue
            }
            guard key[range.upperBound ..< end] == configuration else { continue }

            var stripped = key
            stripped.removeSubrange(range.lowerBound ... end)
            specific[stripped] = value
        }
        return unconditional.merging(specific) { _, specific in specific }
    }
}
