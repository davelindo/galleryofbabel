import Dispatch
import Foundation
import Metal

struct MetalCalibrationKey: Codable, Equatable {
    let schemaVersion: Int
    let cpuScorerVersion: Int
    let metalScorerVersion: Int
    let proxyConfig: ProxyConfig
    let osVersion: String
    let hwModel: String?
    let cpuBrand: String?
    let arch: String
    let gpuName: String
    let gpuRegistryID: UInt64
}

struct MetalCalibration: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let hardwareHash: String
    let key: MetalCalibrationKey
    let batchUsed: Int
    let scanCount: Int
    let topCount: Int
    let verifiedCount: Int
    let quantile: Double
    let recommendedMargin: Double
    let scoreShiftQuantile: Double
    let recommendedScoreShift: Double
    let maxUnderestimation: Double
    let meanDelta: Double
    let meanUnderestimation: Double
    let meanOverestimation: Double
    let p95Underestimation: Double
    let p99Underestimation: Double
    let p999Underestimation: Double
    let p90Overestimation: Double
    let p95Overestimation: Double
    let p99Overestimation: Double
}

private func defaultMetalCalibrationURL() -> URL {
    GobxPaths.metalCalibrationURL
}

private func loadMetalCalibration(from url: URL) -> MetalCalibration? {
    CalibrationSupport.loadJSON(MetalCalibration.self, from: url)
}

private func saveMetalCalibration(_ calibration: MetalCalibration, to url: URL) throws {
    try CalibrationSupport.saveJSON(calibration, to: url)
}

private func currentMetalCalibrationKey() throws -> MetalCalibrationKey {
    let dev = try CalibrationSupport.metalDevice()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let hwModel = CalibrationSupport.sysctlString("hw.model")
    let cpuBrand = CalibrationSupport.sysctlString("machdep.cpu.brand_string")
    let arch = CalibrationSupport.archString()
    let proxyConfig = ProxyConfig.metalDefault(imageSize: 128)
    return MetalCalibrationKey(
        schemaVersion: 2,
        cpuScorerVersion: Scorer.scorerVersion,
        metalScorerVersion: MetalPyramidScorer.scorerVersion,
        proxyConfig: proxyConfig,
        osVersion: osVersion,
        hwModel: hwModel,
        cpuBrand: cpuBrand,
        arch: arch,
        gpuName: dev.name,
        gpuRegistryID: dev.registryID
    )
}

private func hardwareHash(for key: MetalCalibrationKey) throws -> String {
    try CalibrationSupport.hardwareHash(for: key)
}

enum CalibrateMetal {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx calibrate-metal [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--inflight <n>] [--out <path>] [--force]"
        var parser = ArgumentParser(args: args, usage: usage)

        var batch = 64
        var scanCount = 2_000_000
        var topCount = 4096
        var quantile = 0.999
        var inflight = 2
        var force = false
        var outPath: String? = nil

        while let a = parser.pop() {
            switch a {
            case "--batch":
                batch = max(1, try parser.requireInt(for: "--batch"))
            case "--scan":
                scanCount = max(batch, try parser.requireInt(for: "--scan"))
            case "--top":
                topCount = max(256, try parser.requireInt(for: "--top"))
            case "--quantile":
                quantile = min(1.0, max(0.5, try parser.requireDouble(for: "--quantile")))
            case "--inflight":
                inflight = max(1, try parser.requireInt(for: "--inflight"))
            case "--force":
                force = true
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            default:
                throw parser.unknown(a)
            }
        }

        let key = try currentMetalCalibrationKey()
        let hash = try hardwareHash(for: key)

        let url: URL = {
            if let outPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(outPath))
            }
            return defaultMetalCalibrationURL()
        }()

        if !force, let existing = loadMetalCalibration(from: url), existing.key == key, existing.hardwareHash == hash {
            print("Loaded existing Metal calibration: margin=\(String(format: "%.6f", existing.recommendedMargin)) q=\(String(format: "%.4f", existing.quantile)) verified=\(existing.verifiedCount) hash=\(existing.hardwareHash.prefix(12)) file=\(url.path)")
            return
        }

        print("Calibrating Metal vs CPU (batch=\(batch) scan=\(scanCount) top=\(topCount) q=\(String(format: "%.4f", quantile)) inflight=\(inflight))")
        print("Hardware hash: \(hash)")

        let metal = try MetalPyramidScorer(batchSize: batch, inflight: inflight)

        var heap = MinHeap<SeedScoreEntry>()
        heap.reserveCapacity(min(topCount, 16384))

        let v2Min: UInt64 = 0x1_0000_0000
        let v2MaxExclusive: UInt64 = 0x20_0000_0000_0000
        let baseSeed = normalizeV2Seed(UInt64.random(in: v2Min..<v2MaxExclusive))
        var seed = baseSeed
        let scanAligned = scanCount - (scanCount % batch)
        let scanFinal = max(batch, scanAligned)
        var processed = 0
        var enqueued = 0
        let startNs = DispatchTime.now().uptimeNanoseconds
        var lastPrintNs = startNs

        var seeds = [UInt64](repeating: 0, count: batch)
        var pending: [GPUJob] = []
        pending.reserveCapacity(inflight)
        while enqueued < scanFinal || !pending.isEmpty {
            while enqueued < scanFinal && pending.count < inflight {
                let n = min(batch, scanFinal - enqueued)
                for i in 0..<n {
                    seeds[i] = seed
                    seed = nextV2Seed(seed, by: 1)
                }
                if n < batch {
                    for i in n..<batch { seeds[i] = 0 }
                }
                let job = seeds.withUnsafeBufferPointer { ptr in
                    metal.enqueue(seeds: ptr, count: n)
                }
                pending.append(job)
                enqueued += n
            }

            if pending.isEmpty { break }
            let job = pending.removeFirst()
            try metal.withCompletedJob(job) { seedsBuf, scoresBuf in
                for i in 0..<job.count {
                    let sc = scoresBuf[i]
                    guard sc.isFinite else { continue }
                    heap.keepLargest(SeedScoreEntry(score: sc, seed: seedsBuf[i]), limit: topCount)
                }
            }
            processed += job.count

            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastPrintNs >= 1_000_000_000 {
                let dt = Double(now - startNs) / 1e9
                let rate = Double(processed) / max(1e-9, dt)
                let worst = heap.min?.score ?? -Float.infinity
                print("scan \(processed)/\(scanFinal) (\(String(format: "%.0f", rate))/s) topMin=\(String(format: "%.6f", worst))")
                lastPrintNs = now
            }
        }

        let scanDt = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        print("Scan done: \(processed) seeds in \(String(format: "%.2fs", scanDt)) (\(String(format: "%.0f", Double(processed) / max(1e-9, scanDt)))/s)")

        let top = heap.items.sorted { $0.score > $1.score }
        let verifyN = min(topCount, top.count)
        if verifyN == 0 {
            throw GobxError.usage("No finite Metal scores observed; cannot calibrate.")
        }

        print("Verifying top \(verifyN) seeds on CPU…")
        let cpu = Scorer(size: 128)

        var deltas: [Double] = []
        deltas.reserveCapacity(verifyN)
        var unders: [Double] = []
        unders.reserveCapacity(verifyN)
        var overs: [Double] = []
        overs.reserveCapacity(verifyN)

        for i in 0..<verifyN {
            let e = top[i]
            let cpuScore = cpu.score(seed: e.seed).totalScore
            let gpuScore = Double(e.score)
            let delta = cpuScore - gpuScore
            deltas.append(delta)
            unders.append(max(0.0, delta))
            overs.append(max(0.0, -delta))
        }

        deltas.sort()
        unders.sort()
        overs.sort()

        let maxUnder = unders.last ?? 0.0
        let meanDelta = deltas.reduce(0, +) / Double(deltas.count)
        let meanUnder = unders.reduce(0, +) / Double(unders.count)
        let meanOver = overs.reduce(0, +) / Double(overs.count)
        let p95 = CalibrationSupport.quantile(unders, q: 0.95)
        let p99 = CalibrationSupport.quantile(unders, q: 0.99)
        let p999 = CalibrationSupport.quantile(unders, q: 0.999)
        let rec = CalibrationSupport.quantile(unders, q: quantile)
        let scoreShiftQuantile = 0.9
        let scoreShift = CalibrationSupport.quantile(overs, q: scoreShiftQuantile)
        let p90Over = CalibrationSupport.quantile(overs, q: 0.90)
        let p95Over = CalibrationSupport.quantile(overs, q: 0.95)
        let p99Over = CalibrationSupport.quantile(overs, q: 0.99)

        let calibration = MetalCalibration(
            schemaVersion: 2,
            createdAt: Date(),
            hardwareHash: hash,
            key: key,
            batchUsed: batch,
            scanCount: scanCount,
            topCount: topCount,
            verifiedCount: verifyN,
            quantile: quantile,
            recommendedMargin: rec,
            scoreShiftQuantile: scoreShiftQuantile,
            recommendedScoreShift: scoreShift,
            maxUnderestimation: maxUnder,
            meanDelta: meanDelta,
            meanUnderestimation: meanUnder,
            meanOverestimation: meanOver,
            p95Underestimation: p95,
            p99Underestimation: p99,
            p999Underestimation: p999,
            p90Overestimation: p90Over,
            p95Overestimation: p95Over,
            p99Overestimation: p99Over
        )

        try saveMetalCalibration(calibration, to: url)

        print("Wrote Metal calibration: margin=\(String(format: "%.6f", rec)) shift=\(String(format: "%.6f", scoreShift)) max=\(String(format: "%.6f", maxUnder)) meanΔ=\(String(format: "%.6f", meanDelta)) file=\(url.path)")
    }

    static func loadIfValid(configPath: String? = nil) -> MetalCalibration? {
        guard let key = try? currentMetalCalibrationKey() else { return nil }
        guard let hash = try? hardwareHash(for: key) else { return nil }
        let url = configPath.map { URL(fileURLWithPath: GobxPaths.expandPath($0)) } ?? defaultMetalCalibrationURL()
        guard let cal = loadMetalCalibration(from: url) else { return nil }
        guard cal.key == key, cal.hardwareHash == hash else { return nil }
        return cal
    }
}
