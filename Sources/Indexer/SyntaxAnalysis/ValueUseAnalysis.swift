import Configuration
import SourceGraph
import SyntaxAnalysis

/// Records on each call reference the references its arguments are, and whether a generic type is among
/// the arguments, so a value passed to a call can be followed to what the call does with it.
struct ValueUseAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        let valueUses = ValueUseSyntaxVisitor(locations: file.locationBuilder)
        valueUses.walk(file.syntax)
        for (call, arguments) in valueUses.arguments {
            let values = file.references(at: arguments)
            let hasGenericValueArguments = !arguments.isDisjoint(with: valueUses.genericTypeLocations)
            for reference in file.references(at: call) {
                reference.hasGenericValueArguments = hasGenericValueArguments
                reference.valueArgumentReferences = values
            }
        }
    }
}
