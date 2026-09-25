import Configuration
import Foundation
import Logger
import Shared
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class UpdateChecker {
    private struct Status {
        var didStart = false
        var didFinish = false
    }

    private let logger: Logger
    private let debugLogger: ContextualLogger
    private let configuration: Configuration
    private let urlSession: URLSession
    private let releasesURL: URL
    private var latestVersion: ReleaseVersion?
    private let semaphore: DispatchSemaphore
    private var error: Error?
    private let status = Mutex(Status())

    required init(logger: Logger, configuration: Configuration) {
        self.logger = logger
        debugLogger = logger.contextualized(with: "update-check")
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        urlSession = URLSession(configuration: config)
        // `/releases/latest` is the newest stable release, which is all a stable build is offered. It never returns a
        // prerelease, so development builds read the release list instead: GitHub orders it newest first, and the
        // newest development and stable releases are within its first page.
        releasesURL = if Self.isDevelopmentBuild {
            URL(string: "https://api.github.com/repos/albovsky/lethen/releases?per_page=100")!
        } else {
            URL(string: "https://api.github.com/repos/albovsky/lethen/releases/latest")!
        }
        semaphore = DispatchSemaphore(value: 0)
    }

    deinit {
        // Invalidating while a request is still in flight is unsafe, so only tear down a
        // session we know has settled. On Linux, invalidating a settled session still crashed
        // intermittently on Swift 6.1; that toolchain is no longer supported, and the
        // 15-scan teardown check in CI guards the remaining ones.
        let status = status.withLock { $0 }
        guard !status.didStart || status.didFinish else { return }

        urlSession.invalidateAndCancel()
    }

    private func finish() {
        status.withLock { $0.didFinish = true }
        semaphore.signal()
    }

    func run() {
        // We only perform the update check with xcode format because it may interfere with
        // parsing json and csv.
        guard !configuration.disableUpdateCheck,
              configuration.outputFormat.supportsAuxiliaryOutput else { return }

        var urlRequest = URLRequest(url: releasesURL)
        urlRequest.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let task = urlSession.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                debugLogger.debug("error: \(error.localizedDescription)")
                self.error = error
                finish()
                return
            }

            if (response as? HTTPURLResponse)?.statusCode == 404, !Self.isDevelopmentBuild {
                debugLogger.debug("no stable release is published")
                finish()
                return
            }

            guard let jsonData = data,
                  let releases = Self.releases(fromJSON: jsonData)
            else {
                var json = "N/A"

                if let data, let decoded = String(bytes: data, encoding: .utf8) {
                    json = decoded
                }

                let message = "Failed to identify latest release tag in: \(json)"
                self.error = PeripheryError.updateCheckError(message: message)
                debugLogger.debug(message)
                finish()
                return
            }

            latestVersion = ReleaseVersion.latest(of: releases, includingPrereleases: Self.isDevelopmentBuild)
            finish()
        }

        status.withLock { $0.didStart = true }
        task.resume()
    }

    /// Waits for an in-flight update check to settle.
    ///
    /// The check is started before the scan and almost always completes long before the scan
    /// does, so this returns immediately in practice. It matters when it doesn't: reading
    /// `latestVersion` without waiting races the session's callback, and letting the session
    /// deallocate mid-transfer crashes on Linux.
    func waitForCompletion(timeout: TimeInterval = 5) {
        guard status.withLock({ $0.didStart }) else { return }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            debugLogger.debug("timed out after \(timeout)s waiting for the update check")
        }
    }

    func notifyIfAvailable() {
        guard let latestVersion else { return }

        debugLogger.debug("latest: \(latestVersion)")

        guard let localVersion = Self.localVersion, latestVersion > localVersion else { return }

        logger.info(logger.colorize("\nUpdate Available!", .boldGreen))
        let boldLatestVersion = logger.colorize(latestVersion.tag, .bold)
        let boldLocalVersion = logger.colorize(PeripheryVersion, .bold)
        logger.info("Version \(boldLatestVersion) is now available, you are using version \(boldLocalVersion).")
        logger.info("Release notes: " + logger.colorize("https://github.com/albovsky/lethen/releases/tag/\(latestVersion)", .bold))
        let boldOption = logger.colorize("--disable-update-check", .bold)
        let boldScan = logger.colorize("scan", .bold)
        logger.info("To disable update checks pass the \(boldOption) option to the \(boldScan) command.")
    }

    /// Waits for the check to finish, returning the latest applicable release, or nil when none is published.
    func wait() -> Result<ReleaseVersion?, PeripheryError> {
        let waitResult = semaphore.wait(timeout: .now() + 60)

        if let error = error as? PeripheryError {
            return .failure(error)
        }

        if let error {
            return .failure(.underlyingError(error))
        }

        if waitResult == .timedOut {
            return .failure(PeripheryError.updateCheckError(message: "Timed out while checking for update."))
        }

        return .success(latestVersion)
    }

    static let localVersion = ReleaseVersion(PeripheryVersion)

    /// A development build is offered newer development releases; a stable build is offered only stable releases.
    static let isDevelopmentBuild = localVersion?.isPrerelease ?? true

    /// Published releases from either a release list or a single release object, excluding drafts.
    private static func releases(fromJSON data: Data) -> [(tag: String, isPrerelease: Bool)]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }

        let objects: [[String: Any]]
        if let list = json as? [[String: Any]] {
            objects = list
        } else if let object = json as? [String: Any], object["tag_name"] != nil {
            objects = [object]
        } else {
            return nil
        }

        return objects
            .filter { $0["draft"] as? Bool != true }
            .compactMap { object in
                guard let tag = object["tag_name"] as? String else { return nil }

                return (tag, object["prerelease"] as? Bool == true)
            }
    }
}
