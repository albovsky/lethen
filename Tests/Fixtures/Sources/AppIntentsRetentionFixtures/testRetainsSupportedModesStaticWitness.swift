import AppIntents

@available(macOS 26.0, *)
struct ModesIntent: AppIntent {
    static let title: LocalizedStringResource = "Modes Intent"
    static let supportedModes: IntentModes = .background
    static let unusedModesHelper = 1
    // Used-but-not-compared control: retained by its use, not by name.
    static let usedModesHelper = 1

    func perform() async throws -> some IntentResult {
        _ = Self.usedModesHelper
        return .result()
    }
}
