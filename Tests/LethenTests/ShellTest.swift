import Foundation
import Logger
import Shared
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

        let output = try shell.exec([command]) { line in
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

        let output = try shell.exec(["printf 'out\\r\\n'; printf 'err\\n' >&2; printf 'tail'"]) { lines.append($0) }

        XCTAssertEqual(output, "out\r\ntail")
        XCTAssertEqual(lines.all.sorted(), ["err", "out", "tail"])
    }

    func testFailureAfterStreamingThrowsWithTheCapturedOutput() {
        let lines = LineRecorder()

        XCTAssertThrowsError(try shell.exec(["echo progress; echo failure >&2; exit 3"]) { lines.append($0) }) { error in
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
            let output = Result { try shell.exec([command]) }
            result.withLock { $0 = output }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)

        let output = try XCTUnwrap(result.withLock { $0 }).get()
        XCTAssertEqual(output.count, size)
        XCTAssertTrue(output.allSatisfy { $0 == "o" })
    }

    func testCapturingWithoutAHandlerIsUnchanged() throws {
        XCTAssertEqual(try shell.exec(["echo out; echo err >&2"]), "out\n")
        XCTAssertThrowsError(try shell.exec(["echo out; echo err >&2; exit 1"])) { error in
            XCTAssertEqual(String(describing: error), "Shell command 'echo out; echo err >&2; exit 1' returned exit status '1':\nout\n\nerr")
        }
    }

    func testExecStatusReturnsTheExitStatus() throws {
        XCTAssertEqual(try shell.execStatus(["exit 7"]), 7)
        XCTAssertEqual(try shell.execStatus(["true"]), 0)
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
