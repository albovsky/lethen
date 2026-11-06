import Foundation
import Observation

// Recall canaries. Each declaration named `dead…` is unused and must stay reported, beside a live twin that is used.
// A retention rule that retains too much hides one of them while precision stays perfect.

actor FixtureCanaryActor {
    func liveActorMethod() {}
    func deadActorMethod() {}
}

@available(macOS 14.0, *)
@Observable
final class FixtureCanaryLiveState {
    var liveObserved = 0
}

@available(macOS 14.0, *)
@Observable
final class FixtureCanaryDeadState {
    var deadObserved = 0
}

protocol FixtureCanaryLiveProtocol {
    func liveRequirement()
}

// Conformed to, but its requirement is never called.
protocol FixtureCanaryDeadProtocol {
    func deadRequirement()
}

struct FixtureCanaryWitness: FixtureCanaryLiveProtocol, FixtureCanaryDeadProtocol {
    func liveRequirement() {}
    func deadRequirement() {}
}

struct FixtureCanaryRecord {
    var liveField: Int
    // Assigned, never read.
    var deadAssignOnly: Int
}

public final class FixtureCanaryPublicAPI {
    public init() {}

    public func api() -> Int {
        liveHelper()
    }

    private func liveHelper() -> Int {
        FixtureCanaryRecord(liveField: 1, deadAssignOnly: 2).liveField
    }

    // Private inside a public type: `--retain-public` does not reach it.
    private func deadHelper() {}
}

// Used only by a function that is itself unused.
func fixtureCanaryDeadCallee() {}

func fixtureCanaryDeadCaller() {
    fixtureCanaryDeadCallee()
}

func fixtureCanaryLiveCallee() {}

public func fixtureCanaryRoot() async {
    fixtureCanaryLiveCallee()
    await FixtureCanaryActor().liveActorMethod()
    if #available(macOS 14.0, *) {
        _ = FixtureCanaryLiveState().liveObserved
    }
    let witness: any FixtureCanaryLiveProtocol = FixtureCanaryWitness()
    witness.liveRequirement()
    _ = FixtureCanaryWitness() as any FixtureCanaryDeadProtocol
}

#if canImport(SwiftUI)
    import SwiftUI

    struct FixtureCanaryLiveView: View {
        var body: some View {
            Text("live")
        }
    }

    struct FixtureCanaryDeadView: View {
        var body: some View {
            Text("dead")
        }
    }

    public func fixtureCanaryShowView() -> some View {
        FixtureCanaryLiveView()
    }
#endif

#if canImport(ObjectiveC)
    final class FixtureCanaryObjc: NSObject {
        @objc func liveObjc() {}
        // No Objective-C caller.
        @objc func deadObjc() {}
    }

    public func fixtureCanaryCallObjc() {
        FixtureCanaryObjc().liveObjc()
    }
#endif
