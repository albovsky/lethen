import Configuration
import Foundation
import Logger
import Shared
import SystemPackage

public final class BazelProjectDriver: ProjectDriver {
    public static var isSupported: Bool {
        FilePath("MODULE.bazel").exists || FilePath("WORKSPACE").exists
    }

    private static let topLevelKinds = [
        // rules_apple, iOS
        "ios_app_clip",
        "ios_application",
        "ios_extension",
        "ios_imessage_application",
        "ios_imessage_extension",
        "ios_sticker_pack_extension",
        "ios_ui_test",
        "ios_unit_test",

        // rules_apple, tvOS
        "tvos_application",
        "tvos_extension",
        "tvos_ui_test",
        "tvos_unit_test",

        // rules_apple, watchOS
        "watchos_application",
        "watchos_extension",
        "watchos_ui_test",
        "watchos_unit_test",

        // rules_apple, visionOS
        "visionos_application",
        "visionos_ui_test",
        "visionos_unit_test",

        // rules_apple, macOS
        "macos_application",
        "macos_command_line_application",
        "macos_extension",
        "macos_kernel_extension",
        "macos_quick_look_plugin",
        "macos_spotlight_importer",
        "macos_xpc_service",
        "macos_ui_test",
        "macos_unit_test",

        // rules_swift
        "swift_binary",
        "swift_test",
        "swift_compiler_plugin",
    ]

    /// The environment variable that tells `bazel/generated.bzl` where the generated package is.
    static let generatedDirectoryVariable = "LETHEN_BAZEL_GENERATED_DIR"
    /// A target that only `bazel/generated.bzl` of this lethen version creates, in a package of its own.
    static let generatedRepositoryMarker = "@periphery_generated//lethen_scratch:v1"

    /// The scan target. Its package exists only in a `periphery` module as new as this binary, so even when the build
    /// arguments select another module (`--override_module`, a `--config`), `bazel run` cannot reach an older
    /// module's scan package, which comes from `/var/tmp`.
    static let generatedScanTarget = "@periphery_generated//lethen_scan:scan"

    private let configuration: Configuration
    private let shell: Shell
    private let logger: Logger
    private let fileStatus: (FilePath) throws -> FileStatus?

    private lazy var contextLogger: ContextualLogger = logger.contextualized(with: "bazel")

    public convenience init(
        configuration: Configuration,
        shell: Shell,
        logger: Logger
    ) {
        self.init(configuration: configuration, shell: shell, logger: logger, fileStatus: FileStatus.read)
    }

    init(
        configuration: Configuration,
        shell: Shell,
        logger: Logger,
        fileStatus: @escaping (FilePath) throws -> FileStatus?
    ) {
        self.configuration = configuration
        self.shell = shell
        self.logger = logger
        self.fileStatus = fileStatus
    }

    public func build() throws {
        // The scan runs inside `bazel run`, and its exit status is the scan's result.
        try exit(buildAndScan())
    }

    /// Generates the scan target, then builds and runs it, returning the scan's exit status.
    func buildAndScan() throws -> Int32 {
        try rejectReservedRepositoryEnvironment()
        warnIfPeripheryModuleIsNotOverridden()
        let outputPath = try generatedDirectory()
        // Another scan of the same workspace shares the directory, so it waits until this one's `bazel run` ends.
        let lock = try lockGeneratedDirectory(outputPath)
        defer { close(lock) }
        try preparePrivateDirectory(outputPath)

        let configPath = outputPath.appending("periphery.yml")
        configuration.bazel = false // Generic project mode is used for the actual scan.
        try configuration.asYaml().write(to: configPath.url, atomically: true, encoding: .utf8)
        contextLogger.debug("Configuration written to \(configPath)")

        let buildPath = outputPath.appending("BUILD.bazel")
        let deps = try queryTargets().joined(separator: ",\n")
        let globalIndexStoreValue = configuration.bazelIndexStore.map {
            Self.starlarkString($0.makeAbsolute().string)
        } ?? "None"
        let buildFileContents = """
        load("@periphery//bazel:rules.bzl", "scan")

        scan(
          name = "scan",
          testonly = True,
          config = \(Self.starlarkString(configPath.string)),
          global_indexstore = \(globalIndexStoreValue),
          deps = [
            \(deps)
          ],
        )
        """

        try buildFileContents.write(to: buildPath.url, atomically: true, encoding: .utf8)
        contextLogger.debug("Build file written to \(buildPath)")

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = logger.colorize("*", .boldGreen)
            logger.info("\(asterisk) Building...")
        }

        let repositoryEnvironment = "--repo_env=\(Self.generatedDirectoryVariable)=\(outputPath)"
        try verifyGeneratedRepositoryVersion(repositoryEnvironment: repositoryEnvironment)

        let checkVisibility = configuration.bazelCheckVisibility ? "true" : "false"
        var arguments = [
            "bazel",
            "run",
            "--check_visibility=\(checkVisibility)",
            "--ui_event_filters=-info,-debug,-warning",
        ]
        arguments.append(contentsOf: configuration.buildArguments)
        // After the build arguments, because Bazel uses the last `--repo_env` for a variable.
        arguments.append(repositoryEnvironment)
        arguments.append(Self.generatedScanTarget)

        // The actual scan is performed by Bazel.
        return try shell.execStatus(arguments)
    }

    /// Whether a root `MODULE.bazel` resolves the `periphery` module from source rather than from a registry.
    ///
    /// The generated scan target runs `@periphery//:periphery`. Without a non-registry override, Bazel fetches
    /// that module from the Bazel Central Registry, which serves upstream Periphery rather than lethen.
    static func overridesPeripheryModule(_ moduleFile: String) -> Bool {
        let comments = #/#[^\n]*/#
        let contents = moduleFile.replacing(comments, with: "")
        // Starlark strings may use either quote style.
        let isPeripheryModuleItself = #/\bmodule\s*\([^)]*\bname\s*=\s*["']periphery["']/#
        let sourceOverride = #/\b(?:git|local_path|archive)_override\s*\([^)]*\bmodule_name\s*=\s*["']periphery["']/#

        return contents.contains(isPeripheryModuleItself) || contents.contains(sourceOverride)
    }

    /// `value` as a Starlark string literal, so paths and labels with quotes or backslashes stay one exact string in
    /// the generated BUILD file.
    static func starlarkString(_ value: String) -> String {
        var literal = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            default: literal.unicodeScalars.append(character)
            }
        }
        return literal + "\""
    }

    // MARK: - Private

    /// `<output_base>/lethen_generated`. Bazel's output base belongs to this user and this workspace, so the path
    /// is stable across scans, which keeps Bazel from refetching the generated repository, and scans of different
    /// workspaces do not overwrite each other's files.
    ///
    /// The build arguments are not passed: they are options for `bazel run`, while the output base depends only on
    /// startup options, which Bazel reads from the same `.bazelrc` files for both commands.
    private func generatedDirectory() throws -> FilePath {
        let command = ["bazel", "info", "output_base"]
        // Only the final newline is removed, as one scalar: an output base may end in a space, a tab or even a
        // carriage return, which Swift would otherwise join with the newline into one character.
        var scalars = try shell.exec(command).unicodeScalars
        if scalars.last == "\n" {
            scalars.removeLast()
        }
        let outputBase = String(scalars)
        guard FilePath(outputBase).isAbsolute, !outputBase.contains("\n") else {
            throw LethenError.shellCommandFailed(
                cmd: command,
                status: 0,
                output: "Expected an absolute path, got: \(outputBase)"
            )
        }

        return FilePath(outputBase).appending("lethen_generated")
    }

    /// Takes an exclusive lock on `lethen_generated.lock` beside `directory`, waiting while another scan holds it, and
    /// returns its descriptor. The generated files are one pair, read by `bazel run` well after they are written, so a
    /// second scan of the same workspace must not replace them until the first scan is done. The descriptor is closed
    /// on exec, so Bazel's server never inherits the lock.
    private func lockGeneratedDirectory(_ directory: FilePath) throws -> Int32 {
        let lockPath = directory.removingLastComponent().appending("lethen_generated.lock")
        let descriptor = open(lockPath.string, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LethenError.unsafeDirectory(path: lockPath, reason: "it cannot be opened: \(String(cString: strerror(errno)))")
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK, configuration.outputFormat.supportsAuxiliaryOutput {
                logger.info("Waiting for another lethen scan of this Bazel workspace to finish...")
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    let reason = String(cString: strerror(errno))
                    close(descriptor)
                    throw LethenError.unsafeDirectory(path: lockPath, reason: "it cannot be locked: \(reason)")
                }
            }
        }

        return descriptor
    }

    /// Build arguments must not point the generated repository anywhere else, through its variable or by overriding
    /// the repository itself: the version check and the scan would then read different packages.
    private func rejectReservedRepositoryEnvironment() throws {
        let variable = Self.generatedDirectoryVariable
        let arguments = configuration.buildArguments

        /// The value `option` sets, written as `--option=value` or as `--option value`.
        func values(of option: String) -> [String] {
            arguments.indices.compactMap { index in
                if arguments[index].hasPrefix("\(option)=") {
                    return String(arguments[index].dropFirst(option.count + 1))
                }
                return arguments[index] == option && arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
        }

        if values(of: "--repo_env").contains(where: { $0 == variable || $0.hasPrefix("\(variable)=") }) {
            throw LethenError.usageError(
                "\(variable) is set by lethen for each Bazel scan; remove '--repo_env=\(variable)' from the build arguments."
            )
        }

        // The generated repository's apparent name, or a canonical name ending in it, such as
        // `+generated+periphery_generated`.
        let overridesGeneratedRepository = values(of: "--override_repository").contains { value in
            let name = value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? value
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "@")).hasSuffix("periphery_generated")
        }
        if overridesGeneratedRepository {
            throw LethenError.usageError(
                "The periphery_generated repository is created by lethen for each Bazel scan; remove its '--override_repository' from the build arguments."
            )
        }
    }

    /// Checks that the `periphery` module creates the generated repository the way this binary expects.
    ///
    /// An older module ignores the private directory and symlinks the scan package from `/var/tmp/periphery_bazel`,
    /// where another user can put one, so the scan must not run with it. The query loads only the marker package,
    /// never the generated scan package, and passes the same `--repo_env` as `bazel run`, so Bazel fetches the
    /// repository once for both.
    private func verifyGeneratedRepositoryVersion(repositoryEnvironment: String) throws {
        do {
            try shell.exec(["bazel", "query", repositoryEnvironment, Self.generatedRepositoryMarker])
        } catch let LethenError.shellCommandFailed(_, _, output) {
            throw LethenError.usageError(
                "The 'periphery' Bazel module is older than this lethen binary: its generated repository has no " +
                    "'\(Self.generatedRepositoryMarker)' target, so it would read the scan package from the shared " +
                    "/var/tmp/periphery_bazel directory. Update the 'periphery' override in MODULE.bazel to this " +
                    "lethen version ('lethen scan --setup' prints it). Bazel reported:\n\(output)"
            )
        }
    }

    /// Creates `path` readable and writable only by this user, or checks that an existing `path` is such a directory,
    /// so that nobody else can replace the generated files that the scan builds and runs.
    private func preparePrivateDirectory(_ path: FilePath) throws {
        if try fileStatus(path) == nil, mkdir(path.string, 0o700) != 0, errno != EEXIST {
            throw LethenError.unsafeDirectory(path: path, reason: String(cString: strerror(errno)))
        }

        // Whatever is at the path now is checked without following a symbolic link, including a directory that
        // appeared after the first check.
        guard let status = try fileStatus(path) else {
            throw LethenError.unsafeDirectory(path: path, reason: "it disappeared after it was created")
        }
        guard !status.isSymbolicLink else {
            throw LethenError.unsafeDirectory(path: path, reason: "it is a symbolic link")
        }
        guard status.isDirectory else {
            throw LethenError.unsafeDirectory(path: path, reason: "it is not a directory")
        }

        let userID = geteuid()
        guard status.ownerID == userID else {
            throw LethenError.unsafeDirectory(
                path: path,
                reason: "it is owned by user ID \(status.ownerID), not by the current user (\(userID))"
            )
        }
        guard !status.isWritableByOthers else {
            let permissions = String(status.mode & 0o7777, radix: 8)
            throw LethenError.unsafeDirectory(path: path, reason: "other users can write to it (mode \(permissions))")
        }

        // Nobody else could have changed its contents, but they could read them, including the serialized build
        // arguments in `periphery.yml`, so the directory is made private again.
        if status.mode & 0o077 != 0, chmod(path.string, 0o700) != 0 {
            throw LethenError.unsafeDirectory(path: path, reason: "its permissions cannot be restricted: \(String(cString: strerror(errno)))")
        }
    }

    private func warnIfPeripheryModuleIsNotOverridden() {
        guard let moduleFile = try? String(contentsOfFile: "MODULE.bazel", encoding: .utf8),
              !Self.overridesPeripheryModule(moduleFile)
        else { return }

        logger.warn(
            "MODULE.bazel does not override the 'periphery' module, so Bazel resolves it from the registry, " +
                "which serves upstream Periphery. The scan will not include lethen's fixes. " +
                "Run 'lethen scan --setup' for a MODULE.bazel snippet that uses lethen."
        )
    }

    private func queryTargets() throws -> [String] {
        try shell
            .exec(["bazel", "query", query])
            .split(separator: "\n")
            .map { Self.starlarkString("@@\($0)") }
    }

    private var query: String {
        if let bazelQuery = configuration.bazelQuery {
            return bazelQuery
        }

        let kinds = Self.topLevelKinds.joined(separator: "|")
        let query = "filter('^//.*', kind('(\(kinds)) rule', deps(//...)))"

        if let pattern = configuration.bazelFilter {
            return "filter('\(pattern)', \(query))"
        }

        return query
    }
}

/// What `lstat` reports about a path: its type and permissions, and its owner.
struct FileStatus {
    private static let typeMask: mode_t = 0o170000
    private static let directoryType: mode_t = 0o040000
    private static let symbolicLinkType: mode_t = 0o120000

    let mode: mode_t
    let ownerID: uid_t

    var isDirectory: Bool {
        mode & Self.typeMask == Self.directoryType
    }

    var isSymbolicLink: Bool {
        mode & Self.typeMask == Self.symbolicLinkType
    }

    var isWritableByOthers: Bool {
        mode & 0o022 != 0
    }

    /// The status of `path` itself, not of what a symbolic link points to, or nil when nothing exists at `path`.
    static func read(_ path: FilePath) throws -> FileStatus? {
        var info = stat()
        guard lstat(path.string, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return FileStatus(mode: info.st_mode, ownerID: info.st_uid)
    }
}
