import Configuration
import SourceGraph

/// Applies `periphery:ignore` comment commands: retains the declaration, its unused parameters and everything
/// nested in it, and records that the command did it. `periphery:ignore:all` does so for every declaration of
/// the file. It runs after the analyses that add declarations, such as unused parameters.
struct CommentCommandAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        if file.fileCommands.contains(.ignoreAll) {
            commandIgnore(file.declarations, kind: .file, in: file)
        } else {
            for decl in file.declarations where decl.commentCommands.contains(.ignore) {
                commandIgnore([decl], kind: .declaration, in: file)
            }
        }
    }

    private func commandIgnore(_ decls: [Declaration], kind: CommandIgnoreKind, in file: IndexedFile) {
        for decl in decls {
            file.graph.withLock { graph in
                graph.markRetained(decl)
                decl.unusedParameters.forEach { graph.markRetained($0) }

                graph.markCommandIgnored(decl, kind: kind)
                decl.unusedParameters.forEach { graph.markCommandIgnored($0, kind: kind) }
            }
            commandIgnore(Array(decl.declarations), kind: kind, in: file)
        }
    }
}
