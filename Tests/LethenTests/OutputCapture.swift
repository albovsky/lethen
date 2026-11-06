import Foundation
import Synchronization
import XCTest

/// Runs `body` with `descriptor` (standard output or standard error) redirected to a pipe and returns
/// what was written to it. The pipe is drained while `body` runs, so large output cannot fill it.
func captureOutput(of descriptor: Int32, _ body: () throws -> Void) throws -> String {
    fflush(stdout)
    fflush(stderr)
    let pipe = Pipe()
    let captured = Mutex(Data())
    let reading = DispatchGroup()
    DispatchQueue.global().async(group: reading) {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        captured.withLock { $0 = data }
    }

    let savedDescriptor = dup(descriptor)
    dup2(pipe.fileHandleForWriting.fileDescriptor, descriptor)

    func finish() throws -> Data {
        fflush(stdout)
        fflush(stderr)
        dup2(savedDescriptor, descriptor)
        close(savedDescriptor)
        try pipe.fileHandleForWriting.close()
        reading.wait()
        return captured.withLock { $0 }
    }

    do {
        try body()
    } catch {
        _ = try? finish()
        throw error
    }

    return try XCTUnwrap(String(bytes: finish(), encoding: .utf8))
}

/// Runs `body` with standard output and standard error redirected to one pipe, as `2>&1` does, and returns what was
/// written to it in the order it arrived.
func captureMergedOutput(_ body: () throws -> Void) throws -> String {
    let savedError = dup(STDERR_FILENO)
    defer { close(savedError) }
    return try captureOutput(of: STDOUT_FILENO) {
        fflush(stderr)
        dup2(STDOUT_FILENO, STDERR_FILENO)
        defer {
            fflush(stderr)
            dup2(savedError, STDERR_FILENO)
        }
        try body()
    }
}
