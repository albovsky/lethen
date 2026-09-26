import Foundation
import XCTest

/// Runs `body` with `descriptor` (standard output or standard error) redirected to a pipe and returns
/// what was written to it.
func captureOutput(of descriptor: Int32, _ body: () throws -> Void) throws -> String {
    fflush(stdout)
    fflush(stderr)
    let pipe = Pipe()
    let savedDescriptor = dup(descriptor)
    dup2(pipe.fileHandleForWriting.fileDescriptor, descriptor)

    func restore() {
        fflush(stdout)
        fflush(stderr)
        dup2(savedDescriptor, descriptor)
        close(savedDescriptor)
    }

    do {
        try body()
    } catch {
        restore()
        throw error
    }

    restore()
    try pipe.fileHandleForWriting.close()
    return try XCTUnwrap(String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
}
