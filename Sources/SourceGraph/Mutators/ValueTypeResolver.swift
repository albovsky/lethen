/// Finds the struct and class types whose values flow through a set of references, for mutators that
/// model synthesized conformances (equality, encoding) reading every stored property.
enum ValueTypeResolver {
    static func valueTypes(referencedBy references: Set<Reference>, in graph: SourceGraph, visited: inout Set<Declaration>) -> Set<Declaration> {
        var types: Set<Declaration> = []
        for reference in references {
            guard let declaration = graph.declaration(withUsr: reference.usr), visited.insert(declaration).inserted else { continue }

            if declaration.kind == .struct || declaration.kind == .class {
                types.insert(declaration)
            } else if declaration.kind == .functionConstructor, let parent = declaration.parent, parent.kind == .struct || parent.kind == .class {
                types.insert(parent)
            } else if declaration.kind == .functionAccessorGetter, let property = declaration.parent {
                types.formUnion(valueTypes(referencedBy: property.references, in: graph, visited: &visited))
            } else {
                let valueReferences = declaration.references.filter {
                    [.varType, .initializerType, .variableInitFunctionCall, .returnType].contains($0.role)
                }
                types.formUnion(valueTypes(referencedBy: valueReferences, in: graph, visited: &visited))
            }
        }
        return types
    }
}
