import Foundation
import Logger
import Synchronization

final class ShellProcessStore: Sendable {
    private let processes = Mutex<Set<Process>>([])

    func interruptRunning() {
        processes.withLock { processes in
            for process in processes {
                process.interrupt()
                process.waitUntilExit()
            }
        }
    }

    func add(_ process: Process) {
        processes.withLock { _ = $0.insert(process) }
    }

    func remove(_ process: Process) {
        processes.withLock { _ = $0.remove(process) }
    }
}

public protocol Shell: Sendable {
    @discardableResult
    func exec(_ args: [String]) throws -> String
    /// Runs `args` like `exec(_:)`, and also passes each line the command writes to standard output or standard
    /// error to `onOutputLine` while the command runs. Lines are delivered one at a time, from a background thread.
    /// The returned output and the error thrown on failure are the same as `exec(_:)`.
    @discardableResult
    func exec(_ args: [String], onOutputLine: @escaping @Sendable (String) -> Void) throws -> String
    func execStatus(_ args: [String]) throws -> Int32
}

public extension Shell {
    /// Shells that cannot observe output while a command runs capture it as `exec(_:)` does and report no lines.
    @discardableResult
    func exec(_ args: [String], onOutputLine _: @escaping @Sendable (String) -> Void) throws -> String {
        try exec(args)
    }
}

public final class ShellImpl: Shell {
    private let logger: ContextualLogger
    private let store: ShellProcessStore
    private let signalSource: DispatchSourceSignal

    public required init(logger: Logger, sigintHandler: @escaping () -> Void = {}) {
        self.logger = logger.contextualized(with: "shell")
        store = ShellProcessStore()

        signal(SIGINT, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler { [store] in
            sigintHandler()
            store.interruptRunning()
            exit(0)
        }
        signalSource.resume()
    }

    @discardableResult
    public func exec(_ args: [String]) throws -> String {
        try capture(args, lineHandler: nil)
    }

    @discardableResult
    public func exec(_ args: [String], onOutputLine: @escaping @Sendable (String) -> Void) throws -> String {
        try capture(args, lineHandler: SerialLineHandler(onOutputLine))
    }

    @discardableResult
    public func execStatus(_ args: [String]) throws -> Int32 {
        let process = launch(args)
        defer { store.remove(process) }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Private

    private func capture(_ args: [String], lineHandler: SerialLineHandler?) throws -> String {
        let (status, stdout, stderr) = try captureOutput(of: args, lineHandler: lineHandler)

        if status == 0 {
            return stdout
        }

        throw LethenError.shellCommandFailed(
            cmd: args,
            status: status,
            output: [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n").trimmed
        )
    }

    private func launch(_ cmd: [String], configure: (Process) -> Void = { _ in }) -> Process {
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-c", cmd.joined(separator: " ")]
        configure(process)

        logger.debug("\(cmd.joined(separator: " "))")
        store.add(process)
        process.launch()
        return process
    }

    private func captureOutput(
        of cmd: [String],
        lineHandler: SerialLineHandler?
    ) throws -> (Int32, String, String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = launch(cmd) {
            $0.standardOutput = stdoutPipe
            $0.standardError = stderrPipe
        }
        defer { store.remove(process) }

        // Drain both pipes concurrently. Reading one to its end before the other would stall a command that
        // fills the other pipe, and would hold back the lines of whichever stream is read second.
        let stderrResult = Mutex<Result<Data, Error>>(.success(Data()))
        let stderrReader = DispatchGroup()
        DispatchQueue.global().async(group: stderrReader) {
            let result = Result { try Self.drain(stderrPipe.fileHandleForReading, lineHandler: lineHandler) }
            stderrResult.withLock { $0 = result }
        }
        let stdoutResult = Result { try Self.drain(stdoutPipe.fileHandleForReading, lineHandler: lineHandler) }
        stderrReader.wait()
        process.waitUntilExit()

        let stdoutData = try stdoutResult.get()
        let stderrData = try stderrResult.withLock { $0 }.get()

        guard let standardOutput = String(data: stdoutData, encoding: .utf8),
              let standardError = String(data: stderrData, encoding: .utf8)
        else {
            throw LethenError.shellOutputEncodingFailed(
                cmd: cmd,
                encoding: .utf8
            )
        }

        return (process.terminationStatus, standardOutput, standardError)
    }

    /// Reads `handle` until end of file, passing each complete line to `lineHandler` as soon as it is read.
    private static func drain(_ handle: FileHandle, lineHandler: SerialLineHandler?) throws -> Data {
        let newline = UInt8(ascii: "\n")
        let descriptor = handle.fileDescriptor
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var lineStart = 0

        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }

            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            guard count > 0 else { break }

            output.append(contentsOf: buffer[0 ..< count])

            guard let lineHandler else { continue }

            while let newlineIndex = output[lineStart...].firstIndex(of: newline) {
                lineHandler.deliver(output[lineStart ..< newlineIndex])
                lineStart = newlineIndex + 1
            }
        }

        if let lineHandler, lineStart < output.count {
            lineHandler.deliver(output[lineStart...])
        }

        return output
    }
}

/// Passes lines from both output streams to a handler one at a time.
private final class SerialLineHandler: Sendable {
    private let handler: Mutex<@Sendable (String) -> Void>

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = Mutex(handler)
    }

    func deliver(_ bytes: Data) {
        // Output that is not UTF-8 fails the command once it exits, see `shellOutputEncodingFailed`.
        guard var line = String(bytes: bytes, encoding: .utf8) else { return }

        if line.hasSuffix("\r") {
            line.removeLast()
        }
        handler.withLock { $0(line) }
    }
}
