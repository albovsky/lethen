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

public enum FixtureReasonRoot {
    public static func run() {
        let repositories: [FixtureReasonRepository] = [FixtureReasonDirectRepository(), FixtureReasonUncalledRepository(), FixtureReasonOtherRepository()]
        for repository in repositories {
            repository.fixtureReasonLoad()
        }
        FixtureReasonDirectRepository().fixtureReasonUpdate(1)
    }
}
