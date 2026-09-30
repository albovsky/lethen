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
        let process = try launch(args)
        defer { store.remove(process) }
        process.waitUntilExit()
        return Self.exitStatus(of: process)
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

    /// Starts `cmd` directly, with its first element as the program and the rest as its arguments. No shell sees the
    /// command, so arguments reach the program exactly as given: paths, scheme names and build arguments are data,
    /// never shell syntax.
    private func launch(_ cmd: [String], configure: (Process) -> Void = { _ in }) throws -> Process {
        guard let name = cmd.first, let executable = Self.executableURL(for: name) else {
            throw LethenError.shellCommandFailed(cmd: cmd, status: 127, output: "\(cmd.first ?? ""): command not found")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Array(cmd.dropFirst())
        configure(process)

        logger.debug(cmd.shellRendered)
        store.add(process)
        do {
            try process.run()
        } catch {
            store.remove(process)
            throw error
        }
        return process
    }

    /// The executable `name` runs: `name` itself when it contains a slash, otherwise the first executable file named
    /// `name` in a `PATH` directory, as a shell would find it.
    static func executableURL(for name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard !name.isEmpty else { return nil }

        if name.contains("/") {
            return URL(fileURLWithPath: name)
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory)).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }

        return nil
    }

    private func captureOutput(
        of cmd: [String],
        lineHandler: SerialLineHandler?
    ) throws -> (Int32, String, String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try launch(cmd) {
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

        return (Self.exitStatus(of: process), standardOutput, standardError)
    }

    /// The status a shell reports for `process`: its exit status, or 128 plus the signal that killed it.
    private static func exitStatus(of process: Process) -> Int32 {
        process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
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

public extension [String] {
    /// The command as it could be typed into a shell, for logs and error messages. Arguments that a shell would
    /// change are single-quoted.
    var shellRendered: String {
        map { argument in
            let isPlain = !argument.isEmpty && argument.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "@%+=:,./_-".unicodeScalars.contains(scalar))
            }
            return isPlain ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }
}
