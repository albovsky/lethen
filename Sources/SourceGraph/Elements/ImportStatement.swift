import Foundation

public struct ImportStatement {
    public let module: String
    /// The module path as written, `WMF.WMFLogging`; the Swift visitor records only the top-level
    /// module, so for Swift files it equals `module`.
    public let qualifiedModule: String
    public let isTestable: Bool
    public let isExported: Bool
    public let isConditional: Bool
    public let location: Location
    public let commentCommands: [CommentCommand]

    public init(
        module: String,
        qualifiedModule: String? = nil,
        isTestable: Bool,
        isExported: Bool,
        isConditional: Bool,
        location: Location,
        commentCommands: [CommentCommand]
    ) {
        self.module = module
        self.qualifiedModule = qualifiedModule ?? module
        self.isTestable = isTestable
        self.isExported = isExported
        self.isConditional = isConditional
        self.location = location
        self.commentCommands = commentCommands
    }
}
