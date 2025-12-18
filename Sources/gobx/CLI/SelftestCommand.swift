import Dispatch
import Foundation

enum SelftestCommand {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx selftest [--golden <path>] [--write-golden] [--count <n>] [--limit <n>] [--tolerance <x>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var goldenPath: String? = nil
        var writeGolden = false
        var count = 1024
        var limit: Int? = nil
        var tolerance: Double = 0.0
        var verbose = false

        while let a = parser.pop() {
            switch a {
            case "--golden":
                goldenPath = try parser.requireValue(for: "--golden")
            case "--write-golden":
                writeGolden = true
            case "--count":
                count = max(1, try parser.requireInt(for: "--count"))
            case "--limit":
                limit = max(0, try parser.requireInt(for: "--limit"))
            case "--tolerance":
                tolerance = max(0.0, try parser.requireDouble(for: "--tolerance"))
            case "--verbose":
                verbose = true
            default:
                throw parser.unknown(a)
            }
        }

        let url: URL = {
            if let p = goldenPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(p))
            }
            if writeGolden {
                return defaultSelftestGoldenURL()
            }
            if let bundled = Bundle.module.url(forResource: "selftest_golden", withExtension: "json") {
                return bundled
            }
            return defaultSelftestGoldenURL()
        }()

        if writeGolden {
            let seeds = makeSelftestSeeds(count: count)
            let scorer = Scorer(size: 128)

            var entries = [SelftestGolden.Entry]()
            entries.reserveCapacity(seeds.count)

            let startNs = DispatchTime.now().uptimeNanoseconds
            for s in seeds {
                let r = scorer.score(seed: s)
                entries.append(SelftestGolden.Entry(seed: s, totalScoreBits: r.totalScore.bitPattern))
            }
            let dt = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9

            let golden = SelftestGolden(version: 1, createdAt: Date(), entries: entries)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(golden)

            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            print("Wrote selftest golden (\(entries.count) seeds) to \(url.path) in \(String(format: "%.2fs", dt))")
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            throw GobxError.usage("Golden file not found: \(url.path)\nRun: gobx selftest --write-golden")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let golden = try dec.decode(SelftestGolden.self, from: data)
        var entries = golden.entries
        if let l = limit {
            entries = Array(entries.prefix(max(0, l)))
        }
        if entries.isEmpty {
            throw GobxError.usage("Golden file has no entries: \(url.path)")
        }

        let scorer = Scorer(size: 128)
        var failures = 0
        var shown = 0
        let maxShown = verbose ? Int.max : 20

        let startNs = DispatchTime.now().uptimeNanoseconds
        for e in entries {
            let expected = Double(bitPattern: e.totalScoreBits)
            let actual = scorer.score(seed: e.seed).totalScore

            let ok: Bool
            if tolerance == 0 {
                ok = actual.bitPattern == e.totalScoreBits
            } else {
                ok = abs(actual - expected) <= tolerance
            }

            if !ok {
                failures += 1
                if shown < maxShown {
                    shown += 1
                    let diff = actual - expected
                    print("Mismatch seed=\(e.seed) expected=\(String(format: "%.12f", expected)) actual=\(String(format: "%.12f", actual)) diff=\(String(format: "%.12g", diff))")
                }
            }
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9

        if failures == 0 {
            let rate = Double(entries.count) / max(1e-9, dt)
            print("Selftest OK: \(entries.count) seeds in \(String(format: "%.2fs", dt)) (\(String(format: "%.0f", rate))/s)")
            return
        }

        FileHandle.standardError.write(("Selftest FAILED: \(failures)/\(entries.count) mismatches (golden=\(url.path))\n").data(using: .utf8)!)
        exit(1)
    }
}
