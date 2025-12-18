import Dispatch
import Foundation
import Metal
import MetalPerformanceShadersGraph

struct MPSStage1CalibrationKey: Codable, Equatable {
    let schemaVersion: Int
    let mpsScorerVersion: Int
    let optimizationLevel: Int
    let stage1Size: Int
    let stage2Size: Int
    let osVersion: String
    let hwModel: String?
    let cpuBrand: String?
    let arch: String
    let gpuName: String
    let gpuRegistryID: UInt64
}

struct MPSStage1Calibration: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let hardwareHash: String
    let key: MPSStage1CalibrationKey
    let stage2BatchUsed: Int
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

private func defaultMPSStage1CalibrationURL() -> URL {
    GobxPaths.mpsStage1CalibrationURL
}

private func loadMPSStage1Calibration(from url: URL) -> MPSStage1Calibration? {
    CalibrationSupport.loadJSON(MPSStage1Calibration.self, from: url)
}

private func saveMPSStage1Calibration(_ calibration: MPSStage1Calibration, to url: URL) throws {
    try CalibrationSupport.saveJSON(calibration, to: url)
}

private func currentStage1CalibrationKey(optimizationLevel: Int, stage1Size: Int) throws -> MPSStage1CalibrationKey {
    let dev = try CalibrationSupport.metalDevice()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let hwModel = CalibrationSupport.sysctlString("hw.model")
    let cpuBrand = CalibrationSupport.sysctlString("machdep.cpu.brand_string")
    let arch = CalibrationSupport.archString()
    return MPSStage1CalibrationKey(
        schemaVersion: 1,
        mpsScorerVersion: MPSScorer.scorerVersion,
        optimizationLevel: optimizationLevel,
        stage1Size: stage1Size,
        stage2Size: 128,
        osVersion: osVersion,
        hwModel: hwModel,
        cpuBrand: cpuBrand,
        arch: arch,
        gpuName: dev.name,
        gpuRegistryID: dev.registryID
    )
}

private func hardwareHash(for key: MPSStage1CalibrationKey) throws -> String {
    try CalibrationSupport.hardwareHash(for: key)
}

enum CalibrateMPSStage1 {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx calibrate-mps-stage1 [--stage1-size <n>] [--batch <n>] [--scan <n>] [--top <n>] [--quantile <q>] [--opt 0|1] [--out <path>] [--force]"
        var parser = ArgumentParser(args: args, usage: usage)

        var stage1Size = 64
        var batch = 192
        var scanCount = 2_000_000
        var topCount = 4096
        var quantile = 0.999
        var force = false
        var optLevel = 1
        var outPath: String? = nil

        while let a = parser.pop() {
            switch a {
            case "--stage1-size":
                stage1Size = try parser.requireInt(for: "--stage1-size")
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

        guard stage1Size > 0, stage1Size < 128, (stage1Size & (stage1Size - 1)) == 0 else {
            throw GobxError.usage("Invalid --stage1-size: \(stage1Size) (expected power-of-two < 128)")
        }

        guard (0...1).contains(optLevel) else {
            throw GobxError.usage("Invalid --opt: \(optLevel) (expected 0|1)")
        }

        let opt: MPSGraphOptimization = (optLevel == 0) ? .level0 : .level1
        let key = try currentStage1CalibrationKey(optimizationLevel: optLevel, stage1Size: stage1Size)
        let hash = try hardwareHash(for: key)

        let url: URL = {
            if let outPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(outPath))
            }
            return defaultMPSStage1CalibrationURL()
        }()

        if !force, let existing = loadMPSStage1Calibration(from: url), existing.key == key, existing.hardwareHash == hash {
            print("Loaded existing MPS stage1 calibration: stage1-margin=\(String(format: "%.6f", existing.recommendedMargin)) q=\(String(format: "%.4f", existing.quantile)) verified=\(existing.verifiedCount) hash=\(existing.hardwareHash.prefix(12)) file=\(url.path)")
            return
        }

        print("Calibrating MPS stage1 vs stage2 (stage1=\(stage1Size)x\(stage1Size), stage2=128x128, batch=\(batch) scan=\(scanCount) top=\(topCount) q=\(String(format: "%.4f", quantile)) opt=\(optLevel))")
        print("Hardware hash: \(hash)")

        let stage2 = try MPSScorer(batchSize: batch, imageSize: 128, optimizationLevel: opt)

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
            let scores = stage2.score(seeds: seeds)
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
            throw GobxError.usage("No finite MPS stage2 scores observed; cannot calibrate.")
        }

        print("Scoring stage1 for top \(verifyN) stage2 seeds…")
        let stage1 = try MPSScorer(batchSize: batch, imageSize: stage1Size, optimizationLevel: opt)

        var deltas: [Double] = []
        deltas.reserveCapacity(verifyN)
        var unders: [Double] = []
        unders.reserveCapacity(verifyN)

        var j = 0
        var batchSeeds = [UInt64](repeating: 0, count: batch)
        while j < verifyN {
            let n = min(batch, verifyN - j)
            for k in 0..<n {
                batchSeeds[k] = top[j + k].seed
            }
            if n < batch {
                for k in n..<batch { batchSeeds[k] = 0 }
            }
            let scores1 = stage1.score(seeds: batchSeeds)
            for k in 0..<n {
                let s2 = Double(top[j + k].score)
                let s1 = Double(scores1[k])
                let delta = s2 - s1
                deltas.append(delta)
                unders.append(max(0.0, delta))
            }
            j += n
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

        let calibration = MPSStage1Calibration(
            schemaVersion: 1,
            createdAt: Date(),
            hardwareHash: hash,
            key: key,
            stage2BatchUsed: batch,
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

        try saveMPSStage1Calibration(calibration, to: url)

        print("Wrote MPS stage1 calibration: stage1-margin=\(String(format: "%.6f", rec)) max=\(String(format: "%.6f", maxUnder)) meanΔ=\(String(format: "%.6f", meanDelta)) file=\(url.path)")
    }

    static func loadIfValid(optLevel: Int = 1, stage1Size: Int = 64, configPath: String? = nil) -> MPSStage1Calibration? {
        guard let key = try? currentStage1CalibrationKey(optimizationLevel: optLevel, stage1Size: stage1Size) else { return nil }
        guard let hash = try? hardwareHash(for: key) else { return nil }
        let url = configPath.map { URL(fileURLWithPath: GobxPaths.expandPath($0)) } ?? defaultMPSStage1CalibrationURL()
        guard let cal = loadMPSStage1Calibration(from: url) else { return nil }
        guard cal.key == key, cal.hardwareHash == hash else { return nil }
        return cal
    }
}
