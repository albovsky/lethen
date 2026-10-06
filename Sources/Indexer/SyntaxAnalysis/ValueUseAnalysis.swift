import Configuration
import SourceGraph
import SyntaxAnalysis

/// Records what a call does with its values: the references its arguments are (and whether a generic type is
/// among them), the arguments by label, and the generic arguments a specialization names; and, on declarations,
/// the facts about parameter types, accessor bodies and initialized constants that value-flow retainers read.
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
        for (call, list) in valueUses.argumentLists {
            let arguments = list.map { argument in
                ValueArgument(label: argument.label, references: file.references(at: argument.origins))
            }
            for reference in file.references(at: call) {
                reference.valueArguments = arguments
            }
        }
        for (call, types) in valueUses.resultTypes {
            let resolved = file.references(at: types)
            for reference in file.references(at: call) {
                reference.resultTypeReferences = resolved
            }
        }
        for location in valueUses.specializationArgumentLocations {
            for reference in file.references(at: location) {
                reference.isGenericSpecializationArgument = true
            }
        }
        for (location, arguments) in valueUses.specializationArguments {
            let resolved = arguments.map { file.references(at: $0) }
            for reference in file.references(at: location) {
                reference.genericArguments = resolved
            }
        }
        file.graph.withLock { _ in
            for declaration in file.declarations {
                if let names = valueUses.parameterTypeNames[declaration.location] {
                    declaration.parameterTypeNames = names
                }
                if let names = valueUses.returnTypeNames[declaration.location] {
                    declaration.returnTypeNames = names
                }
                if valueUses.accessorBodyLocations.contains(declaration.location) {
                    declaration.hasAccessorBody = true
                }
                if valueUses.initializedConstantLocations.contains(declaration.location) {
                    declaration.isInitializedConstant = true
                }
            }
        }
    }
}
