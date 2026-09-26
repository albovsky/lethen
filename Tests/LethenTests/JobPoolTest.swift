import Shared
import Synchronization
import XCTest

final class JobPoolTest: XCTestCase {
    private struct JobError: Error {
        let job: Int
    }

    func testForEachRunsEveryJob() throws {
        let seen = Mutex<Set<Int>>([])
        try JobPool(jobs: Array(0 ..< 64)).forEach { job in
            seen.withLock { _ = $0.insert(job) }
        }
        XCTAssertEqual(seen.withLock { $0 }, Set(0 ..< 64))
    }

    func testForEachRethrowsAnErrorThrownByConcurrentJobs() {
        XCTAssertThrowsError(try JobPool(jobs: Array(0 ..< 64)).forEach { job in
            if job.isMultiple(of: 2) {
                throw JobError(job: job)
            }
        }) { error in
            guard let error = error as? JobError else {
                return XCTFail("Expected a job error, got: \(error)")
            }

            XCTAssertTrue(error.job.isMultiple(of: 2))
        }
    }

    func testFlatMapCollectsEveryResult() throws {
        let results = try JobPool(jobs: Array(1 ... 32)).flatMap { [$0, $0 * 100] }
        XCTAssertEqual(Set(results), Set((1 ... 32).flatMap { [$0, $0 * 100] }))
    }

    func testFlatMapRethrowsAnErrorThrownByConcurrentJobs() {
        XCTAssertThrowsError(try JobPool(jobs: Array(1 ... 32)).flatMap { job -> [Int] in
            if job.isMultiple(of: 3) {
                throw JobError(job: job)
            }
            return [job]
        }) { error in
            guard let error = error as? JobError else {
                return XCTFail("Expected a job error, got: \(error)")
            }

            XCTAssertTrue(error.job.isMultiple(of: 3))
        }
    }
}
