import Foundation
import Logger
@testable import Shared
import Synchronization
import XCTest

final class ShellTest: XCTestCase {
    private var shell: ShellImpl!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        shell = nil
        directory = nil
        try super.tearDownWithError()
    }

    func testDeliversLinesWhileTheCommandRuns() throws {
        // The command waits for a file that only the line handler creates, so it reports whether the
        // handler saw its first line before the command exited.
        let marker = directory.appendingPathComponent("seen").path
        let command = """
        echo ready; i=0; while [ ! -f '\(marker)' ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done; \
        if [ -f '\(marker)' ]; then echo streamed; else echo buffered; fi
        """
        let lines = LineRecorder()

        let output = try shell.exec(["/bin/sh", "-c", command]) { line in
            lines.append(line)
            if line == "ready" {
                FileManager.default.createFile(atPath: marker, contents: nil)
            }
        }

        XCTAssertEqual(output, "ready\nstreamed\n")
        XCTAssertEqual(lines.all, ["ready", "streamed"])
    }

    func testDeliversStandardErrorAndUnterminatedLinesButReturnsStandardOutput() throws {
        let lines = LineRecorder()

        let output = try shell.exec(["/bin/sh", "-c", "printf 'out\\r\\n'; printf 'err\\n' >&2; printf 'tail'"]) { lines.append($0) }

        XCTAssertEqual(output, "out\r\ntail")
        XCTAssertEqual(lines.all.sorted(), ["err", "out", "tail"])
    }

    func testFailureAfterStreamingThrowsWithTheCapturedOutput() {
        let lines = LineRecorder()

        XCTAssertThrowsError(try shell.exec(["/bin/sh", "-c", "echo progress; echo failure >&2; exit 3"]) { lines.append($0) }) { error in
            guard case let LethenError.shellCommandFailed(_, status, output) = error else {
                return XCTFail("Expected a failed shell command, got: \(error)")
            }

            XCTAssertEqual(status, 3)
            XCTAssertEqual(output, "progress\n\nfailure")
        }
        XCTAssertEqual(lines.all.sorted(), ["failure", "progress"])
    }

    func testCapturesOutputLargerThanAPipeBufferOnBothStreams() throws {
        // Standard error is filled before anything is written to standard output. A reader that drains standard
        // output to its end before reading standard error never returns.
        let size = 256 * 1024
        let command = "head -c \(size) /dev/zero | tr '\\0' e >&2; head -c \(size) /dev/zero | tr '\\0' o"
        let finished = expectation(description: "command finished")
        let result = Mutex<Result<String, Error>?>(nil)
        let shell = shell!

        DispatchQueue.global().async {
            let output = Result { try shell.exec(["/bin/sh", "-c", command]) }
            result.withLock { $0 = output }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)

        let output = try XCTUnwrap(result.withLock { $0 }).get()
        XCTAssertEqual(output.count, size)
        XCTAssertTrue(output.allSatisfy { $0 == "o" })
    }

    func testCapturingWithoutAHandlerIsUnchanged() throws {
        XCTAssertEqual(try shell.exec(["/bin/sh", "-c", "echo out; echo err >&2"]), "out\n")
        XCTAssertThrowsError(try shell.exec(["/bin/sh", "-c", "echo out; echo err >&2; exit 1"])) { error in
            XCTAssertEqual(String(describing: error), "Shell command '/bin/sh -c 'echo out; echo err >&2; exit 1'' returned exit status '1':\nout\n\nerr")
        }
    }

    func testExecStatusReturnsTheExitStatus() throws {
        XCTAssertEqual(try shell.execStatus(["/bin/sh", "-c", "exit 7"]), 7)
        XCTAssertEqual(try shell.execStatus(["true"]), 0)
    }

    /// A command killed by a signal reports 128 plus the signal, as a shell does, rather than the bare signal number.
    func testCommandKilledByASignalReportsTheShellStatus() {
        XCTAssertEqual(try shell.execStatus(["/bin/sh", "-c", "kill -9 $$"]), 137)
        XCTAssertThrowsError(try shell.exec(["/bin/sh", "-c", "kill -9 $$"])) { error in
            guard case let LethenError.shellCommandFailed(_, status, _) = error else {
                return XCTFail("Expected a failed shell command, got: \(error)")
            }

            XCTAssertEqual(status, 137)
        }
    }

    // MARK: - Arguments

    /// Arguments are data: nothing in them is expanded, substituted or split, whichever way the command is run.
    func testArgumentsReachTheProgramExactlyAsGiven() throws {
        let dollar = directory.appendingPathComponent("dollar").path
        let backtick = directory.appendingPathComponent("backtick").path
        let argument = "My App $(touch '\(dollar)') `touch '\(backtick)'` \"double\" 'single' back\\slash ; semi | pipe & $HOME *"

        XCTAssertEqual(try shell.exec(["printf", "%s", argument]), argument)
        XCTAssertEqual(try shell.exec(["printf", "%s", argument]) { _ in }, argument)
        XCTAssertEqual(try shell.execStatus(["test", argument, "=", argument]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dollar))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backtick))
    }

    func testPlainArgumentsStillRunTheCommand() throws {
        XCTAssertEqual(try shell.exec(["echo", "hello", "world"]), "hello world\n")
        XCTAssertEqual(try shell.exec(["printf", "%s|%s", "", "empty"]), "|empty")
    }

    func testMissingCommandFailsAsAShellWould() {
        XCTAssertThrowsError(try shell.exec(["lethen-no-such-command"])) { error in
            guard case let LethenError.shellCommandFailed(cmd, status, output) = error else {
                return XCTFail("Expected a failed shell command, got: \(error)")
            }

            XCTAssertEqual(cmd, ["lethen-no-such-command"])
            XCTAssertEqual(status, 127)
            XCTAssertEqual(output, "lethen-no-such-command: command not found")
        }
        XCTAssertThrowsError(try shell.execStatus([]))
    }

    func testFindsCommandsOnThePathInOrder() throws {
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A directory and a non-executable file with the command's name are skipped, as a shell skips them.
        try FileManager.default.createDirectory(at: first.appendingPathComponent("tool"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: second.appendingPathComponent("tool").path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let third = directory.appendingPathComponent("third")
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: third.appendingPathComponent("tool").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let path = [first, second, third].map(\.path).joined(separator: ":")
        XCTAssertEqual(ShellImpl.executableURL(for: "tool", environment: ["PATH": path])?.path, third.appendingPathComponent("tool").path)
        XCTAssertNil(ShellImpl.executableURL(for: "tool", environment: ["PATH": first.path]))
        XCTAssertEqual(ShellImpl.executableURL(for: "/bin/sh", environment: ["PATH": ""])?.path, "/bin/sh")
        XCTAssertNil(ShellImpl.executableURL(for: "", environment: ["PATH": path]))
    }

    func testCommandsAreRenderedAsTheyCouldBeTyped() {
        XCTAssertEqual(["swift", "build", "-c", "release", "--scratch-path=/tmp/x"].shellRendered, "swift build -c release --scratch-path=/tmp/x")
        XCTAssertEqual(["xcodebuild", "-project", "/a b/$(x).xcodeproj", "-scheme", "it's", ""].shellRendered,
                       "xcodebuild -project '/a b/$(x).xcodeproj' -scheme 'it'\\''s' ''")
    }

    func testShellsWithoutStreamingCaptureAndReportNoLines() throws {
        struct CapturingShell: Shell {
            func exec(_ args: [String]) throws -> String {
                args.joined(separator: " ")
            }

            func execStatus(_: [String]) throws -> Int32 {
                0
            }
        }
        let lines = LineRecorder()

        XCTAssertEqual(try CapturingShell().exec(["swift", "build"]) { lines.append($0) }, "swift build")
        XCTAssertEqual(lines.all, [])
    }
}

private final class LineRecorder: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}
