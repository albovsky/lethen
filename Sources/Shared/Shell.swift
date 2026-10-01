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
        let process: Process
        do {
            process = try launch(args)
        } catch let LethenError.shellCommandFailed(_, status, output) where status == 126 || status == 127 {
            // A missing or non-executable program is a status, as from a shell, so callers that exit with it still
            // exit 127 or 126.
            FileHandle.standardError.write(Data((output + "\n").utf8))
            return status
        }
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
        let name = cmd.first ?? ""
        let executable: URL
        switch Self.lookUp(name) {
        case let .found(url):
            executable = url
        case .notExecutable:
            throw LethenError.shellCommandFailed(cmd: cmd, status: 126, output: "\(name): Permission denied")
        case .notFound:
            let reason = name.contains("/") ? "No such file or directory" : "command not found"
            throw LethenError.shellCommandFailed(cmd: cmd, status: 127, output: "\(name): \(reason)")
        }

        logger.debug(cmd.shellRendered)
        let arguments = Array(cmd.dropFirst())
        do {
            return try start(executable, arguments: arguments, configure: configure)
        } catch {
            switch Self.posixCode(of: error) {
            case ENOEXEC:
                // An executable text file without a `#!` line, such as a PATH wrapper, is run by a shell when the
                // system will not run it, as a shell itself does. Its arguments still reach it as separate arguments.
                return try start(Self.fallbackShell, arguments: [executable.path] + arguments, configure: configure)
            case let .some(code):
                // The program was found but could not start, such as a script whose `#!` interpreter is missing: a
                // shell reports 127 when something is missing and 126 otherwise.
                throw LethenError.shellCommandFailed(
                    cmd: cmd,
                    status: code == ENOENT ? 127 : 126,
                    output: "\(name): \(String(cString: strerror(code)))"
                )
            case nil:
                throw error
            }
        }
    }

    /// The POSIX error a failed start reports. Foundation reports it directly on macOS and wraps it in a Cocoa error
    /// on Linux.
    private static func posixCode(of error: Error) -> Int32? {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return Int32(error.code)
        }

        return (error.userInfo[NSUnderlyingErrorKey] as? Error).flatMap(posixCode)
    }

    /// The directories searched when `PATH` is unset: bash's own default, which includes `/usr/local/bin`, without its
    /// trailing `.`, so a program in the scanned project's directory is never run in place of a missing build tool.
    static var defaultSearchPath: String {
        #if os(macOS)
            "/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin"
        #else
            "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
        #endif
    }

    /// The shell that runs an executable file the system cannot run itself; bash ran such files before.
    private static var fallbackShell: URL {
        URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/bin/bash") ? "/bin/bash" : "/bin/sh")
    }

    private func start(_ executable: URL, arguments: [String], configure: (Process) -> Void) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        configure(process)

        store.add(process)
        do {
            try process.run()
        } catch {
            store.remove(process)
            throw error
        }
        return process
    }

    /// What a shell finds for a command name.
    enum Lookup: Equatable {
        /// An executable file to run.
        case found(URL)
        /// A file that is not executable, and no executable one: a shell reports status 126.
        case notExecutable(URL)
        /// Nothing at all: a shell reports status 127.
        case notFound
    }

    /// Finds the program `name` runs as a shell would: `name` itself when it contains a slash, otherwise the first
    /// executable file named `name` in a `PATH` directory. A file without execute permission is reported only when no
    /// executable one follows it.
    static func lookUp(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Lookup {
        guard !name.isEmpty else { return .notFound }

        func classify(_ candidate: URL) -> Lookup {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return .notFound }

            return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate.path)
                ? .found(candidate) : .notExecutable(candidate)
        }

        if name.contains("/") {
            return classify(URL(fileURLWithPath: name))
        }

        var firstNotExecutable: URL?
        let searchPath = environment["PATH"] ?? defaultSearchPath
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory)).appendingPathComponent(name)
            switch classify(candidate) {
            case .found:
                return .found(candidate)
            case .notExecutable:
                // A directory on the search path is skipped silently, as a shell skips it.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    firstNotExecutable = firstNotExecutable ?? candidate
                }
            case .notFound:
                continue
            }
        }

        return firstNotExecutable.map { .notExecutable($0) } ?? .notFound
    }

    private func captureOutput(
        of cmd: [String],
        lineHandler: SerialLineHandler?
    ) throws -> (Int32, String, String) {
        // Each launch attempt gets its own pipes: a failed start closes the ones it was given.
        let process = try launch(cmd) {
            $0.standardOutput = Pipe()
            $0.standardError = Pipe()
        }
        defer { store.remove(process) }
        // swiftlint:disable:next force_cast
        let (stdoutPipe, stderrPipe) = (process.standardOutput as! Pipe, process.standardError as! Pipe)

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
