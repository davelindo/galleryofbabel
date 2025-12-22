import Foundation

enum BuildInfo {
    static let versionHash: String = {
        if let envHash = envVersionHash() { return envHash }
        if let gitHash = gitHashFromRepo() { return gitHash }
        return "unknown"
    }()

    static let userAgent: String = "gobx/\(versionHash)"

    private static func envVersionHash() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["GOBX_VERSION_HASH"], let h = normalizeHash(v) { return h }
        if let v = env["GIT_COMMIT"], let h = normalizeHash(v) { return h }
        if let v = env["GITHUB_SHA"], let h = normalizeHash(v) { return h }
        return nil
    }

    private static func gitHashFromRepo() -> String? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        for _ in 0..<10 {
            let gitDir = url.appendingPathComponent(".git", isDirectory: true)
            if fm.fileExists(atPath: gitDir.path) {
                return readHashFromGitDir(gitDir)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private static func readHashFromGitDir(_ gitDir: URL) -> String? {
        let headURL = gitDir.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: ") {
            let ref = String(trimmed.dropFirst(5))
            let refPath = gitDir.appendingPathComponent(ref)
            if let refHash = try? String(contentsOf: refPath, encoding: .utf8) {
                return normalizeHash(refHash)
            }
            let packedURL = gitDir.appendingPathComponent("packed-refs")
            if let packed = try? String(contentsOf: packedURL, encoding: .utf8) {
                for line in packed.split(separator: "\n") {
                    if line.hasPrefix("#") || line.hasPrefix("^") { continue }
                    let parts = line.split(separator: " ")
                    if parts.count == 2 && parts[1] == ref {
                        return normalizeHash(String(parts[0]))
                    }
                }
            }
            return nil
        }
        return normalizeHash(trimmed)
    }

    private static func normalizeHash(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return nil }
        guard trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(trimmed.prefix(12))
    }
}
