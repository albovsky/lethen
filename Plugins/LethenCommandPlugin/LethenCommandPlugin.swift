import Foundation
import PackagePlugin

/// `swift package lethen` scans the package, and the Xcode command scans an Xcode project.
@main
struct LethenCommandPlugin: CommandPlugin {
    /// Builds the package with indexing in its own scratch directory, because the `swift package` running
    /// the plugin holds the lock on `.build`. Inside the plugin's sandbox SwiftPM can neither start a sandbox
    /// of its own nor read the keychain, and a failed keychain lookup (for example while downloading
    /// prebuilt swift-syntax) fails the build, so both are turned off.
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let scratchPath = context.package.directoryURL.appending(path: ".build/lethen").path
        try run(
            context.tool(named: "lethen").url,
            in: context.package.directoryURL,
            arguments: Self.scanArguments(arguments, buildArguments: ["--scratch-path", scratchPath, "--disable-sandbox", "--disable-keychain"])
        )
    }

    /// `lethen scan` with the user's options, and the plugin's build arguments ahead of any the user passed
    /// after `--`.
    static func scanArguments(_ arguments: [String], buildArguments: [String], defaults: [String] = []) -> [String] {
        let separator = arguments.firstIndex(of: "--")
        let options = separator.map { Array(arguments[..<$0]) } ?? arguments
        let userBuildArguments = separator.map { Array(arguments[($0 + 1)...]) } ?? []
        let missingDefaults = stride(from: 0, to: defaults.count, by: 2).flatMap { index -> [String] in
            let option = defaults[index]
            return options.contains(option) ? [] : Array(defaults[index ..< min(index + 2, defaults.count)])
        }
        let updateCheck = options.contains("--disable-update-check") ? [] : ["--disable-update-check"]
        return ["scan"] + updateCheck + missingDefaults + options + ["--"] + buildArguments + userBuildArguments
    }

    private func run(_ tool: URL, in directory: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.currentDirectoryURL = directory
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            Diagnostics.error("lethen exited with status \(process.terminationStatus)")
        }
    }
}

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension LethenCommandPlugin: XcodeCommandPlugin {
        /// Scans the index Xcode keeps for the project in its DerivedData, because building from inside
        /// Xcode's plugin sandbox is not possible, and reports each result as an Xcode issue.
        func performCommand(context: XcodePluginContext, arguments: [String]) throws {
            let project = context.xcodeProject.directoryURL.appending(path: "\(context.xcodeProject.displayName).xcodeproj")
            let scan = Self.scanArguments(
                arguments,
                buildArguments: [],
                defaults: ["--project", project.path, "--schemes", context.xcodeProject.displayName, "--format", "xcode"]
            )
            let process = Process()
            process.executableURL = try context.tool(named: "lethen").url
            process.currentDirectoryURL = context.xcodeProject.directoryURL
            process.arguments = Array(scan.prefix { $0 != "--" }) + ["--skip-build", "--skip-schemes-validation"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            for line in (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n") {
                Self.report(String(line))
            }

            if process.terminationStatus != 0 {
                Diagnostics.error("lethen exited with status \(process.terminationStatus); build the project in Xcode so its index is current")
            }
        }

        /// Turns a `path:line:column: warning: message` line into an Xcode issue; other lines are printed.
        private static func report(_ line: String) {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let lineNumber = Int(parts[1]), parts[3].trimmingCharacters(in: .whitespaces) == "warning" else {
                print(line)
                return
            }

            Diagnostics.warning(parts[4].trimmingCharacters(in: .whitespaces), file: String(parts[0]), line: lineNumber)
        }
    }
#endif
