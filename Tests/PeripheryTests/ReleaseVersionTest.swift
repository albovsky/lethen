import Shared
import XCTest

final class ReleaseVersionTest: XCTestCase {
    func testReleaseRanksAboveItsOwnPrereleases() throws {
        let release = try XCTUnwrap(ReleaseVersion("3.8.1"))

        for prerelease in ["3.8.1-dev.2", "3.8.1-dev.10", "3.8.1-beta", "3.8.1-rc1", "3.8.1-rc.1"] {
            let prereleaseVersion = try XCTUnwrap(ReleaseVersion(prerelease))
            XCTAssertLessThan(prereleaseVersion, release, prerelease)
        }
    }

    func testNumberedPrereleasesCompareNumerically() throws {
        try XCTAssertLessThan(XCTUnwrap(ReleaseVersion("3.8.1-dev.2")), XCTUnwrap(ReleaseVersion("3.8.1-dev.10")))
        try XCTAssertLessThan(XCTUnwrap(ReleaseVersion("3.8.1-dev.1")), XCTUnwrap(ReleaseVersion("3.8.1-dev.2")))
    }

    func testSemanticVersionPrereleasePrecedence() throws {
        // The ordering example from the Semantic Versioning 2.0.0 specification.
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ]
        let versions = try ordered.map { try XCTUnwrap(ReleaseVersion($0)) }

        for (lower, higher) in zip(versions, versions.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
        }
    }

    func testCoreVersionOrdering() throws {
        try XCTAssertLessThan(XCTUnwrap(ReleaseVersion("3.8.1")), XCTUnwrap(ReleaseVersion("3.9.0-dev.1")))
        try XCTAssertLessThan(XCTUnwrap(ReleaseVersion("3.9.0")), XCTUnwrap(ReleaseVersion("3.10.0")))
        try XCTAssertEqual(XCTUnwrap(ReleaseVersion("3.8")), XCTUnwrap(ReleaseVersion("3.8.0")))
        try XCTAssertEqual(XCTUnwrap(ReleaseVersion("3.8.1+build.5")), XCTUnwrap(ReleaseVersion("3.8.1")))
    }

    func testRejectsNonVersionTags() {
        for tag in ["", "latest", "v3.8.1", "3.8.x", "3.8.1-", "3..1"] {
            XCTAssertNil(ReleaseVersion(tag), tag)
        }
    }

    func testLatestStableReleaseIgnoresPrereleases() {
        let releases: [(tag: String, isPrerelease: Bool)] = [
            ("3.9.0-dev.1", true),
            ("3.8.1", false),
            ("3.8.1-dev.2", true),
            ("3.8.1-rc1", false), // Tagged as a prerelease but not flagged as one on GitHub.
            ("3.8.0", false),
        ]

        XCTAssertEqual(ReleaseVersion.latest(of: releases, includingPrereleases: false)?.tag, "3.8.1")
        XCTAssertNil(ReleaseVersion.latest(of: [("3.8.1-dev.1", true)], includingPrereleases: false))
    }

    func testLatestDevelopmentReleasePrefersNewestVersion() {
        let releases: [(tag: String, isPrerelease: Bool)] = [
            ("3.8.1-dev.2", true),
            ("3.8.1", false),
            ("3.8.1-dev.10", true),
            ("3.8.1-beta", true),
            ("not-a-version", false),
        ]

        XCTAssertEqual(ReleaseVersion.latest(of: releases, includingPrereleases: true)?.tag, "3.8.1")
        XCTAssertEqual(
            ReleaseVersion.latest(of: Array(releases.prefix(1)) + [("3.8.1-dev.10", true)], includingPrereleases: true)?.tag,
            "3.8.1-dev.10"
        )
        XCTAssertNil(ReleaseVersion.latest(of: [], includingPrereleases: true))
    }
}
