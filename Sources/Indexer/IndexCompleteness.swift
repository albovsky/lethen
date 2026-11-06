import Shared
import SystemPackage

/// Whether the index has a unit for every source file of a target it built. A compilation-cache hit compiles nothing
/// and so writes no unit, which would leave the scan without that file's references.
public enum IndexCompleteness {
    /// A target of the project: its module names and its collectable compiled files, lexically normalized.
    public struct Target {
        public let moduleNames: Set<String>
        public let sourceFiles: Set<FilePath>

        public init(moduleNames: Set<String>, sourceFiles: Set<FilePath>) {
            self.moduleNames = moduleNames
            self.sourceFiles = sourceFiles
        }
    }

    /// The collectable compiled files of each target whose unit belongs to it.
    ///
    /// A file compiled into several targets has a unit for each target that built it, named by module, so a
    /// unit counts for a target unless the file's modules show another target of the project compiled it
    /// instead. A unit whose module matches no target, such as a clang one, counts for every target that
    /// compiles the file, which errs toward scanned.
    public static func indexedFiles<ID: Hashable>(
        byTarget targets: [ID: Target],
        indexedModules: [FilePath: Set<String>]
    ) -> [ID: Set<FilePath>] {
        let modules = normalized(indexedModules)
        func isIndexed(_ file: FilePath, for id: ID, target: Target) -> Bool {
            guard let fileModules = modules[file] else { return false }

            let matched = fileModules.intersection(target.moduleNames)
            guard matched.isEmpty else {
                // A unit whose module two targets share cannot say which of them built the file, so it proves
                // neither; each of them still counts as scanned through a file only it compiles. Units of
                // distinct modules each belong to their own target.
                return !targets.contains {
                    $0.key != id && !matched.isDisjoint(with: $0.value.moduleNames) && $0.value.sourceFiles.contains(file)
                }
            }

            let builtByAnother = targets.contains {
                $0.key != id && !fileModules.isDisjoint(with: $0.value.moduleNames) && $0.value.sourceFiles.contains(file)
            }
            return !builtByAnother
        }

        return Dictionary(uniqueKeysWithValues: targets.map { id, target in
            (id, target.sourceFiles.filter { isIndexed($0, for: id, target: target) })
        })
    }

    /// The files of targets that have a unit of their own but lack one for a file they compile, sorted by path.
    ///
    /// A target counts as built only when a unit of one of its own modules names a file it compiles. A target with no
    /// such unit is left alone, since a target the schemes do not build cannot be told from one the cache skipped,
    /// and a unit of a module no target claims, such as a clang one for a file two targets share, cannot say which
    /// target built it. A file of a built target without a unit of its own is missing when no unit names it
    /// at all, or when every module that does belongs to another target and none to this one, as when this target's
    /// compile of a file it shares with a built target was a cache hit. A unit whose module this target shares
    /// with another cannot say which of them built the file, and a unit of a module no target claims, such as a
    /// clang one, may be this target's, so both count as present.
    public static func missingFiles(
        byTarget targets: [some Hashable: Target],
        indexedModules: [FilePath: Set<String>]
    ) -> [FilePath] {
        let modules = normalized(indexedModules)
        let indexed = indexedFiles(byTarget: targets, indexedModules: indexedModules)
        let claimed = targets.values.reduce(into: Set<String>()) { $0.formUnion($1.moduleNames) }
        var missing: Set<FilePath> = []
        for (id, target) in targets {
            let own = indexed[id, default: []]
            let built = own.contains { !modules[$0, default: []].isDisjoint(with: target.moduleNames) }
            guard built else { continue }

            for file in target.sourceFiles.subtracting(own) {
                guard let fileModules = modules[file] else {
                    missing.insert(file)
                    continue
                }

                if fileModules.isDisjoint(with: target.moduleNames), fileModules.isSubset(of: claimed) {
                    missing.insert(file)
                }
            }
        }
        return missing.sorted { $0.string < $1.string }
    }

    /// Throws `LethenError.incompleteIndexStore` for `store` when `missingFiles` is not empty.
    public static func check(
        byTarget targets: [some Hashable: Target],
        indexedModules: [FilePath: Set<String>],
        store: FilePath
    ) throws {
        let missing = missingFiles(byTarget: targets, indexedModules: indexedModules)
        guard !missing.isEmpty else { return }

        throw LethenError.incompleteIndexStore(path: store.string, missingFiles: missing.map(\.string))
    }

    // MARK: - Private

    private static func normalized(_ indexedModules: [FilePath: Set<String>]) -> [FilePath: Set<String>] {
        Dictionary(indexedModules.map { ($0.key.lexicallyNormalized(), $0.value) }, uniquingKeysWith: { $0.union($1) })
    }
}
