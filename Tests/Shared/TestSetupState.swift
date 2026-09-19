/// Captures once-per-class setup failures for XCTest's throwing instance setup.
/// Like the shared source graph, this state requires serial tests within a process.
final class TestSetupState {
    private var error: Error?

    func capture(_ body: () throws -> Void) {
        error = nil
        do { try body() } catch { self.error = error }
    }

    func check() throws {
        if let error { throw error }
    }
}
