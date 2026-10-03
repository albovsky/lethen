import Foundation
import SystemPackage
@testable import XcodeSupport
import XCTest

/// A build's index can be reused only while nothing it depends on changed since it started: any directory, and any
/// file but a compiled source, must predate the start, and a compiled source the completion.
final class XcodeBuildInputsTest: XCTestCase {
    private var root: FilePath!
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

    func testFileAddedInASubdirectoryIsReportedThroughItsDirectory() throws {
        try write("Sources/New.swift")
        try touch("Sources/New.swift", before)
        try touch("Sources", between)

        XCTAssertEqual(change(), root.appending("Sources"))
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
        XCTAssertNil(XcodeBuildInputs.firstChange(roots: [root], files: [file], started: started, completed: completed))

        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: file.string)
        XCTAssertEqual(XcodeBuildInputs.firstChange(roots: [root], files: [file], started: started, completed: completed), file)

        // A listed file that no longer exists is a change too.
        try FileManager.default.removeItem(at: file.url)
        XCTAssertEqual(XcodeBuildInputs.firstChange(roots: [root], files: [file], started: started, completed: completed), file)
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
        XCTAssertNil(XcodeBuildInputs.firstChange(roots: [root], files: files, started: started, completed: completed))

        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: target.string)
        for file in files {
            XCTAssertEqual(XcodeBuildInputs.firstChange(roots: [root], files: [file], started: started, completed: completed), file)
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

            XCTAssertEqual(XcodeBuildInputs.firstChange(roots: [root], files: [file], started: started, completed: completed), file, name)
        }

        let source = other.appending("Shared.swift")
        try Data().write(to: source.url)
        try FileManager.default.setAttributes([.modificationDate: between], ofItemAtPath: source.string)

        XCTAssertNil(XcodeBuildInputs.firstChange(roots: [root], files: [source], started: started, completed: completed))
    }

    func testMissingRootIsReported() {
        let missing = root.appending("Removed")

        XCTAssertEqual(XcodeBuildInputs.firstChange(roots: [root, missing], files: [], started: started, completed: completed), missing)
    }

    func testUnreadableDirectoryIsReported() throws {
        let locked = root.appending("Locked")
        try write("Locked/Hidden.swift")
        try settle()
        XCTAssertNil(change())

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.string)

        XCTAssertNotNil(change())
    }

    /// A declared directory can be reached through a symbolic link, which the enumerator does not enter on its own.
    func testRootThatIsASymbolicLinkIsWalkedAsItsTarget() throws {
        let link = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen build inputs link \(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(at: link.url) }
        try FileManager.default.createSymbolicLink(atPath: link.string, withDestinationPath: root.string)
        XCTAssertNil(XcodeBuildInputs.firstChange(roots: [link], files: [], started: started, completed: completed))

        try touch("Sources/App.swift", after)

        XCTAssertEqual(
            XcodeBuildInputs.firstChange(roots: [link], files: [], started: started, completed: completed),
            link.appending("Sources/App.swift")
        )
    }

    // MARK: - Private

    private func change() -> FilePath? {
        XcodeBuildInputs.firstChange(roots: [root], files: [], started: started, completed: completed)
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
