import Configuration
import Foundation
import Logger
import ProjectDrivers
import Shared
import SystemPackage

final class SPMProjectSetupGuide: SetupGuideHelpers, SetupGuide {
    private let configuration: Configuration
    private let shell: Shell

    static func detect(configuration: Configuration, shell: Shell, logger: Logger) -> Self? {
        guard SPM.isSupported else { return nil }

        return Self(configuration: configuration, shell: shell, logger: logger)
    }

    required init(configuration: Configuration, shell: Shell, logger: Logger) {
        self.configuration = configuration
        self.shell = shell
        super.init(logger: logger)
    }

    var projectKindName: String {
        "Swift Package"
    }

    func perform() throws -> ProjectKind {
        .spm
    }

    var commandLineOptions: [String] {
        []
    }

    var suggestedCommandLineOptions: [String] {
        []
    }

    private(set) lazy var detectedRetainPublic: DetectedAnswer<Bool>? = {
        do {
            let description = try SPM.Package(configuration: configuration, shell: shell, logger: logger).load()
            return Self.retainPublicAnswer(products: description.products ?? [])
        } catch {
            logger.debug("Could not read the package's products, asking instead: \(error)")
            return nil
        }
    }()

    /// Libraries are imported by code outside the package, so their public declarations count as used;
    /// executables are not, so theirs are reported. A package with both, or neither, is asked about.
    static func retainPublicAnswer(products: [PackageProduct]) -> DetectedAnswer<Bool>? {
        let kinds = Set(products.map(\.kind))

        switch (kinds.contains("library"), kinds.contains("executable")) {
        case (true, false):
            return DetectedAnswer(value: true, reason: "the package's products are libraries, which other code imports")
        case (false, true):
            return DetectedAnswer(value: false, reason: "the package's products are executables, which no other code imports")
        default:
            return nil
        }
    }
}
