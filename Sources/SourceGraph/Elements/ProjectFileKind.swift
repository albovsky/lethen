public enum ProjectFileKind: CaseIterable {
    case interfaceBuilder
    case infoPlist
    case xcDataModel
    case xcMappingModel
    case swiftSource
    case clangSource

    /// Whether the kind is compiled source, which a synchronized folder contributes only to the
    /// targets that own the folder.
    public var isCompiledSource: Bool {
        self == .swiftSource || self == .clangSource
    }

    public var extensions: [String] {
        switch self {
        case .interfaceBuilder:
            ["xib", "storyboard"]
        case .infoPlist:
            ["plist"]
        case .xcDataModel:
            ["xcdatamodeld"]
        case .xcMappingModel:
            ["xcmappingmodel"]
        case .swiftSource:
            ["swift"]
        case .clangSource:
            // The extensions clang compiles into a unit of its own. Headers have no unit.
            ["c", "cc", "cpp", "cxx", "m", "mm"]
        }
    }
}
