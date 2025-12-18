import Dispatch
import Foundation
import Metal
import MetalPerformanceShadersGraph

struct MPSCalibrationKey: Codable, Equatable {
    let schemaVersion: Int
    let cpuScorerVersion: Int
    let mpsScorerVersion: Int
    let optimizationLevel: Int
    let osVersion: String
    let hwModel: String?
    let cpuBrand: String?
    let arch: String
    let gpuName: String
    let gpuRegistryID: UInt64
}

struct MPSCalibration: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let hardwareHash: String
    let key: MPSCalibrationKey
    let batchUsed: Int
    let scanCount: Int
    let topCount: Int
    let verifiedCount: Int
    let quantile: Double
    let recommendedMargin: Double
    let maxUnderestimation: Double
    let meanDelta: Double
    let meanUnderestimation: Double
    let p95Underestimation: Double
    let p99Underestimation: Double
    let p999Underestimation: Double
}

private func defaultMPSCalibrationURL() -> URL {
    GobxPaths.mpsCalibrationURL
}

private func loadMPSCalibration(from url: URL) -> MPSCalibration? {
    CalibrationSupport.loadJSON(MPSCalibration.self, from: url)
}

private func saveMPSCalibration(_ calibration: MPSCalibration, to url: URL) throws {
    try CalibrationSupport.saveJSON(calibration, to: url)
}

private func currentCalibrationKey(optimizationLevel: Int) throws -> MPSCalibrationKey {
    let dev = try CalibrationSupport.metalDevice()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let hwModel = CalibrationSupport.sysctlString("hw.model")
    let cpuBrand = CalibrationSupport.sysctlString("machdep.cpu.brand_string")
    let arch = CalibrationSupport.archString()
    return MPSCalibrationKey(
        schemaVersion: 1,
        cpuScorerVersion: Scorer.scorerVersion,
        mpsScorerVersion: MPSScorer.scorerVersion,
        optimizationLevel: optimizationLevel,
        osVersion: osVersion,
        hwModel: hwModel,
        cpuBrand: cpuBrand,
        arch: arch,
        gpuName: dev.name,
        gpuRegistryID: dev.registryID
    )
}

private func hardwareHash(for key: MPSCalibrationKey) throws -> String {
    try CalibrationSupport.hardwareHash(for: key)
}

enum CalibrateMPS {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx calibrate-mps [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--opt 0|1] [--out <path>] [--force]"
        var parser = ArgumentParser(args: args, usage: usage)

        var batch = 64
        var scanCount = 2_000_000
        var topCount = 4096
        var quantile = 0.999
        var force = false
        var optLevel = 1
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
            case "--force":
                force = true
            case "--opt":
                optLevel = try parser.requireInt(for: "--opt")
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            default:
                throw parser.unknown(a)
            }
        }

        guard (0...1).contains(optLevel) else {
            throw GobxError.usage("Invalid --opt: \(optLevel) (expected 0|1)")
        }

        let opt: MPSGraphOptimization = (optLevel == 0) ? .level0 : .level1
        let key = try currentCalibrationKey(optimizationLevel: optLevel)
        let hash = try hardwareHash(for: key)

        let url: URL = {
            if let outPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(outPath))
            }
            return defaultMPSCalibrationURL()
        }()

        if !force, let existing = loadMPSCalibration(from: url), existing.key == key, existing.hardwareHash == hash {
            print("Loaded existing MPS calibration: margin=\(String(format: "%.6f", existing.recommendedMargin)) q=\(String(format: "%.4f", existing.quantile)) verified=\(existing.verifiedCount) hash=\(existing.hardwareHash.prefix(12)) file=\(url.path)")
            return
        }

        print("Calibrating MPS vs CPU (batch=\(batch) scan=\(scanCount) top=\(topCount) q=\(String(format: "%.4f", quantile)) opt=\(optLevel))")
        print("Hardware hash: \(hash)")

        let mps = try MPSScorer(batchSize: batch, optimizationLevel: opt)

        var heap = MinHeap<SeedScoreEntry>()
        heap.reserveCapacity(min(topCount, 16384))

        let v2Min: UInt64 = 0x1_0000_0000
        let v2MaxExclusive: UInt64 = 0x20_0000_0000_0000
        let baseSeed = normalizeV2Seed(UInt64.random(in: v2Min..<v2MaxExclusive))
        var seed = baseSeed
        let scanAligned = scanCount - (scanCount % batch)
        let scanFinal = max(batch, scanAligned)
        var processed = 0
        let startNs = DispatchTime.now().uptimeNanoseconds
        var lastPrintNs = startNs

        var seeds = [UInt64](repeating: 0, count: batch)
        while processed < scanFinal {
            let n = min(batch, scanFinal - processed)
            for i in 0..<n {
                seeds[i] = seed
                seed = nextV2Seed(seed, by: 1)
            }
            if n < batch {
                for i in n..<batch { seeds[i] = 0 }
            }
            let scores = mps.score(seeds: seeds)
            for i in 0..<n {
                let sc = scores[i]
                guard sc.isFinite else { continue }
                heap.keepLargest(SeedScoreEntry(score: sc, seed: seeds[i]), limit: topCount)
            }
            processed += n

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
            throw GobxError.usage("No finite MPS scores observed; cannot calibrate.")
        }

        print("Verifying top \(verifyN) seeds on CPU…")
        let cpu = Scorer(size: 128)

        var deltas: [Double] = []
        deltas.reserveCapacity(verifyN)
        var unders: [Double] = []
        unders.reserveCapacity(verifyN)

        for i in 0..<verifyN {
            let e = top[i]
            let cpuScore = cpu.score(seed: e.seed).totalScore
            let mpsScore = Double(e.score)
            let delta = cpuScore - mpsScore
            deltas.append(delta)
            unders.append(max(0.0, delta))
        }

        deltas.sort()
        unders.sort()

        let maxUnder = unders.last ?? 0.0
        let meanDelta = deltas.reduce(0, +) / Double(deltas.count)
        let meanUnder = unders.reduce(0, +) / Double(unders.count)
        let p95 = CalibrationSupport.quantile(unders, q: 0.95)
        let p99 = CalibrationSupport.quantile(unders, q: 0.99)
        let p999 = CalibrationSupport.quantile(unders, q: 0.999)
        let rec = CalibrationSupport.quantile(unders, q: quantile)

        let calibration = MPSCalibration(
            schemaVersion: 1,
            createdAt: Date(),
            hardwareHash: hash,
            key: key,
            batchUsed: batch,
            scanCount: scanCount,
            topCount: topCount,
            verifiedCount: verifyN,
            quantile: quantile,
            recommendedMargin: rec,
            maxUnderestimation: maxUnder,
            meanDelta: meanDelta,
            meanUnderestimation: meanUnder,
            p95Underestimation: p95,
            p99Underestimation: p99,
            p999Underestimation: p999
        )

        try saveMPSCalibration(calibration, to: url)

        print("Wrote MPS calibration: margin=\(String(format: "%.6f", rec)) max=\(String(format: "%.6f", maxUnder)) meanΔ=\(String(format: "%.6f", meanDelta)) file=\(url.path)")
    }

    static func loadIfValid(optLevel: Int = 1, configPath: String? = nil) -> MPSCalibration? {
        guard let key = try? currentCalibrationKey(optimizationLevel: optLevel) else { return nil }
        guard let hash = try? hardwareHash(for: key) else { return nil }
        let url = configPath.map { URL(fileURLWithPath: GobxPaths.expandPath($0)) } ?? defaultMPSCalibrationURL()
        guard let cal = loadMPSCalibration(from: url) else { return nil }
        guard cal.key == key, cal.hardwareHash == hash else { return nil }
        return cal
    }
}
