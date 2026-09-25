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
    private var latestVersion: String?
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
        // `/releases/latest` never returns a prerelease, so it cannot see development releases.
        releasesURL = URL(string: "https://api.github.com/repos/albovsky/lethen/releases?per_page=30")!
        semaphore = DispatchSemaphore(value: 0)
    }

    deinit {
        // Invalidating a URLSession while a request is still in flight crashes inside
        // FoundationNetworking on Linux (SIGILL). An abandoned session is reclaimed when the
        // process exits, so only tear it down once we know nothing is in flight.
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

        let task = urlSession.dataTask(with: urlRequest) { [weak self] data, _, error in
            guard let self else { return }

            if let error {
                debugLogger.debug("error: \(error.localizedDescription)")
                self.error = error
                finish()
                return
            }

            guard let jsonData = data,
                  let releases = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]]
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

            latestVersion = Self.latestVersion(in: releases, includingPrereleases: Self.isPrerelease(PeripheryVersion))
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

        guard latestVersion.isVersion(greaterThan: PeripheryVersion) else { return }

        logger.info(logger.colorize("\nUpdate Available!", .boldGreen))
        let boldLatestVersion = logger.colorize(latestVersion, .bold)
        let boldLocalVersion = logger.colorize(PeripheryVersion, .bold)
        logger.info("Version \(boldLatestVersion) is now available, you are using version \(boldLocalVersion).")
        logger.info("Release notes: " + logger.colorize("https://github.com/albovsky/lethen/releases/tag/\(latestVersion)", .bold))
        let boldOption = logger.colorize("--disable-update-check", .bold)
        let boldScan = logger.colorize("scan", .bold)
        logger.info("To disable update checks pass the \(boldOption) option to the \(boldScan) command.")
    }

    /// Waits for the check to finish, returning the latest applicable release, or nil when none is published.
    func wait() -> Result<String?, PeripheryError> {
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

    /// A development build is offered newer development releases; a stable build is offered only stable releases.
    static func latestVersion(in releases: [[String: Any]], includingPrereleases: Bool) -> String? {
        releases
            .filter { $0["draft"] as? Bool != true }
            .filter { includingPrereleases || $0["prerelease"] as? Bool != true }
            .compactMap { $0["tag_name"] as? String }
            .max { $1.isVersion(greaterThan: $0) }
    }

    static func isPrerelease(_ version: String) -> Bool {
        version.contains("-")
    }
}
