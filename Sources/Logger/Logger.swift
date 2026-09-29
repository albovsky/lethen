import Foundation
import Synchronization

#if canImport(os)
    import os
#endif

public enum ANSIColor: String {
    case bold = "\u{001B}[0;1m"
    case red = "\u{001B}[0;31m"
    case boldRed = "\u{001B}[0;1;31m"
    case green = "\u{001B}[0;32m"
    case boldGreen = "\u{001B}[0;1;32m"
    case yellow = "\u{001B}[0;33m"
    case boldYellow = "\u{001B}[0;1;33m"
    case blue = "\u{001B}[0;34m"
    case lightBlue = "\u{001B}[1;34m"
    case magenta = "\u{001B}[0;35m"
    case boldMagenta = "\u{001B}[0;1;35m"
    case cyan = "\u{001B}[0;36m"
    case lightGray = "\u{001B}[0;37m"
    case gray = "\u{001B}[0;1;30m"
}

public enum LoggerColorMode: Sendable {
    case auto
    case always
    case never
}

public struct Logger: Sendable {
    let outputQueue: DispatchQueue
    let quiet: Bool
    let verbose: Bool
    let colorMode: LoggerColorMode
    /// Records how long each interval takes, when a scan reports statistics.
    public let intervalRecorder: IntervalRecorder?

    #if canImport(os)
        let signposter = OSSignposter()
    #endif

    public var isColoredOutputEnabled: Bool {
        switch colorMode {
        case .auto:
            isColorOutputCapable
        case .always:
            true
        case .never:
            false
        }
    }

    public init(
        quiet: Bool,
        verbose: Bool,
        colorMode: LoggerColorMode,
        intervalRecorder: IntervalRecorder? = nil
    ) {
        self.quiet = quiet
        self.verbose = verbose
        self.colorMode = colorMode
        self.intervalRecorder = intervalRecorder
        outputQueue = DispatchQueue(label: "Logger.outputQueue")
    }

    public func colorize(_ text: String, _ color: ANSIColor) -> String {
        guard isColoredOutputEnabled else { return text }

        return "\(color.rawValue)\(text)\u{001B}[0;0m"
    }

    public func contextualized(with context: String) -> ContextualLogger {
        .init(logger: self, context: context)
    }

    public func info(_ text: String, canQuiet: Bool = true) {
        guard !(quiet && canQuiet) else { return }

        log(text, output: stdout)
    }

    public func debug(_ text: String) {
        guard verbose else { return }

        log(text, output: stdout)
    }

    /// Writes progress to standard error so that it never mixes with results on standard output.
    public func progress(_ text: String) {
        guard !quiet else { return }

        log(text, output: stderr)
    }

    /// Writes a note about the results to standard error so that it never mixes with results on
    /// standard output.
    public func note(_ text: String) {
        guard !quiet else { return }

        log(text, output: stderr)
    }

    public func warn(_ text: String, newlinePrefix: Bool = false) {
        guard !quiet else { return }

        if newlinePrefix {
            log("", output: stderr)
        }
        let text = colorize("warning: ", .boldYellow) + text
        log(text, output: stderr)
    }

    // periphery:ignore
    public func error(_ text: String) {
        let text = colorize("error: ", .boldRed) + text
        log(text, output: stderr)
    }

    /// Writes `text` to standard error even in quiet mode, keeping reports the user asked for apart
    /// from results on standard output.
    public func report(_ text: String) {
        log(text, output: stderr)
    }

    public func beginInterval(_ name: StaticString) -> SignpostInterval {
        let start = intervalRecorder.map { _ in ContinuousClock.now }
        #if canImport(os)
            let id = signposter.makeSignpostID()
            let state = signposter.beginInterval(name, id: id)
            return .init(name: name, start: start, state: state)
        #else
            return .init(name: name, start: start)
        #endif
    }

    public func endInterval(_ interval: SignpostInterval) {
        #if canImport(os)
            signposter.endInterval(interval.name, interval.state)
        #endif
        if let intervalRecorder, let start = interval.start {
            intervalRecorder.record(interval.name, duration: ContinuousClock.now - start)
        }
    }

    // MARK: - Private

    func log(_ line: String, output: UnsafeMutablePointer<FILE>) {
        _ = outputQueue.sync { fputs(line + "\n", output) }
    }

    private var isColorOutputCapable: Bool = {
        guard let term = ProcessInfo.processInfo.environment["TERM"],
              term.lowercased() != "dumb",
              isatty(fileno(stdout)) != 0
        else {
            return false
        }

        return true
    }()
}

public struct ContextualLogger: Sendable {
    let logger: Logger
    let context: String

    public func contextualized(with innerContext: String) -> ContextualLogger {
        logger.contextualized(with: "\(context):\(innerContext)")
    }

    public func debug(_ text: String) {
        logger.debug("[\(context)] \(text)")
    }

    public func beginInterval(_ name: StaticString) -> SignpostInterval {
        logger.beginInterval(name)
    }

    public func endInterval(_ interval: SignpostInterval) {
        logger.endInterval(interval)
    }
}

public struct SignpostInterval {
    let name: StaticString
    /// When the interval began, if the logger records interval durations.
    let start: ContinuousClock.Instant?
    #if canImport(os)
        let state: OSSignpostIntervalState
    #endif
}

/// The total time spent in each named interval. Intervals that end more than once, such as one per
/// source graph mutator, accumulate.
public final class IntervalRecorder: Sendable {
    private let totals = Mutex<[String: Duration]>([:])

    public init() {}

    /// The accumulated duration of each interval that has ended, keyed by interval name.
    public var durations: [String: Duration] {
        totals.withLock { $0 }
    }

    func record(_ name: StaticString, duration: Duration) {
        totals.withLock { $0["\(name)", default: .zero] += duration }
    }
}
