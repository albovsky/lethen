import Foundation
import IndexStore
import Logger
import Shared

/// Identifies one record of one store: a header's record is shared by every unit that includes it.
struct RecordKey: Hashable {
    let store: ObjectIdentifier
    let name: String
}

/// Which module (or submodule) declares each C and Objective-C symbol, read from the module units
/// clang writes for a module it builds, and how those modules depend on each other.
///
/// An `@import` leaves no occurrence in the index, so whether a file needs one can only be told from
/// the symbols the file uses. A use is a reference to a USR; the module unit of the imported module
/// lists the record of each of its headers, tagged with the submodule that header belongs to
/// (`WMF.WMFLogging`), and those records declare the same USRs. Joining the two names the submodule
/// each used symbol came from.
///
/// System modules are left out: a module that re-exports Foundation must not make every file that uses
/// Foundation appear to need it.
struct ClangModuleSymbolMap {
    /// The top-level names of the non-system modules whose module units the stores hold. A module with
    /// no unit, as every module is in a SwiftPM build, cannot be checked.
    private(set) var modulesWithUnits: Set<String> = []
    /// The non-system modules each module imports, by top-level name.
    private var dependencies: [String: Set<String>] = [:]
    /// The submodule names that declare each USR.
    private var modulesByUSR: [String: Set<String>] = [:]

    /// Reads the modules `importedModules` name and every module they depend on, since a module
    /// usually re-exports what it imports.
    init(stores: [IndexStore], importedModules: Set<String>, logger: ContextualLogger) throws {
        var moduleUnits: [(store: IndexStore, unit: UnitReader, module: String)] = []

        for store in stores {
            for unit in store.units where unit.isModule && !unit.isSystem {
                let module = Self.topLevel(unit.moduleName)
                guard !module.isEmpty else { continue }

                moduleUnits.append((store, unit, module))
                modulesWithUnits.insert(module)
                unit.forEach(dependency: { dependency in
                    let imported = Self.topLevel(dependency.moduleName)
                    guard dependency.kind == .unit, !dependency.isSystem, !imported.isEmpty, imported != module else { return }

                    dependencies[module, default: []].insert(imported)
                })
            }
        }

        var needed = importedModules
        for module in importedModules {
            needed.formUnion(transitiveDependencies(of: module))
        }

        var jobs: [RecordKey: Job] = [:]
        for (store, unit, module) in moduleUnits where needed.contains(module) {
            unit.forEach(dependency: { dependency in
                guard dependency.kind == .record, !dependency.isSystem else { return }

                let key = RecordKey(store: ObjectIdentifier(store), name: dependency.name)
                let name = dependency.moduleName.isEmpty ? unit.moduleName : dependency.moduleName
                jobs[key, default: Job(store: store, name: dependency.name, modules: [])].modules.insert(name)
            })
        }

        let declarations = try JobPool(jobs: Array(jobs.values)).flatMap { job -> [(usr: String, modules: Set<String>)] in
            let reader = try RecordReader(indexStore: job.store, recordName: job.name)
            var usrs: Set<String> = []
            reader.forEach(occurrence: { occurrence in
                if !occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                    usrs.insert(occurrence.symbol.usr)
                }
            })
            return usrs.map { ($0, job.modules) }
        }

        for (usr, modules) in declarations {
            modulesByUSR[usr, default: []].formUnion(modules)
        }

        logger.debug("Mapped \(modulesByUSR.count) symbols of \(needed.intersection(modulesWithUnits).count) modules from \(moduleUnits.count) module units")
    }

    /// The submodule names that declare any of the USRs.
    func modules(declaring usrs: Set<String>) -> Set<String> {
        usrs.reduce(into: Set<String>()) { result, usr in
            if let modules = modulesByUSR[usr] {
                result.formUnion(modules)
            }
        }
    }

    /// The non-system modules the module imports directly or through other modules, by top-level name.
    func transitiveDependencies(of module: String) -> Set<String> {
        var seen: Set<String> = []
        var pending = Array(dependencies[module] ?? [])
        while let next = pending.popLast() {
            guard next != module, seen.insert(next).inserted else { continue }

            pending.append(contentsOf: dependencies[next] ?? [])
        }
        return seen
    }

    static func topLevel(_ module: String) -> String {
        String(module.prefix { $0 != "." })
    }

    // MARK: - Private

    private struct Job {
        let store: IndexStore
        let name: String
        var modules: Set<String>
    }
}
