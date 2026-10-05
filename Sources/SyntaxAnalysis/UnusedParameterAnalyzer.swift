import Foundation
import SourceGraph
import SwiftSyntax
import SystemPackage

public final class UnusedParameterAnalyzer {
    private enum UsageType {
        case used
        case unused
        case shadowed
    }

    public init() {}

    public func analyze(file: SourceFile, syntax: SourceFileSyntax, locationConverter: SourceLocationConverter, parseProtocols: Bool) -> [Function: Set<Parameter>] {
        analyzeEveryFunction(file: file, syntax: syntax, locationConverter: locationConverter, parseProtocols: parseProtocols)
            .filter { !$0.value.isEmpty }
    }

    /// Like `analyze`, but also returns the functions whose parameters are all used, so a caller can tell that
    /// a copy of a function uses a parameter another copy leaves unused.
    public func analyzeEveryFunction(file: SourceFile, syntax: SourceFileSyntax, locationConverter: SourceLocationConverter, parseProtocols: Bool) -> [Function: Set<Parameter>] {
        let functions = UnusedParameterParser.parse(
            file: file,
            syntax: syntax,
            locationConverter: locationConverter,
            parseProtocols: parseProtocols
        )

        return functions.reduce(into: [Function: Set<Parameter>]()) { result, function in
            result[function] = analyze(function: function)
        }
    }

    func analyze(function: Function) -> Set<Parameter> {
        Set(unusedParams(in: function))
    }

    // MARK: - Private

    private func unusedParams(in function: Function) -> [Parameter] {
        guard !function.attributes.contains(where: { $0.name == "IBAction" }) else { return [] }

        return function.parameters.filter { !isParam($0, usedIn: function) }
    }

    private func isParam(_ param: Parameter, usedIn function: Function) -> Bool {
        if case .wildcard = param.name {
            // Params named '_' are explicitly not intended for use, ignore them.
            return true
        }

        if isParam(param, usedForSpecializationIn: function) {
            return true
        }

        if isFunctionFatalErrorOnly(function) {
            return true
        }

        if isFunctionUnavailable(function) {
            return true
        }

        return isParam(param, usedIn: function.items)
    }

    private func isFunctionUnavailable(_ function: Function) -> Bool {
        function.attributes.contains { $0.name == "available" && $0.arguments == "*, unavailable" }
    }

    private func isFunctionFatalErrorOnly(_ function: Function) -> Bool {
        guard let codeBlockList = function.items.first as? GenericItem,
              codeBlockList.node.is(CodeBlockItemListSyntax.self),
              codeBlockList.items.count == 1,
              let funcCallExpr = codeBlockList.items.first as? GenericItem,
              funcCallExpr.node.is(FunctionCallExprSyntax.self),
              let identifier = funcCallExpr.items.first as? Identifier
        else { return false }

        return identifier.name == "fatalError"
    }

    private func isParam(_ param: Parameter, usedIn items: [Item]) -> Bool {
        for item in items {
            switch usage(of: param, in: item) {
            case .used:
                return true
            case .shadowed:
                return false
            case .unused:
                break
            }
        }

        return false
    }

    private func isParam(_ param: Parameter, usedIn item: Item) -> Bool {
        switch usage(of: param, in: item) {
        case .used:
            true
        case .shadowed, .unused:
            false
        }
    }

    private func usage(of param: Parameter, in item: Item) -> UsageType {
        switch item {
        case let item as Variable:
            // First check if the param is used in the assignment expression.
            if isParam(param, usedIn: item.items) {
                return .used
            }

            // Next check if the variable shadows the param.
            if item.names.contains(param.name.text) {
                return .shadowed
            }

            return .unused
        case let item as Closure:
            if item.params.contains(param.name.text) {
                return .shadowed
            }

            if isParam(param, usedIn: item.items) {
                return .used
            }
        case let item as Identifier:
            return item.name == param.name.text ? .used : .unused
        case let item as GenericItem where item.node.is(LabeledExprListSyntax.self): // function call arguments
            for item in item.items where isParam(param, usedIn: item) {
                return .used
            }

            return .unused
        default:
            if isParam(param, usedIn: item.items) {
                return .used
            }
        }

        return .unused
    }

    /// A metatype parameter such as `_ type: T.Type = T.self` selects a generic type at the call
    /// site, so its value is not expected to be read.
    private func isParam(_ param: Parameter, usedForSpecializationIn function: Function) -> Bool {
        guard let baseTypeNames = param.metatypeBaseTypeNames else { return false }

        return baseTypeNames.contains { function.genericParameters.contains($0) }
    }
}
