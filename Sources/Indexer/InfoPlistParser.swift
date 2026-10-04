import AEXML
import Foundation
import SourceGraph
import SystemPackage

final class InfoPlistParser {
    /// Keys whose value names a class the system instantiates by name.
    static let classNameKeys = [
        "UISceneClassName", "UISceneDelegateClassName", "NSPrincipalClass",
        "NSExtensionPrincipalClass", "CLKComplicationPrincipalClass", "WKExtensionDelegateClassName",
        "NSDocumentClass",
    ]
    private let path: FilePath

    required init(path: FilePath) {
        self.path = path
    }

    func parse() throws -> [AssetReference] {
        guard let data = FileManager.default.contents(atPath: path.string) else { return [] }

        let structure = try Self.document(from: data)
        let elements = filter(structure.root)

        return elements.map {
            AssetReference(absoluteName: $0.string, source: .infoPlist)
        }
    }

    /// The XML tree of a property list. Any other format a `.plist` resource may have, binary or OpenStep, is converted
    /// first, since the XML parser cannot read it and one such file would otherwise abort the scan. Data that is no
    /// property list at all fails with the XML parser's error.
    private static func document(from data: Data) throws -> AEXMLDocument {
        do {
            return try AEXMLDocument(xml: data)
        } catch {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            else { throw error }

            return try AEXMLDocument(xml: xml)
        }
    }

    // MARK: - Private

    private func filter(_ parent: AEXMLElement) -> [AEXMLElement] {
        var elements: [AEXMLElement] = []

        for (i, child) in parent.children.enumerated() {
            if child.name == "key", Self.classNameKeys.contains(child.string) {
                if let nextElement = parent.children[safe: i + 1] {
                    elements.append(nextElement)
                }
            }

            elements += filter(child)
        }

        return elements
    }
}
