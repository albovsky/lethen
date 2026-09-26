import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Display the version of lethen"
    )

    func run() throws {
        print(LethenVersion)
    }
}
