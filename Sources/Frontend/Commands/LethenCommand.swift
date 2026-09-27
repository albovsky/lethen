import ArgumentParser

public struct LethenCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lethen",
        subcommands: [
            ScanCommand.self,
            ExplainCommand.self,
            CheckUpdateCommand.self,
            ClearCacheCommand.self,
            VersionCommand.self,
        ]
    )

    public init() {}
}
