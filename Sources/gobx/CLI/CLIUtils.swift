import Foundation

func parseSeed(_ s: String) throws -> UInt64 {
    if let v = UInt64(s) { return v }
    throw GobxError.invalidSeed(s)
}

func defaultSelftestGoldenURL() -> URL {
    let fm = FileManager.default
    let rel = "Sources/gobx/Resources/selftest_golden.json"

    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let fromCwd = cwd.appendingPathComponent(rel)
    if fm.fileExists(atPath: fromCwd.path) { return fromCwd }

    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent(rel)
        if fm.fileExists(atPath: candidate.path) { return candidate }
        if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { break }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }

    return fromCwd
}
