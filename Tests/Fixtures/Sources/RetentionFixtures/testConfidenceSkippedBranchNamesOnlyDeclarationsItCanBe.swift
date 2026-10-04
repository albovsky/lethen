import Foundation

public class FixtureLabels5 {
    func show(title: String) { titleHelper() }
    func show(message: String) { messageHelper() }
    func show(title: String, animated: Bool = true) {}
    func show(_ value: Int) {}
    func titleHelper() {}
    func messageHelper() {}
    func run(completion: () -> Void) {}
    func pick(by: Int) {}
    func pick(of: Int) {}
    func lookup(for key: String) {}
    func lookup(of key: String) {}
    // Called in the clause this build compiled and named with other labels in the skipped one: used.
    func taken(title: String) {}
    func neverNamed(title: String) {}
    // Spelled with the labels it declares, but in the clause this build compiled.
    func calledOnlyHere(title: String) {}

    public func use() {
        taken(title: "x")
        #if !os(Windows)
            calledOnlyHere(title: "x")
        #endif
        #if os(Windows)
            show(title: "x")
            run { }
            _ = #selector(self.pick)
            lookup(for: "x")
            taken(message: "x")
            show(message: "x", extra: 1)
            neverNamed(other: 1)
            let value = 1
            show(value)
        #endif
    }
}

func freeShow5(title: String) {}
func freeShow5(message: String) {}

public func fixtureFree5() {
    #if os(Windows)
        freeShow5(title: "x")
    #endif
}

public class FixtureInit5 {
    init(label: Int) {}
    convenience init(other: Int) { self.init(label: other) }
    convenience init(unrelated: Int) { self.init(label: unrelated) }

    public static func use() {
        _ = FixtureInit5(label: 1)
        #if os(Windows)
            // A call of another type's initializer, with labels this class's initializers do not have.
            _ = String.init(data: Data(), encoding: .utf8)
            _ = FixtureInit5.init(other: 1)
        #endif
    }
}
