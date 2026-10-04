import Foundation
import SystemPackage
@testable import XcodeSupport
import XCTest

/// A build's index can be reused only while nothing it depends on changed since it started: every tracked file but a
/// compiled source must predate the start, a compiled source the completion, and the tracked files must be the ones
/// the build started with. Files a scan does not read, and directory times, do not matter.
final class XcodeBuildInputsTest: XCTestCase {
    private var root: FilePath!
    /// The tracked files as the build started.
    private var recorded: Set<FilePath> = []
    private let started = Date(timeIntervalSinceReferenceDate: 1000)
    private let completed = Date(timeIntervalSinceReferenceDate: 2000)
    private let before = Date(timeIntervalSinceReferenceDate: 500)
    private let between = Date(timeIntervalSinceReferenceDate: 1500)
    private let after = Date(timeIntervalSinceReferenceDate: 3000)

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen build inputs \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        try write("Sources/App.swift")
        try write("Sources/Support.m")
        try write("Sources/Support.h")
        try write("App.xcodeproj/project.pbxproj")
        try write("Config.xcconfig")
        try write("Package.resolved")
        try settle()
        recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [])
    }

    override func tearDownWithError() throws {
        if let root {
            // Restores access that a test removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending("Locked").string)
            try? FileManager.default.removeItem(at: root.url)
        }
    }

    func testNothingChangedIsNil() {
        XCTAssertNil(change())
    }

    func testCompiledSourceEditedAfterCompletionIsReported() throws {
        try touch("Sources/App.swift", after)

        XCTAssertEqual(change(), root.appending("Sources/App.swift"))
    }

    func testCompiledSourceEditedDuringTheBuildIsLeftToTheCollector() throws {
        try touch("Sources/App.swift", between)
        try touch("Sources/Support.m", between)

        XCTAssertNil(change())
    }

    func testOtherFilesEditedDuringTheBuildAreReported() throws {
        for path in ["Sources/Support.h", "App.xcodeproj/project.pbxproj", "Config.xcconfig", "Package.resolved"] {
            try settle()
            try touch(path, between)

            XCTAssertEqual(change(), root.appending(path), path)
        }
    }

    func testFileAddedIsReportedWhateverItsDate() throws {
        try write("Sources/New.swift")
        try touch("Sources/New.swift", before)

        XCTAssertEqual(change(), root.appending("Sources/New.swift"))
    }

    func testFileRemovedIsReported() throws {
        try FileManager.default.removeItem(at: root.appending("Sources/Support.h").url)

        XCTAssertEqual(change(), root.appending("Sources/Support.h"))
    }

    func testFileRenamedIsReported() throws {
        try FileManager.default.moveItem(at: root.appending("Sources/App.swift").url, to: root.appending("Sources/Renamed.swift").url)

        XCTAssertEqual(change(), root.appending("Sources/App.swift"))
    }

    /// A build phase that rewrites localized strings, or a folder of them, changes nothing a scan reads.
    func testFilesAScanDoesNotReadAreIgnored() throws {
        try write("en.lproj/Localizable.strings")
        try write("Assets.xcassets/Contents.json")
        try settle()
        recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [])

        for path in ["en.lproj/Localizable.strings", "Assets.xcassets/Contents.json", "en.lproj", "Assets.xcassets", "Sources", ""] {
            try touch(path, after)
        }
        try write("fr.lproj/Localizable.strings")
        try write("Sources/Notes.md")

        XCTAssertNil(change())
    }

    func testEveryTrackedKindIsReportedWhenEditedDuringTheBuild() throws {
        let paths = [
            "A.h", "A.hh", "A.hpp", "A.inc", "A.inl", "A.pch", "A.modulemap", "A.def", "A.xcconfig", "A.xcscheme", "A.entitlements",
            "App.xcworkspace/contents.xcworkspacedata", "Info.plist", "Main.storyboard", "View.xib",
            "Model.xcdatamodeld/Model.xcdatamodel/contents", "Model.xcdatamodeld/.xccurrentversion", "Map.xcmappingmodel/xcmapping.xml",
        ]
        for path in paths {
            try write(path)
        }
        try settle()
        recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [])
        XCTAssertNil(change())

        for path in paths {
            try touch(path, between)

            XCTAssertEqual(change(), root.appending(path), path)
            try touch(path, before)
        }
    }

    func testListedFileIsTrackedWhateverItIsCalled() throws {
        let file = root.appending("Scripts/Inputs.txt")
        try write("Scripts/Inputs.txt")
        try settle()
        let recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [file])
        XCTAssertTrue(recorded.contains(file))

        try touch("Scripts/Inputs.txt", between)

        XCTAssertEqual(firstChange(roots: [root], files: [file], recorded: recorded), file)
    }

    func testEqualTimestampsCountAsChanged() throws {
        try touch("Config.xcconfig", started)
        XCTAssertEqual(change(), root.appending("Config.xcconfig"))

        try settle()
        try touch("Sources/App.swift", completed)
        XCTAssertEqual(change(), root.appending("Sources/App.swift"))
    }

    func testListedFileOutsideTheRootsIsChecked() throws {
        let other = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen other \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: other.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other.url) }
        let file = other.appending("Shared.swift")
        try Data().write(to: file.url)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: file.string)
        XCTAssertNil(firstChange(roots: [root], files: [file]))

        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: file.string)
        XCTAssertEqual(firstChange(roots: [root], files: [file]), file)

        // A listed file that no longer exists is a change too, but one that never existed is not, until it appears.
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: file.string)
        let recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [file])
        try FileManager.default.removeItem(at: file.url)
        XCTAssertEqual(firstChange(roots: [root], files: [file], recorded: recorded), file)
        XCTAssertNil(firstChange(roots: [root], files: [file], recorded: XcodeBuildInputs.trackedPaths(roots: [root], files: [])))
        try Data().write(to: file.url)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: file.string)
        XCTAssertEqual(firstChange(roots: [root], files: [file], recorded: XcodeBuildInputs.trackedPaths(roots: [root], files: [])), file)
    }

    /// The walk does not follow symbolic links, so a listed file is read through them: its time is the one of the file
    /// the link leads to, whether the link is the file or a directory above it.
    func testListedFileBehindASymbolicLinkIsCheckedThroughIt() throws {
        let other = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen other \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: other.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other.url) }
        let target = other.appending("Target.xcconfig")
        try Data().write(to: target.url)
        try FileManager.default.createSymbolicLink(atPath: root.appending("Linked").string, withDestinationPath: other.string)
        try FileManager.default.createSymbolicLink(atPath: root.appending("Link.xcconfig").string, withDestinationPath: target.string)
        try settle()
        // settle() follows links, so the links themselves are dated here.
        for link in ["Linked", "Link.xcconfig"] {
            var times = [timeval(tv_sec: Int(before.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(before.timeIntervalSince1970), tv_usec: 0)]
            XCTAssertEqual(lutimes(root.appending(link).string, &times), 0)
        }
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: target.string)
        let files: Set = [root.appending("Linked/Target.xcconfig"), root.appending("Link.xcconfig")]
        XCTAssertNil(firstChange(roots: [root], files: files))

        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: target.string)
        for file in files {
            XCTAssertEqual(firstChange(roots: [root], files: [file]), file)
        }
    }

    func testVersionControlBuildOutputAndUserStateAreIgnored() throws {
        try write(".git/index")
        try write(".build/debug/App.swift")
        try write("Sources/.DS_Store")
        try write("App.xcodeproj/xcuserdata/u.xcuserdatad/UserInterfaceState.xcuserstate")
        try settle()

        for path in [".git/index", ".build/debug/App.swift", "Sources/.DS_Store", "App.xcodeproj/xcuserdata/u.xcuserdatad/UserInterfaceState.xcuserstate"] {
            try touch(path, after)
        }
        // Their directories change as well.
        for path in [".git", ".build", ".build/debug", "App.xcodeproj/xcuserdata", "App.xcodeproj/xcuserdata/u.xcuserdatad"] {
            try touch(path, after)
        }

        XCTAssertNil(change())
    }

    func testUserSchemeIsNotIgnored() throws {
        let scheme = "App.xcodeproj/xcuserdata/u.xcuserdatad/xcschemes/App.xcscheme"
        try write(scheme)
        try settle()
        recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [])
        XCTAssertNil(change())

        try touch(scheme, between)

        XCTAssertEqual(change(), root.appending(scheme))
    }

    /// A listed file is held to the same limit as one found in a root: only a compiled source may be newer than the
    /// build's start.
    func testListedFileThatIsNotACompiledSourceEditedDuringTheBuildIsReported() throws {
        let other = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen listed \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: other.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other.url) }

        for name in ["Extra.xcconfig", "Shared.h"] {
            let file = other.appending(name)
            try Data().write(to: file.url)
            try FileManager.default.setAttributes([.modificationDate: between], ofItemAtPath: file.string)

            XCTAssertEqual(firstChange(roots: [root], files: [file]), file, name)
        }

        let source = other.appending("Shared.swift")
        try Data().write(to: source.url)
        try FileManager.default.setAttributes([.modificationDate: between], ofItemAtPath: source.string)

        XCTAssertNil(firstChange(roots: [root], files: [source]))
    }

    func testMissingRootIsReported() {
        let missing = root.appending("Removed")

        XCTAssertEqual(firstChange(roots: [root, missing], files: []), missing)
    }

    func testUnreadableDirectoryIsReported() throws {
        let locked = root.appending("Locked")
        try write("Locked/Hidden.swift")
        try settle()
        recorded = XcodeBuildInputs.trackedPaths(roots: [root], files: [])
        XCTAssertNil(change())

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.string)

        XCTAssertNotNil(change())
    }

    /// A declared directory can be reached through a symbolic link, which the enumerator does not enter on its own.
    func testRootThatIsASymbolicLinkIsWalkedAsItsTarget() throws {
        let link = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen build inputs link \(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(at: link.url) }
        try FileManager.default.createSymbolicLink(atPath: link.string, withDestinationPath: root.string)
        XCTAssertNil(firstChange(roots: [link], files: []))

        try touch("Sources/App.swift", after)

        XCTAssertEqual(
            firstChange(roots: [link], files: []),
            link.appending("Sources/App.swift")
        )
    }

    // MARK: - Private

    private func change() -> FilePath? {
        firstChange(roots: [root], files: [], recorded: recorded)
    }

    /// With no `recorded` list, the files found now are taken as the ones the build started with.
    private func firstChange(roots: [FilePath], files: Set<FilePath>, recorded: Set<FilePath>? = nil) -> FilePath? {
        XcodeBuildInputs.firstChange(
            roots: roots,
            files: files,
            recorded: recorded ?? XcodeBuildInputs.trackedPaths(roots: roots, files: files),
            started: started,
            completed: completed
        )
    }

    private func write(_ path: String) throws {
        let file = root.appending(path)
        try FileManager.default.createDirectory(atPath: file.removingLastComponent().string, withIntermediateDirectories: true)
        try Data().write(to: file.url)
    }

    private func touch(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appending(path).string)
    }

    /// Dates every file and directory of the tree before the build started.
    private func settle() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string))
        for case let relative as String in enumerator {
            try touch(relative, before)
        }
        try touch("", before)
    }
}
