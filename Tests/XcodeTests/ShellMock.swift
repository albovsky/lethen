import Foundation
import Logger
import Shared
import Synchronization

struct ShellMock: Shell {
    let output: String

    func exec(_: [String]) throws -> String {
        output
    }

    func execStatus(_: [String]) throws -> Int32 {
        0
    }
}

/// Records every command instead of running it, answering like `xcodebuild -version`. A command containing
/// `failingArgument` throws, as a failed build does. With `listedSchemes`, `xcodebuild -list -json` answers with
/// those schemes in the `project` section.
final class RecordingShell: Shell {
    private let commands = Mutex<[[String]]>([])
    private let streamedCommands = Mutex<[[String]]>([])
    private let failingArgument: String?
    private let listedSchemes: [String]

    init(failingArgument: String? = nil, listedSchemes: [String] = []) {
        self.failingArgument = failingArgument
        self.listedSchemes = listedSchemes
    }

    var executed: [[String]] {
        commands.withLock { $0 }
    }

    var streamed: [[String]] {
        streamedCommands.withLock { $0 }
    }

    var derivedDataPaths: [String] {
        executed.compactMap { command in
            guard command.first == "xcodebuild", let index = command.firstIndex(of: "-derivedDataPath") else { return nil }

            return command[index + 1]
        }
    }

    func exec(_ args: [String]) throws -> String {
        commands.withLock { $0.append(args) }
        if let failingArgument, args.contains(failingArgument) {
            throw LethenError.shellCommandFailed(cmd: args, status: 65, output: "** TEST BUILD FAILED **")
        }

        if args.contains("-list") {
            let names = listedSchemes.map { "\"\($0)\"" }.joined(separator: ", ")
            return "{\n\"project\" : {\n\"schemes\" : [\(names)],\n\"name\" : \"Listed\"\n}\n}"
        }

        return "Xcode 27.0\nBuild version 27A266a"
    }

    func exec(_ args: [String], onOutputLine: @escaping @Sendable (String) -> Void) throws -> String {
        streamedCommands.withLock { $0.append(args) }
        onOutputLine("note: Building targets in dependency order")
        return try exec(args)
    }

    func execStatus(_: [String]) throws -> Int32 {
        0
    }
}

/// Records every command like `RecordingShell`, and runs it. A build that reuses an earlier one needs the real
/// `xcodebuild -version`, since DerivedData's name is a hash of it.
final class ForwardingRecordingShell: Shell {
    private let streamedCommands = Mutex<[[String]]>([])
    private let shell: ShellImpl

    init(logger: Logger) {
        shell = ShellImpl(logger: logger)
    }

    var streamed: [[String]] {
        streamedCommands.withLock { $0 }
    }

    func exec(_ args: [String]) throws -> String {
        try shell.exec(args)
    }

    func exec(_ args: [String], onOutputLine: @escaping @Sendable (String) -> Void) throws -> String {
        streamedCommands.withLock { $0.append(args) }
        return try shell.exec(args, onOutputLine: onOutputLine)
    }

    func execStatus(_ args: [String]) throws -> Int32 {
        try shell.execStatus(args)
    }
}
