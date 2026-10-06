import AppIntents

@available(macOS 15.0, *)
@UnionValue
enum UnionChoice {
    case text(String)
    case number(Int)

    static let caseDisplayRepresentations: [UnionChoice: DisplayRepresentation] = [:]
    static let unusedUnionHelper = 1
}
