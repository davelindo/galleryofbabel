import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UpdateChecker {
    private static let owner = "davelindo"
    private static let repo = "galleryofbabel"
    private static let cacheTTL: TimeInterval = 6 * 3600

    struct UpdateState: Codable {
        let schemaVersion: Int
        let lastCheckedAt: Date
        let latestHash: String
    }

    static func scheduleIfNeeded(command: String) {
        guard shouldCheck(command: command) else { return }
        Task.detached(priority: .utility) {
            await checkAndWarn()
        }
    }

    private static func shouldCheck(command: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["GOBX_NO_UPDATE_CHECK"] == "1" { return false }
        if BuildInfo.versionHash == "unknown" { return false }
        if command.hasPrefix("bench-") { return false }
        return isInteractiveOutput()
    }

    private static func isInteractiveOutput() -> Bool {
        return isatty(fileno(stderr)) != 0 || Terminal.isInteractiveStdout()
    }

    private static func checkAndWarn() async {
        let local = BuildInfo.versionHash
        guard local != "unknown" else { return }
        let now = Date()

        if let cached = loadState(), now.timeIntervalSince(cached.lastCheckedAt) < cacheTTL {
            if cached.latestHash != local {
                warnIfNeeded(local: local, remote: cached.latestHash)
            }
            return
        }

        guard let remote = await fetchRemoteMainHash() else {
            if let cached = loadState(), now.timeIntervalSince(cached.lastCheckedAt) < cacheTTL {
                if cached.latestHash != local {
                    warnIfNeeded(local: local, remote: cached.latestHash)
                }
            }
            return
        }

        saveState(UpdateState(schemaVersion: 1, lastCheckedAt: now, latestHash: remote))
        if remote != local {
            warnIfNeeded(local: local, remote: remote)
        }
    }

    private static func warnIfNeeded(local: String, remote: String) {
        guard isInteractiveOutput() else { return }
        let msg = "Update available: main@\(remote) (current \(local)). Run `git pull` and rebuild.\n"
        if let data = msg.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private static func fetchRemoteMainHash() async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/main")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(BuildInfo.userAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 4.0
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sha = obj["sha"] as? String
            else {
                return nil
            }
            return String(sha.prefix(12))
        } catch {
            return nil
        }
    }

    private static func loadState() -> UpdateState? {
        CalibrationSupport.loadJSON(UpdateState.self, from: GobxPaths.updateStateURL)
    }

    private static func saveState(_ state: UpdateState) {
        try? CalibrationSupport.saveJSON(state, to: GobxPaths.updateStateURL)
    }
}
