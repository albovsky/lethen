import Foundation
@testable import TestShared
import XCTest

/// Corpus verdicts are the precision evidence; keep them well-formed and the published scorecard current.
final class CorpusAdjudicationTest: XCTestCase {
    private struct Manifest: Decodable {
        let name: String
    }

    private struct Adjudications: Decodable {
        let project: String
        let sampleRate: Double
        let adjudications: [Entry]
    }

    private struct Entry: Decodable {
        let path: String
        let line: Int
        let column: Int
        let kind: String
        let name: String
        let verdict: String
        let note: String
        let adjudicatedOn: String
        let lethenCommit: String
        let retired: String?

        var key: String { "\(path):\(line):\(column) \(kind) \(name)" }
    }

    private enum Cell: Decodable {
        case string(String)
        case int(Int)
        case strings([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = try .strings(container.decode([String].self))
            }
        }

        var description: String {
            switch self {
            case let .string(value): value
            case let .int(value): String(value)
            case let .strings(value): value.joined(separator: ",")
            }
        }
    }

    func testAdjudicationsNameReportedFindingsOnce() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try JSONDecoder().decode([Manifest].self, from: Data(contentsOf: ProjectRootPath.appending("corpus/projects.json").url))
        XCTAssertFalse(manifest.isEmpty)

        for project in manifest.map(\.name) {
            let file = try decoder.decode(Adjudications.self, from: Data(contentsOf: ProjectRootPath.appending("corpus/adjudications/\(project).json").url))
            let rows = try JSONDecoder().decode([[Cell]].self, from: Data(contentsOf: ProjectRootPath.appending("corpus/expected/\(project).json").url))
            let reported = Set(rows.map { row in "\(row[0].description):\(row[1].description):\(row[2].description) \(row[3].description) \(row[4].description)" })

            XCTAssertEqual(file.project, project)
            XCTAssertTrue(file.sampleRate > 0 && file.sampleRate <= 1, "\(project) sample_rate must be in (0, 1]")
            XCTAssertEqual(Set(file.adjudications.map(\.key)).count, file.adjudications.count, "\(project) adjudicates a finding twice")
            for entry in file.adjudications {
                XCTAssertTrue(["TP", "FP", "UNSURE"].contains(entry.verdict), "\(entry.key) has verdict \(entry.verdict)")
                XCTAssertFalse(entry.note.isEmpty, "\(entry.key) has no evidence")
                XCTAssertTrue(entry.adjudicatedOn.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil, "\(entry.key) has no ISO date")
                XCTAssertTrue(entry.lethenCommit.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil, "\(entry.key) has no Lethen commit")
                if entry.retired == nil {
                    XCTAssertTrue(reported.contains(entry.key), "\(entry.key) is not in corpus/expected/\(project).json; mark its verdict retired")
                } else {
                    XCTAssertFalse(reported.contains(entry.key), "\(entry.key) is marked retired but is still reported")
                }
            }
        }
    }

    #if os(macOS)
        // The scripts need Python 3, which macOS runners have and the Linux Swift images do not
        // promise; the required Swift 6.4 / Xcode 27 job runs these.

        func testScriptsPassTheirSelfCheck() throws {
            let (status, output) = try python(["corpus/test_precision.py"])
            XCTAssertEqual(status, 0, output)
        }

        func testCommittedScorecardIsCurrent() throws {
            let (status, output) = try python(["corpus/precision.py", "--verify"])
            XCTAssertEqual(status, 0, output)
        }

        private func python(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + arguments
            process.currentDirectoryURL = ProjectRootPath.url
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try (process.terminationStatus, XCTUnwrap(String(bytes: data, encoding: .utf8)))
        }
    #endif
}
