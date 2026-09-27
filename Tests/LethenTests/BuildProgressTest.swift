import Configuration
import Foundation
import Logger
import Shared
import Synchronization
import XCTest

final class BuildProgressTest: XCTestCase {
    func testModeFollowsQuietVerboseAndOutputFormat() {
        for format in OutputFormat.allCases {
            let auxiliary = format.supportsAuxiliaryOutput
            XCTAssertEqual(BuildProgress.mode(quiet: true, verbose: false, supportsAuxiliaryOutput: auxiliary), .silent, "\(format)")
            XCTAssertEqual(BuildProgress.mode(quiet: true, verbose: true, supportsAuxiliaryOutput: auxiliary), .silent, "\(format)")
            XCTAssertEqual(BuildProgress.mode(quiet: false, verbose: true, supportsAuxiliaryOutput: auxiliary), .fullOutput, "\(format)")
        }

        XCTAssertEqual(BuildProgress.mode(quiet: false, verbose: false, supportsAuxiliaryOutput: OutputFormat.xcode.supportsAuxiliaryOutput), .heartbeat)
        for format in [OutputFormat.json, .csv, .checkstyle, .codeclimate, .githubActions, .githubMarkdown, .gitlabCodeQuality] {
            XCTAssertEqual(BuildProgress.mode(quiet: false, verbose: false, supportsAuxiliaryOutput: format.supportsAuxiliaryOutput), .silent, "\(format)")
        }
    }

    func testFullOutputWritesEveryLineAndReturnsTheBuildResult() {
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .fullOutput, write: { writes.append($0) })

        let result = progress.run { onOutputLine in
            onOutputLine("[1/2] Compiling A a.swift")
            onOutputLine("warning: something")
            return "built"
        }

        XCTAssertEqual(result, "built")
        XCTAssertEqual(writes.all, ["[1/2] Compiling A a.swift", "warning: something"])
    }

    func testSilentWritesNothing() {
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .silent, interval: .milliseconds(10), write: { writes.append($0) })

        progress.run { onOutputLine in
            onOutputLine("[1/2] Compiling A a.swift")
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTAssertEqual(writes.all, [])
    }

    func testHeartbeatReportsElapsedTimeAndLatestStepWithoutBuildOutput() throws {
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .heartbeat, interval: .milliseconds(20), write: { writes.append($0) })

        try progress.run { onOutputLine in
            onOutputLine("Building for debugging...")
            onOutputLine("[3/10] Compiling A a.swift")
            onOutputLine("[4/10] Compiling A b.swift")
            onOutputLine("warning: [9/9] is not a progress line")
            try waitUntil { writes.all.count >= 2 }
        }

        let heartbeat = try XCTUnwrap(writes.all.first)
        XCTAssertTrue(heartbeat.hasPrefix("  Still building ("), heartbeat)
        XCTAssertTrue(heartbeat.hasSuffix("s elapsed, step 4/10)"), heartbeat)
        XCTAssertFalse(writes.all.contains { $0.contains("Compiling") || $0.contains("warning") })
    }

    func testHeartbeatReadsSwiftBuildProgressLines() throws {
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .heartbeat, interval: .milliseconds(20), write: { writes.append($0) })

        try progress.run { onOutputLine in
            onOutputLine("[Planning deferred tasks]")
            onOutputLine("[43 / 60] TargetA")
            onOutputLine("[Planning deferred tasks]")
            try waitUntil { !writes.all.isEmpty }
        }

        let heartbeat = try XCTUnwrap(writes.all.first)
        XCTAssertTrue(heartbeat.hasSuffix("s elapsed, step 43/60)"), heartbeat)
        XCTAssertFalse(writes.all.contains { $0.contains("TargetA") || $0.contains("Planning") })
    }

    func testHeartbeatWithoutProgressLinesReportsElapsedTimeOnly() throws {
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .heartbeat, interval: .milliseconds(20), write: { writes.append($0) })

        try progress.run { onOutputLine in
            onOutputLine("note: Using codesigning identity override")
            try waitUntil { !writes.all.isEmpty }
        }

        let heartbeat = try XCTUnwrap(writes.all.first)
        XCTAssertTrue(heartbeat.hasPrefix("  Still building ("), heartbeat)
        XCTAssertTrue(heartbeat.hasSuffix("s elapsed)"), heartbeat)
    }

    func testHeartbeatStopsWhenTheBuildFails() throws {
        struct BuildFailed: Error {}
        let writes = WriteRecorder()
        let progress = BuildProgress(mode: .heartbeat, interval: .milliseconds(20), write: { writes.append($0) })

        XCTAssertThrowsError(try progress.run { _ in
            try waitUntil { !writes.all.isEmpty }
            throw BuildFailed()
        }) { XCTAssertTrue($0 is BuildFailed) }

        let count = writes.all.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(writes.all.count, count)
    }

    func testLoggerWritesProgressToStandardErrorOnly() throws {
        let logger = Logger(quiet: false, verbose: false, colorMode: .never)
        var standardError = ""

        let standardOutput = try captureOutput(of: STDOUT_FILENO) {
            standardError = try captureOutput(of: STDERR_FILENO) {
                logger.progress("  Still building (15s elapsed)")
            }
        }

        XCTAssertEqual(standardOutput, "")
        XCTAssertEqual(standardError, "  Still building (15s elapsed)\n")
    }

    func testQuietLoggerWritesNoProgress() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)

        let standardError = try captureOutput(of: STDERR_FILENO) {
            logger.progress("  Still building (15s elapsed)")
        }

        XCTAssertEqual(standardError, "")
    }

    private struct TimedOut: Error {}

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw TimedOut() }

            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private final class WriteRecorder: Sendable {
    private let writes = Mutex<[String]>([])

    var all: [String] {
        writes.withLock { $0 }
    }

    func append(_ text: String) {
        writes.withLock { $0.append(text) }
    }
}
