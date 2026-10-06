import AppIntents

@available(macOS 26.0, *)
struct ModesIntent: AppIntent {
    static let title: LocalizedStringResource = "Modes Intent"
    static let supportedModes: IntentModes = .background
    static let unusedModesHelper = 1

    func perform() async throws -> some IntentResult {
        .result()
    }
}
