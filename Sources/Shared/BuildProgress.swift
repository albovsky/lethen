import Foundation
import Logger
import Synchronization

/// Shows that a project build is still running.
///
/// Build output is written to standard error, never standard output, so machine-readable scan results stay valid.
public struct BuildProgress: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Nothing is written.
        case silent
        /// A periodic line with the elapsed time and the latest `[step/total]` progress SwiftPM reported.
        case heartbeat
        /// Every line the build writes.
        case fullOutput
    }

    /// `--quiet` silences progress. `--verbose` shows the full build output. Otherwise, formats that print
    /// auxiliary output show a heartbeat, and machine-readable formats show nothing.
    public static func mode(quiet: Bool, verbose: Bool, supportsAuxiliaryOutput: Bool) -> Mode {
        if quiet { return .silent }
        if verbose { return .fullOutput }
        return supportsAuxiliaryOutput ? .heartbeat : .silent
    }

    private let mode: Mode
    private let interval: Duration
    private let write: @Sendable (String) -> Void

    public init(mode: Mode, interval: Duration = .seconds(15), write: @escaping @Sendable (String) -> Void) {
        self.mode = mode
        self.interval = interval
        self.write = write
    }

    public init(mode: Mode, logger: Logger) {
        self.init(mode: mode, write: { logger.progress($0) })
    }

    /// Runs `build`, passing it the handler that receives each line of build output.
    @discardableResult
    public func run<Result>(_ build: (_ onOutputLine: @escaping @Sendable (String) -> Void) throws -> Result) rethrows -> Result {
        switch mode {
        case .silent:
            return try build { _ in }
        case .fullOutput:
            return try build(write)
        case .heartbeat:
            let heartbeat = Heartbeat(interval: interval, write: write)
            defer { heartbeat.stop() }
            return try build { heartbeat.observe($0) }
        }
    }
}

private final class Heartbeat: Sendable {
    private struct State {
        var latestStep: String?
        var isStopped = false
    }

    private let state = Mutex(State())
    private let timer: DispatchSourceTimer

    init(interval: Duration, write: @escaping @Sendable (String) -> Void) {
        let start = ContinuousClock.now
        let intervalNanoseconds = Int(interval / .nanoseconds(1))
        timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(
            deadline: .now() + .nanoseconds(intervalNanoseconds),
            repeating: .nanoseconds(intervalNanoseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.beat(elapsed: ContinuousClock.now - start, write: write)
        }
        timer.resume()
    }

    /// Records the `[step/total]` prefix of a SwiftPM progress line. The native build system writes `[3/10]`,
    /// Swift Build writes `[3 / 10]`.
    func observe(_ line: String) {
        guard let match = line.prefixMatch(of: #/\[\s*(\d+)\s*/\s*(\d+)\s*\]/#) else { return }

        let step = "\(match.output.1)/\(match.output.2)"
        state.withLock { $0.latestStep = step }
    }

    private func beat(elapsed: Duration, write: @Sendable (String) -> Void) {
        state.withLock { state in
            guard !state.isStopped else { return }

            let step = state.latestStep.map { ", step \($0)" } ?? ""
            write("  Still building (\(elapsed.components.seconds)s elapsed\(step))")
        }
    }

    func stop() {
        state.withLock { $0.isStopped = true }
        timer.cancel()
    }
}
