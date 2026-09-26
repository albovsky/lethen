import ArgumentParser
import Foundation
import Frontend

// When stdout is a pipe, enable line buffering so output is flushed after each
// newline rather than block-buffered, ensuring timely output to the consumer.
var info = stat()
fstat(STDOUT_FILENO, &info)

if (info.st_mode & S_IFMT) == S_IFIFO {
    setlinebuf(stdout)
    setlinebuf(stderr)
}

do {
    var command = try LethenCommand.parseAsRoot()
    try command.run()
} catch {
    LethenCommand.exit(withError: error)
}
