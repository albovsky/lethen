import Foundation
import Logger

public protocol SetupGuide {
    func perform() throws -> ProjectKind
    var commandLineOptions: [String] { get }
    var projectKindName: String { get }
}

public enum SetupSelection {
    case all([String])
    case some([String])

    public var selectedValues: [String] {
        switch self {
        case let .all(values), let .some(values):
            values
        }
    }
}

open class SetupGuideHelpers {
    public let logger: Logger

    /// Reads one line of input, or nil once input has ended. Tests script this.
    public var readInput: () -> String? = { readLine(strippingNewline: true) }

    public init(logger: Logger) {
        self.logger = logger
    }

    func display(options: [String]) {
        let maxPaddingCount = String(options.count).count

        for (index, option) in options.enumerated() {
            let paddingCount = maxPaddingCount - String(index + 1).count
            let padding = String(repeating: " ", count: paddingCount)
            print(padding + logger.colorize("\(index + 1) ", .boldGreen) + option)
        }
    }

    public func select(single options: [String]) throws -> String {
        while true {
            display(options: options)
            print(logger.colorize("?", .boldYellow) + " Type the number for the option you wish to select")
            print(logger.colorize("=> ", .bold), terminator: "")
            let input = try readRequiredInput()

            if let choice = Int(input) {
                if let option = options[safe: choice - 1] {
                    return option
                }

                print(logger.colorize("\nInvalid option: \(input)\n", .boldYellow))
            } else {
                print(logger.colorize("\nInvalid input, expected a number.\n", .boldYellow))
            }
        }
    }

    public func select(multiple options: [String]) throws -> SetupSelection {
        let helpMsg = " Delimit choices with a single space, e.g: 1 2 3"

        while true {
            display(options: options)
            print(logger.colorize("?", .boldYellow) + helpMsg)
            print(logger.colorize("=> ", .bold), terminator: "")
            let choices = try readRequiredInput().split(separator: " ", omittingEmptySubsequences: true)
            var selected: [String] = []
            var isValid = true

            for choice in choices {
                if let index = Int(choice), let option = options[safe: index - 1] {
                    selected.append(option)
                } else {
                    print(logger.colorize("\nInvalid option: \(choice)\n", .boldYellow))
                    isValid = false
                    break
                }
            }

            if isValid, !selected.isEmpty {
                return .some(selected)
            }

            if isValid {
                print(logger.colorize("\nInvalid input, expected a number.\n", .boldYellow))
            }
        }
    }

    public func selectBoolean() throws -> Bool {
        while true {
            print(
                "(" + logger.colorize("Y", .boldGreen) + ")es" +
                    "/" +
                    "(" + logger.colorize("N", .boldGreen) + ")o" +
                    logger.colorize("\n=> ", .bold),
                terminator: ""
            )
            let answer = try readRequiredInput().lowercased()

            if ["y", "yes"].contains(answer) {
                return true
            }

            if ["n", "no"].contains(answer) {
                return false
            }

            print(logger.colorize("\nInvalid input, expected 'y' or 'n'.\n", .boldYellow))
        }
    }

    // MARK: - Private

    private func readRequiredInput() throws -> String {
        guard let input = readInput() else {
            print("")
            throw PeripheryError.guidedSetupError(message: "Input ended before a choice was made; the guided setup needs an interactive terminal")
        }

        return input.trimmed
    }
}
