import Configuration
import Foundation
import Logger
import ProjectDrivers
import Shared
import SystemPackage

final class Project {
    let kind: ProjectKind

    private let configuration: Configuration
    private let shell: Shell
    private let logger: Logger

    convenience init(
        configuration: Configuration,
        shell: Shell,
        logger: Logger
    ) throws {
        var kind: ProjectKind?

        if let path = configuration.project {
            kind = .xcode(projectPath: path)
        } else if let path = configuration.genericProjectConfig {
            kind = .generic(genericProjectConfig: path)
        } else if BazelProjectDriver.isSupported, configuration.bazel {
            kind = .bazel
        } else {
            switch try ProjectDetector(directory: .current).detect() {
            case .spm:
                kind = .spm
            case let .xcode(path):
                kind = .xcode(projectPath: path)
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    logger.info("Scanning \(path.lastComponent?.string ?? path.string) found in the current directory (pass '--project' to choose another).")
                }
            case .bazel:
                kind = .bazel
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    logger.info("Scanning the Bazel module in the current directory (pass '--bazel' to make this explicit).")
                }
            case nil:
                kind = nil
            }
        }

        guard let kind else {
            throw LethenError.usageError("Failed to identify project in the current directory. Run lethen where the Package.swift, the .xcworkspace or .xcodeproj, or the MODULE.bazel is, or pass '--project', '--bazel' or '--generic-project-config'.")
        }

        self.init(kind: kind, configuration: configuration, shell: shell, logger: logger)
    }

    init(
        kind: ProjectKind,
        configuration: Configuration,
        shell: Shell,
        logger: Logger
    ) {
        self.kind = kind
        self.configuration = configuration
        self.shell = shell
        self.logger = logger
    }

    func driver() throws -> ProjectDriver {
        if !configuration.configurations.isEmpty {
            switch kind {
            case .spm, .xcode:
                break
            case .bazel, .generic:
                throw LethenError.usageError("--configurations is supported for Swift packages and Xcode projects only.")
            }
        }

        switch kind {
        case let .xcode(projectPath):
            #if canImport(XcodeSupport)
                return try XcodeProjectDriver(
                    projectPath: projectPath,
                    configuration: configuration,
                    shell: shell,
                    logger: logger
                )
            #else
                throw LethenError.usageError("Xcode projects are only supported on macOS. On this platform, scan a Swift package, or use '--bazel' or '--generic-project-config'.")
            #endif
        case .spm:
            return try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
        case .bazel:
            return BazelProjectDriver(
                configuration: configuration,
                shell: shell,
                logger: logger
            )
        case let .generic(genericProjectConfig):
            return try GenericProjectDriver(
                genericProjectConfig: genericProjectConfig,
                configuration: configuration
            )
        }
    }
}
