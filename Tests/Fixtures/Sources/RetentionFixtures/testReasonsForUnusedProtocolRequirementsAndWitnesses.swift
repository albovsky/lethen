import Foundation

protocol FixtureReasonRepository {
    func fixtureReasonLoad()
    func fixtureReasonUpdate(_ value: Int)
}

struct FixtureReasonDirectRepository: FixtureReasonRepository {
    func fixtureReasonLoad() {}
    func fixtureReasonUpdate(_: Int) {}
}

struct FixtureReasonUncalledRepository: FixtureReasonRepository {
    func fixtureReasonLoad() {}
    func fixtureReasonUpdate(_ value: Int) {
        fixtureReasonHelper(value)
    }

    private func fixtureReasonHelper(_: Int) {}
}

struct FixtureReasonOtherRepository: FixtureReasonRepository {
    func fixtureReasonLoad() {}
    func fixtureReasonUpdate(_: Int) {}
}

protocol FixtureReasonFirstProtocol {
    func fixtureReasonShared()
}

protocol FixtureReasonSecondProtocol {
    func fixtureReasonShared()
}

struct FixtureReasonBothProtocols: FixtureReasonFirstProtocol, FixtureReasonSecondProtocol {
    func fixtureReasonShared() {}
}

protocol FixtureReasonRetainedProtocol {
    func fixtureReasonRetained()
}

public struct FixtureReasonPublicConformer: FixtureReasonRetainedProtocol {
    // Retained by --retain-public, so used, but nothing calls it.
    public func fixtureReasonRetained() {}
}

public enum FixtureReasonRoot {
    public static func run() {
        let repositories: [FixtureReasonRepository] = [FixtureReasonDirectRepository(), FixtureReasonUncalledRepository(), FixtureReasonOtherRepository()]
        for repository in repositories {
            repository.fixtureReasonLoad()
        }
        FixtureReasonDirectRepository().fixtureReasonUpdate(1)
        let second: FixtureReasonSecondProtocol = FixtureReasonBothProtocols()
        second.fixtureReasonShared()
        // Both protocols are used as types, so their requirements are judged on their own.
        let first: FixtureReasonFirstProtocol = FixtureReasonBothProtocols()
        let retained: FixtureReasonRetainedProtocol = FixtureReasonPublicConformer()
        _ = (first, retained)
    }
}
