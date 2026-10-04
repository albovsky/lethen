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

        let structure = try AEXMLDocument(xml: Self.xmlData(from: data))
        let elements = filter(structure.root)

        return elements.map {
            AssetReference(absoluteName: $0.string, source: .infoPlist)
        }
    }

    /// A property list as XML: a binary one, which any `.plist` resource may be, is converted first, since the XML parser
    /// cannot read it and one such file would otherwise abort the scan.
    private static func xmlData(from data: Data) throws -> Data {
        guard data.starts(with: Data("bplist".utf8)) else { return data }

        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
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
