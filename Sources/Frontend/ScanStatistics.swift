import Foundation

/// The size of a scanned project, which `--stats` reports with the time spent in each phase.
struct ScanStatistics {
    let sourceFileCount: Int
    /// Lines of the Swift source files that contain code, excluding blank and comment-only lines.
    let lineCount: Int?
    /// Declarations indexed, before analysis.
    let declarationCount: Int
}

/// Renders what `--stats` prints after a scan.
enum ScanStatisticsReport {
    private struct Phase {
        let interval: String
        let label: String
        let isNested: Bool
    }

    /// The reported phases in scan order, named by the logger interval that times each of them.
    private static let phases = [
        Phase(interval: "driver:setup", label: "Setup", isNested: false),
        Phase(interval: "driver:build", label: "Build", isNested: false),
        Phase(interval: "index", label: "Index", isNested: false),
        Phase(interval: "index:plan", label: "Plan", isNested: true),
        Phase(interval: "index:swift:phase:one", label: "Swift phase one", isNested: true),
        Phase(interval: "index:swift:phase:two", label: "Swift phase two", isNested: true),
        Phase(interval: "analyze", label: "Analyze", isNested: false),
        Phase(interval: "result:build", label: "Results", isNested: false),
        Phase(interval: "result:output", label: "Output", isNested: false),
    ]

    private static let labelWidth = 22

    /// The report for the accumulated duration of each logger interval and, when the scan collected
    /// them, the project's statistics. Phases that did not run are left out; the total is the sum
    /// of the top-level phases.
    static func render(durations: [String: Duration], statistics: ScanStatistics?) -> String {
        var lines = ["Scan statistics:"]
        var total = Duration.zero

        for phase in phases {
            guard let duration = durations[phase.interval] else { continue }

            lines.append(row(phase.label, seconds(duration), isNested: phase.isNested))

            if !phase.isNested {
                total += duration
            }
        }

        lines.append(row("Total", seconds(total)))

        if let statistics {
            lines.append(row("Source files", "\(statistics.sourceFileCount)"))

            if let lineCount = statistics.lineCount {
                lines.append(row("Lines of code", "\(lineCount)"))

                let analysis = durations["index", default: .zero] + durations["analyze", default: .zero]
                if analysis > .zero {
                    let linesPerSecond = Int((Double(lineCount) / analysis.seconds).rounded())
                    lines.append(row("Throughput", "\(linesPerSecond) lines/s (index and analyze)"))
                }
            }

            lines.append(row("Declarations", "\(statistics.declarationCount)"))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func row(_ label: String, _ value: String, isNested: Bool = false) -> String {
        let indentedLabel = (isNested ? "    " : "  ") + label
        return indentedLabel.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + value
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.3fs", duration.seconds)
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
