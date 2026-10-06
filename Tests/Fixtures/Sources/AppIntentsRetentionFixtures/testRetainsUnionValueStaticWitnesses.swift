import AppIntents

@available(macOS 27.0, *)
@UnionValue
enum UnionChoice {
    case text(String)
    case number(Int)

    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = representations(count: usedUnionHelper)
    static let unusedUnionHelper = 1
    // Used-but-not-compared control: retained by its use, not by name.
    static let usedUnionHelper = 0

    static func representations(count: Int) -> [Cases: DisplayRepresentation] {
        _ = count
        return [:]
    }
}
