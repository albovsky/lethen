/// Captures once-per-class setup failures for XCTest's throwing instance setup.
/// Like the shared source graph, this state requires serial tests within a process.
/// Setup runs as a chain of captures; once one fails, later captures are skipped so
/// that dependent steps do not run against missing state, and `check` reports the
/// first failure.
final class TestSetupState {
    private var error: Error?

    func capture(_ body: () throws -> Void) {
        guard error == nil else { return }

        do { try body() } catch { self.error = error }
    }

    func check() throws {
        if let error {
            throw error
        }
    }
}
