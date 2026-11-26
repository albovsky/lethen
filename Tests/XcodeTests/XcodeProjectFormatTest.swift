import Foundation
import Logger
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
import XcodeProj
@testable import XcodeSupport
import XCTest

/// Xcode 27.2 can store a project as JSON in `project.xcproj` instead of `project.pbxproj`. Lethen reads it into the
/// same object graph XcodeProj reads from the property list, so a converted project loads as its original did, and a
/// bundle that still has `project.pbxproj` loads from it.
final class XcodeProjectFormatTest: XCTestCase {
    private var root: FilePath!

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-format-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(atPath: root.string)
        }
    }

    func testJSONFileThatIsNoProjectIsAnErrorNamingTheFile() throws {
        let project = root.appending("App.xcodeproj")
        try FileManager.default.createDirectory(atPath: project.string, withIntermediateDirectories: true)
        try "{}\n".write(toFile: project.appending("project.xcproj").string, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try load(project)) { error in
            guard case let LethenError.usageError(message) = error else { return XCTFail("\(error)") }

            XCTAssertTrue(message.contains("App.xcodeproj/project.xcproj"), message)
        }
    }

    func testProjectWithAPropertyListFileLoadsFromIt() throws {
        let project = root.appending("UIKitProject.xcodeproj")
        try FileManager.default.copyItem(atPath: UIKitProjectPath.string, toPath: project.string)
        try "{}\n".write(toFile: project.appending("project.xcproj").string, atomically: true, encoding: .utf8)

        XCTAssertFalse(try load(project).targets.isEmpty)
    }

    /// A hand-written project with the format's trailing commas: files of groups, folders and variant and version
    /// groups reach their targets' build phases, a folder's exclusions leave its owner and its inclusions join another
    /// target, and a `[config=…]` setting lands only in that configuration.
    func testReadsTargetsFilesFoldersAndSettings() throws {
        let directory = root.appending("Fixture")
        let project = directory.appending("App.xcodeproj")
        try FileManager.default.createDirectory(atPath: project.string, withIntermediateDirectories: true)
        let files = [
            "App/Main.swift", "App/Base.lproj/Main.storyboard", "App/Model.xcdatamodeld/Model.xcdatamodel/contents",
            "Folder/Kept.swift", "Folder/Left.swift", "Folder/Shared.swift", "Tests/AppTests.swift",
        ]
        for file in files {
            let path = directory.appending(file)
            try FileManager.default.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
            try "".write(toFile: path.string, atomically: true, encoding: .utf8)
        }
        try """
        {
          "default-configuration": "Release",
          "configurations": [ "Debug", "Release", ],
          "localizations": { "development": "en", "supported": [ "Base", ], },
          "files": [
            {
              "kind": "group",
              "path": "App",
              "children": [
                { "path": "Main.swift", "target-membership": [ "App/compile-sources", ], },
                {
                  "kind": "variant-group",
                  "name": "Main.storyboard",
                  "target-membership": [ { "build-phase": "App/resources", }, ],
                  "children": [ { "path": "Base.lproj/Main.storyboard", }, ],
                },
                {
                  "kind": "version-group",
                  "path": "Model.xcdatamodeld",
                  "current-version": "Model.xcdatamodel",
                  "target-membership": [ "App/compile-sources", ],
                  "children": [ { "path": "Model.xcdatamodel", }, ],
                },
              ],
            },
            {
              "kind": "folder",
              "path": "Folder",
              "target-membership": [ "App", ],
              "membership-exceptions": [
                { "target": "App", "exclusions": [ "Left.swift", ], },
                { "target": "AppTests", "inclusions": [ "Shared.swift", ], },
              ],
            },
            { "kind": "group", "path": "Tests", "children": [ { "path": "AppTests.swift", "target-membership": [ "AppTests/compile-sources", ], }, ], },
            { "kind": "group", "name": "Products", "children": [ { "path": "<PRODUCTS>/App.app", "id": "PRODUCT", }, ], },
          ],
          "targets": [
            {
              "name": "App",
              "id": "APP",
              "product": "Products/App.app",
              "product-type": "application",
              "build-phases": [ "compile-sources", "resources", ],
              "build-settings": {
                "INFOPLIST_FILE": "App/Info.plist",
                "PRODUCT_MODULE_NAME[config=Debug]": "DebugApp",
                "PRODUCT_MODULE_NAME[config=Release]": "ReleaseApp",
              },
            },
            {
              "name": "AppTests",
              "id": "TESTS",
              "product-type": "bundle.unit-test",
              "dependencies": [ "App", ],
              "build-phases": [ "compile-sources", ],
            },
          ],
          "build-settings": { "SDKROOT": "iphoneos", },
        }

        """.write(toFile: project.appending("project.xcproj").string, atomically: true, encoding: .utf8)

        let loaded = try load(project)
        let app = try XCTUnwrap(loaded.targets.first { $0.name == "App" })
        let tests = try XCTUnwrap(loaded.targets.first { $0.name == "AppTests" })
        try app.identifyFiles()
        try tests.identifyFiles()

        XCTAssertEqual(loaded.buildConfigurationNames, ["Debug", "Release"])
        XCTAssertFalse(app.isTestTarget)
        XCTAssertTrue(tests.isTestTarget)
        XCTAssertEqual(app.moduleNames, ["DebugApp", "ReleaseApp"])
        XCTAssertEqual(tests.moduleNames, ["AppTests"])
        XCTAssertEqual(tests.dependencies, [XcodeTarget.Dependency(name: "App", projectName: nil, projectPath: nil)])
        XCTAssertEqual(relative(app.files(kind: .swiftSource), to: directory), ["App/Main.swift", "Folder/Kept.swift", "Folder/Shared.swift"])
        XCTAssertEqual(relative(app.files(kind: .interfaceBuilder), to: directory), ["App/Base.lproj/Main.storyboard"])
        XCTAssertEqual(relative(app.files(kind: .xcDataModel), to: directory), ["App/Model.xcdatamodeld"])
        XCTAssertEqual(relative(app.files(kind: .infoPlist), to: directory), ["App/Info.plist"])
        XCTAssertEqual(relative(tests.files(kind: .swiftSource), to: directory), ["Folder/Shared.swift", "Tests/AppTests.swift"])
    }

    /// Each fixture project converted by Xcode loads exactly as the same project in the property list format does.
    /// That project is Xcode's conversion of the JSON file back, since a conversion drops what Xcode's model does not
    /// keep: Xcode 27.2 drops a folder's membership exceptions that name a subfolder, in either direction.
    func testProjectsConvertedByXcodeLoadAsTheirPropertyListForm() throws {
        let xcodebuild = try xcodebuildConverting()
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        for fixture in [UIKitProjectPath, SwiftUIProjectPath, MixedLanguageProjectPath, ConfigurationsProjectPath] {
            let directory = try XCTUnwrap(fixture.removingLastComponent().lastComponent?.string)
            let name = try XCTUnwrap(fixture.lastComponent?.string)
            let original = root.appending("PropertyList/\(directory)/\(name)")
            let converted = root.appending("JSON/\(directory)/\(name)")
            for copy in [original, converted] {
                try FileManager.default.createDirectory(atPath: copy.removingLastComponent().removingLastComponent().string, withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: fixture.removingLastComponent().string, toPath: copy.removingLastComponent().string)
                try shell.exec(xcodebuild + ["-project", copy.string, "-convert-project", "xcproj"])
            }
            try shell.exec(xcodebuild + ["-project", original.string, "-convert-project", "pbxproj"])
            XCTAssertTrue(converted.appending("project.xcproj").exists, name)
            XCTAssertFalse(converted.appending("project.pbxproj").exists, name)
            XCTAssertTrue(original.appending("project.pbxproj").exists, name)
            XCTAssertFalse(original.appending("project.xcproj").exists, name)

            let expected = try summary(of: load(original), relativeTo: original.removingLastComponent())
            let actual = try summary(of: load(converted), relativeTo: converted.removingLastComponent())
            XCTAssertEqual(actual, expected, name)
        }
    }

    /// A project that references another and depends on one of its targets through a proxy loads both projects, and
    /// that dependency, as the property list form does.
    func testProjectReferencingAnotherLoadsAsItsPropertyListForm() throws {
        let xcodebuild = try xcodebuildConverting()
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let template = root.appending("Template")
        for name in ["App", "Library"] {
            try FileManager.default.createDirectory(atPath: template.string, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: template.appending(name).string)
        }
        let library = try XcodeProj(pathString: template.appending("Library/ConfigurationsProject.xcodeproj").string)
        let remoteTarget = try XCTUnwrap(library.pbxproj.nativeTargets.first { $0.name == "ConfigurationsProject" })
        let appPath = template.appending("App/ConfigurationsProject.xcodeproj")
        let app = try XcodeProj(pathString: appPath.string)
        let pbxproj = app.pbxproj
        let reference = PBXFileReference(sourceTree: .group, name: "Library.xcodeproj", lastKnownFileType: "wrapper.pb-project", path: "../Library/ConfigurationsProject.xcodeproj")
        let products = PBXGroup(children: [], sourceTree: .group, name: "Products")
        let proxy = PBXContainerItemProxy(containerPortal: .fileReference(reference), remoteGlobalID: .string(remoteTarget.uuid), proxyType: .nativeTarget, remoteInfo: "ConfigurationsProject")
        let dependency = PBXTargetDependency(name: "ConfigurationsProject", targetProxy: proxy)
        for object in [reference, products, proxy, dependency] as [PBXObject] {
            pbxproj.add(object: object)
        }
        let rootObject = try XCTUnwrap(pbxproj.rootObject)
        try XCTUnwrap(rootObject.mainGroup).children.append(reference)
        rootObject.projects = [["ProductGroup": products, "ProjectRef": reference]]
        let tests = try XCTUnwrap(pbxproj.nativeTargets.first { $0.name == "ConfigurationsProjectTests" })
        tests.dependencies.append(dependency)
        try app.write(pathString: appPath.string, override: true)

        var summaries: [[String]] = []
        for format in ["pbxproj", "xcproj"] {
            let copy = root.appending(format)
            try FileManager.default.copyItem(atPath: template.string, toPath: copy.string)
            let project = copy.appending("App/ConfigurationsProject.xcodeproj")
            try shell.exec(xcodebuild + ["-project", project.string, "-convert-project", "xcproj"])
            if format == "pbxproj" {
                try shell.exec(xcodebuild + ["-project", project.string, "-convert-project", "pbxproj"])
            }
            XCTAssertTrue(project.appending("project.\(format)").exists, format)
            try summaries.append(summary(of: load(project), relativeTo: copy))
        }

        XCTAssertEqual(summaries[1], summaries[0])
        let remote = "ConfigurationsProject ConfigurationsProject Library/ConfigurationsProject.xcodeproj"
        XCTAssertTrue(summaries[0].contains { $0.hasPrefix("App/ConfigurationsProject.xcodeproj/ConfigurationsProjectTests:") && $0.contains(remote) }, "\(summaries[0])")
    }

    func testScanOfAProjectConvertedByXcodeReportsWhatTheOriginalDoes() throws {
        let xcodebuild = try xcodebuildConverting()
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lethen")
        var results: [String] = []
        for variant in ["Original", "Converted"] {
            let copy = root.appending("\(variant)/Fixture")
            try FileManager.default.createDirectory(atPath: copy.removingLastComponent().string, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: copy.string)
            let project = copy.appending("ConfigurationsProject.xcodeproj")
            if variant == "Converted" {
                try shell.exec(xcodebuild + ["-project", project.string, "-convert-project", "xcproj"])
                XCTAssertFalse(project.appending("project.pbxproj").exists)
            }

            let scan = [
                executable.path, "scan", "--project-root", copy.string, "--project", project.string, "--schemes", "ConfigurationsProject",
                "--format", "csv", "--disable-update-check", "--quiet",
            ]
            let output = try shell.exec(Array(xcodebuild.dropLast()) + scan)
            results.append(output.replacingOccurrences(of: copy.string, with: "<root>"))
        }

        XCTAssertEqual(results[1], results[0])
        XCTAssertTrue(results[0].contains("<root>/"), results[0])
    }

    // MARK: - Private

    /// `env -i … xcodebuild` for an Xcode that converts projects, 27.2 or later, or a skip without one. Set
    /// `LETHEN_XCODE_27_2_DEVELOPER_DIR` to use one that is not the selected Xcode.
    private func xcodebuildConverting() throws -> [String] {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        // Keep the parent XCTest process's framework paths out of the other Xcode's processes.
        let variables = ProcessInfo.processInfo.environment
        let primaryCI = variables["GITHUB_JOB"] == "swift-6-4"
        let developerDir = primaryCI
            ? "/Applications/Xcode_27.2.app/Contents/Developer"
            : variables["LETHEN_XCODE_27_2_DEVELOPER_DIR"] ?? variables["DEVELOPER_DIR"]
        var environment = ["/usr/bin/env", "-i", "HOME=\(NSHomeDirectory())", "TMPDIR=\(NSTemporaryDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let developerDir { environment.append("DEVELOPER_DIR=\(developerDir)") }
        let xcodebuild = environment + ["/usr/bin/xcodebuild"]
        let version = try shell.exec(xcodebuild + ["-version"])
        let number = try XCTUnwrap(version.split(separator: "\n").first?.split(separator: " ").last)
        if String(number).isVersion(lessThan: "27.2") {
            if primaryCI { XCTFail("Expected Xcode 27.2 or later in the primary CI job; found \(version)") }
            throw XCTSkip("Conversion requires Xcode 27.2 or later; found \(version)")
        }
        return xcodebuild
    }

    /// What Lethen reads from a project, with paths relative to `directory`, one line each.
    private func summary(of project: XcodeProject, relativeTo directory: FilePath) throws -> [String] {
        func paths(_ paths: some Sequence<FilePath>) -> String {
            relative(paths, to: directory).joined(separator: ", ")
        }

        var lines = [
            "configurations: \(project.buildConfigurationNames.sorted())",
            "source roots: \(paths(project.projectSourceRoots))",
            "inputs: \(paths(project.declaredInputFiles))",
            "unenumerable inputs: \(project.hasUnenumerableBuildInputs)",
        ]
        // A target is named by its project's path and its name, which same-named targets of two projects share.
        let targets = project.targets.map { (name: "\(paths([$0.projectPath]))/\($0.name)", target: $0) }
        for (name, target) in targets.sorted(by: { $0.name < $1.name }) {
            try target.identifyFiles()
            let dependencies = target.dependencies.map { "\($0.name) \($0.projectName ?? "-") \($0.projectPath.map { paths([$0]) } ?? "-")" }
            lines.append("\(name): test \(target.isTestTarget), modules \(target.moduleNames.sorted()), dependencies \(dependencies.sorted())")
            for kind in ProjectFileKind.allCases {
                lines.append("\(name) \(kind): \(paths(target.files(kind: kind)))")
            }
        }
        return lines
    }

    private func relative(_ paths: some Sequence<FilePath>, to directory: FilePath) -> [String] {
        paths.map { $0.lexicallyNormalized().relativeTo(directory.lexicallyNormalized()).string }.sorted()
    }

    private func load(_ project: FilePath) throws -> XcodeProject {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellMock(output: "")
        var loadedProjectPaths: Set<FilePath> = []
        return try XcodeProject(
            path: project,
            loadedProjectPaths: &loadedProjectPaths,
            xcodebuild: Xcodebuild(shell: shell, logger: logger),
            shell: shell,
            logger: logger
        )
    }
}
