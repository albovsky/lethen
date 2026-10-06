import AppIntents

struct StaticWitnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Static Witness Intent"
    static let description = IntentDescription("Describes the intent")
    static let unusedHelper = 1
    // Collision control: `defaultQuery` is declared by AppEntity, not AppIntent.
    static let defaultQuery = 1
    static var preview = "preview"

    func perform() async throws -> some IntentResult {
        _ = Self.preview
        return .result()
    }
}
