import AppIntents

// `TransientAppEntity` refines `AppEntity`, so the index records only the refinement as the conformed protocol.
@available(macOS 14.0, *)
struct RefinedEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Refined Entity"
    static let unusedEntityHelper = 1
    // Collision control: `title` is declared by AppIntent, not by an entity.
    static let title = 1

    init() {}

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Refined")
    }
}
