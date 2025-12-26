import Darwin
import Dispatch
import Foundation
import Metal
import MetalPerformanceShadersGraph

struct BenchMPSWorkerResult: Codable {
    let batchSize: Int
    let imageSize: Int
    let inflight: Int
    let optimizationLevel: Int
    let warmupSeconds: Double
    let warmupBatches: Int
    let measureSeconds: Double
    let elapsedSeconds: Double
    let seeds: UInt64
    let seedsPerSecond: Double
    let avgScore: Double
    let gpuActiveResidencyAvg: Double?
    let gpuActiveResidencyMin: Double?
    let gpuActiveResidencyMax: Double?
    let gpuActiveResidencySamples: Int?
    let deviceName: String?
}

enum BenchMPS {
    private static func defaultBatches(for imageSize: Int) -> [Int] {
        if imageSize <= 32 {
            return [1024, 1536, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192, 9216, 10240, 11264, 12288]
        }
        return [16, 32, 48, 64, 80, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx bench-mps [--seconds <s>] [--warmup <s>] [--warmup-batches <n>] [--reps <n>] [--batches <csv>] [--size <n>] [--gpu-util] [--gpu-interval-ms <n>] [--inflight <n>] [--opt 0|1] [--log-dir <path>] [--json]"
        var parser = ArgumentParser(args: args, usage: usage)

        var seconds: Double = 5.0
        var warmup: Double = 1.0
        var warmupBatches: Int = 0
        var reps: Int = 2
        var batches: [Int] = []
        var batchesSpecified = false
        var imageSize: Int = 128
        var gpuUtil = false
        var gpuIntervalMs = 500
        var inflight: Int = 2
        var logDir: URL? = nil
        var jsonOutput = false
        var optimizationLevel = 1

        while let a = parser.pop() {
            switch a {
            case "--seconds":
                seconds = max(0.25, try parser.requireDouble(for: "--seconds"))
            case "--warmup":
                warmup = max(0.0, try parser.requireDouble(for: "--warmup"))
            case "--warmup-batches":
                warmupBatches = max(0, try parser.requireInt(for: "--warmup-batches"))
            case "--reps":
                reps = max(1, try parser.requireInt(for: "--reps"))
            case "--batches":
                batches = try parseBatchesCSV(try parser.requireValue(for: "--batches"))
                batchesSpecified = true
            case "--size":
                imageSize = try parser.requireInt(for: "--size")
            case "--gpu-util":
                gpuUtil = true
            case "--gpu-interval-ms":
                gpuIntervalMs = max(50, try parser.requireInt(for: "--gpu-interval-ms"))
            case "--inflight":
                inflight = max(1, try parser.requireInt(for: "--inflight"))
            case "--log-dir":
                logDir = URL(fileURLWithPath: GobxPaths.expandPath(try parser.requireValue(for: "--log-dir")))
            case "--json":
                jsonOutput = true
            case "--opt":
                optimizationLevel = try parser.requireInt(for: "--opt")
            default:
                throw parser.unknown(a)
            }
        }

        if !(0...1).contains(optimizationLevel) {
            throw GobxError.usage("Invalid --opt: \(optimizationLevel) (expected 0|1)")
        }
        if imageSize <= 0 || (imageSize & (imageSize - 1)) != 0 {
            throw GobxError.usage("Invalid --size: \(imageSize) (expected power-of-two > 0)")
        }
        if !batchesSpecified {
            batches = defaultBatches(for: imageSize)
        }

        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let outDir: URL = {
            if let d = logDir { return d }
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            return FileManager.default.temporaryDirectory.appendingPathComponent("gobx-bench-mps-\(ts)")
        }()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if !jsonOutput {
            let batchList = batches.map(String.init).joined(separator: ",")
            print("Bench logs: \(outDir.path)")
            let gpuStr = gpuUtil ? " gpu-util=on interval=\(gpuIntervalMs)ms" : ""
            print("Sweeping batches: \(batchList) (size=\(imageSize), reps=\(reps), warmup=\(String(format: "%.2f", warmup))s, warmup-batches=\(warmupBatches), seconds=\(String(format: "%.2f", seconds))s, inflight=\(inflight), opt=\(optimizationLevel)\(gpuStr))")
            print("")
        }

        struct RunRecord {
            let batch: Int
            let rep: Int
            let result: BenchMPSWorkerResult?
            let termination: String?
            let logBase: URL
        }

        var records: [RunRecord] = []
        records.reserveCapacity(batches.count * reps)

        let totalRuns = batches.count * reps
        var runIndex = 0

        for b in batches {
            for r in 1...reps {
                runIndex += 1
                let base = outDir.appendingPathComponent("batch\(b)_rep\(r)")
                let stdoutURL = base.appendingPathExtension("stdout.log")
                let stderrURL = base.appendingPathExtension("stderr.log")

                let args = [
                    "bench-mps-worker",
                    "--batch", String(b),
                    "--seconds", String(seconds),
                    "--warmup", String(warmup),
                    "--warmup-batches", String(warmupBatches),
                    "--size", String(imageSize),
                    "--inflight", String(inflight),
                    "--opt", String(optimizationLevel),
                ]
                var workerArgs = args
                if gpuUtil {
                    workerArgs.append("--gpu-util")
                    workerArgs.append("--gpu-interval-ms")
                    workerArgs.append(String(gpuIntervalMs))
                }

                let proc = Process()
                proc.executableURL = exe
                proc.arguments = workerArgs

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    throw GobxError.usage("Failed to spawn worker: \(error)")
                }

                proc.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                try outData.write(to: stdoutURL, options: .atomic)
                try errData.write(to: stderrURL, options: .atomic)

                let termination: String? = {
                    if proc.terminationReason == .uncaughtSignal {
                        let sig = Int32(proc.terminationStatus)
                        if let cstr = strsignal(sig) {
                            return "signal=\(sig) (\(String(cString: cstr)))"
                        }
                        return "signal=\(sig)"
                    }
                    if proc.terminationStatus != 0 {
                        return "exit=\(proc.terminationStatus)"
                    }
                    return nil
                }()

                let decoded: BenchMPSWorkerResult? = {
                    guard termination == nil else { return nil }
                    return try? JSONDecoder().decode(BenchMPSWorkerResult.self, from: outData)
                }()

                let finalTermination: String? = {
                    if let termination { return termination }
                    if decoded == nil { return "decode_error" }
                    return nil
                }()

                records.append(RunRecord(batch: b, rep: r, result: decoded, termination: finalTermination, logBase: base))

                if !jsonOutput {
                    if let decoded {
                        let rate = String(format: "%.0f/s", decoded.seedsPerSecond)
                        let avg = String(format: "%.6f", decoded.avgScore)
                        let gpu = decoded.gpuActiveResidencyAvg.map { String(format: " gpu=%.0f%%", $0) } ?? ""
                        print("[\(runIndex)/\(totalRuns)] batch=\(b) rep=\(r) OK \(rate) avg=\(avg)\(gpu)")
                    } else {
                        print("[\(runIndex)/\(totalRuns)] batch=\(b) rep=\(r) FAIL \(finalTermination ?? "?") logs=\(base.path)")
                    }
                }
            }
        }

        if jsonOutput {
            struct Output: Codable {
                let logDir: String
                let runs: [BenchMPSWorkerResult]
                let failures: [String]
            }
            let okRuns = records.compactMap(\.result)
            let failures = records.compactMap { rec -> String? in
                guard let t = rec.termination else { return nil }
                return "batch=\(rec.batch) rep=\(rec.rep) \(t) logs=\(rec.logBase.path)"
            }
            let payload = Output(logDir: outDir.path, runs: okRuns, failures: failures)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            return
        }

        // Aggregate per batch (median seeds/s across reps).
        struct BatchAgg {
            let batch: Int
            let ok: Int
            let crashed: Int
            let medianRate: Double?
            let meanRate: Double?
        }

        var aggs: [BatchAgg] = []
        aggs.reserveCapacity(batches.count)

        for b in batches {
            let runs = records.filter { $0.batch == b }
            let ok = runs.compactMap(\.result)
            let failures = runs.filter { $0.termination != nil }
            let rates = ok.map(\.seedsPerSecond).sorted()
            let median: Double? = {
                guard !rates.isEmpty else { return nil }
                if rates.count % 2 == 1 { return rates[rates.count / 2] }
                return 0.5 * (rates[rates.count / 2 - 1] + rates[rates.count / 2])
            }()
            let mean: Double? = rates.isEmpty ? nil : (rates.reduce(0, +) / Double(rates.count))
            aggs.append(BatchAgg(batch: b, ok: ok.count, crashed: failures.count, medianRate: median, meanRate: mean))
        }

        aggs.sort { (lhs, rhs) -> Bool in
            (lhs.medianRate ?? -Double.infinity) > (rhs.medianRate ?? -Double.infinity)
        }

        func fmtRate(_ v: Double?) -> String {
            guard let v else { return "-" }
            return String(format: "%.0f/s", v)
        }

        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return String(repeating: " ", count: width - s.count) + s
        }

        print("")
        print("\(pad("batch", 8))  \(pad("ok", 6))  \(pad("median", 10))  \(pad("mean", 10))")
        for a in aggs {
            let okStr = "\(a.ok)/\(reps)"
            print("\(pad(String(a.batch), 8))  \(pad(okStr, 6))  \(pad(fmtRate(a.medianRate), 10))  \(pad(fmtRate(a.meanRate), 10))")
        }

        if let best = aggs.first, let bestRate = best.medianRate {
            print("")
            print("Best batch: \(best.batch) (\(String(format: "%.0f", bestRate))/s median)")
        }

        let failures = records.filter { $0.termination != nil }
        if !failures.isEmpty {
            print("")
            print("Failures:")
            for f in failures {
                print("  - batch=\(f.batch) rep=\(f.rep) \(f.termination ?? "?") logs=\(f.logBase.path)")
            }
        }
    }

    static func runWorker(args: [String]) throws {
        let usage = "Usage: gobx bench-mps-worker --batch <n> [--seconds <s>] [--warmup <s>] [--warmup-batches <n>] [--size <n>] [--gpu-util] [--gpu-interval-ms <n>] [--inflight <n>] [--opt 0|1]"
        var parser = ArgumentParser(args: args, usage: usage)

        var batch: Int? = nil
        var seconds: Double = 5.0
        var warmup: Double = 1.0
        var warmupBatches: Int = 0
        var imageSize: Int = 128
        var gpuUtil = false
        var gpuIntervalMs = 500
        var inflight: Int = 2
        var optimizationLevel = 1

        while let a = parser.pop() {
            switch a {
            case "--batch":
                batch = try parser.requireInt(for: "--batch")
            case "--seconds":
                seconds = max(0.25, try parser.requireDouble(for: "--seconds"))
            case "--warmup":
                warmup = max(0.0, try parser.requireDouble(for: "--warmup"))
            case "--warmup-batches":
                warmupBatches = max(0, try parser.requireInt(for: "--warmup-batches"))
            case "--size":
                imageSize = try parser.requireInt(for: "--size")
            case "--gpu-util":
                gpuUtil = true
            case "--gpu-interval-ms":
                gpuIntervalMs = max(50, try parser.requireInt(for: "--gpu-interval-ms"))
            case "--inflight":
                inflight = max(1, try parser.requireInt(for: "--inflight"))
            case "--opt":
                optimizationLevel = try parser.requireInt(for: "--opt")
            default:
                throw parser.unknown(a)
            }
        }

        guard let batch, batch > 0 else {
            throw GobxError.usage("bench-mps-worker requires --batch <n>")
        }
        guard (0...1).contains(optimizationLevel) else {
            throw GobxError.usage("Invalid --opt: \(optimizationLevel) (expected 0|1)")
        }
        if imageSize <= 0 || (imageSize & (imageSize - 1)) != 0 {
            throw GobxError.usage("Invalid --size: \(imageSize) (expected power-of-two > 0)")
        }

        let opt: MPSGraphOptimization = {
            switch optimizationLevel {
            case 0: return .level0
            default: return .level1
            }
        }()

        let deviceName: String? = {
            guard let d = MTLCreateSystemDefaultDevice() else { return nil }
            return d.name
        }()

        let scorer = try MPSScorer(batchSize: batch, imageSize: imageSize, inflight: inflight, optimizationLevel: opt)

        let warmupNs = UInt64(warmup * 1e9)
        let measureNs = UInt64(seconds * 1e9)

        var seeds = [UInt64](repeating: 0, count: batch)
        var seed: UInt64 = 0x1_0000_0000

        func runBatches(_ batches: Int) throws {
            guard batches > 0 else { return }

            let inflightFinal = max(1, inflight)
            var pending: [MPSScorer.Job] = []
            pending.reserveCapacity(inflightFinal)

            var enqueuedBatches = 0
            var completedBatches = 0

            while completedBatches < batches {
                while pending.count < inflightFinal, enqueuedBatches < batches {
                    for i in 0..<batch {
                        seeds[i] = seed
                        seed &+= 1
                    }
                    let job = seeds.withUnsafeBufferPointer { buf in
                        scorer.enqueue(seeds: buf, count: batch)
                    }
                    pending.append(job)
                    enqueuedBatches += 1
                }

                guard !pending.isEmpty else { continue }
                let job = pending.removeFirst()
                try scorer.withCompletedJob(job) { _, _ in }
                completedBatches += 1
            }
        }

        func run(for durationNs: UInt64) throws -> (seeds: UInt64, scoreSum: Double, elapsed: Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            let endTarget = start &+ durationNs
            var totalSeeds: UInt64 = 0
            var scoreSum: Double = 0

            let inflightFinal = max(1, inflight)
            var pending: [MPSScorer.Job] = []
            pending.reserveCapacity(inflightFinal)

            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= endTarget { break }

                while pending.count < inflightFinal {
                    for i in 0..<batch {
                        seeds[i] = seed
                        seed &+= 1
                    }
                    let job = seeds.withUnsafeBufferPointer { buf in
                        scorer.enqueue(seeds: buf, count: batch)
                    }
                    pending.append(job)

                    let t = DispatchTime.now().uptimeNanoseconds
                    if t >= endTarget { break }
                }

                if !pending.isEmpty {
                    let job = pending.removeFirst()
                    try scorer.withCompletedJob(job) { _, scoresBuf in
                        for sc in scoresBuf {
                            scoreSum += Double(sc)
                        }
                    }
                    totalSeeds &+= UInt64(job.count)
                }
            }

            while !pending.isEmpty {
                let job = pending.removeFirst()
                try scorer.withCompletedJob(job) { _, scoresBuf in
                    for sc in scoresBuf {
                        scoreSum += Double(sc)
                    }
                }
                totalSeeds &+= UInt64(job.count)
            }

            let end = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(end - start) / 1e9
            return (totalSeeds, scoreSum, elapsed)
        }

        if warmupNs > 0 {
            _ = try run(for: warmupNs)
        }
        if warmupBatches > 0 {
            try runBatches(warmupBatches)
        }
        let gpuSampler = gpuUtil ? PowermetricsSampler(durationSeconds: seconds, intervalMs: gpuIntervalMs) : nil
        gpuSampler?.start()
        let r = try run(for: measureNs)
        let gpuSummary = gpuSampler?.finish()

        let rate = Double(r.seeds) / max(1e-9, r.elapsed)
        let avgScore = r.seeds > 0 ? (r.scoreSum / Double(r.seeds)) : 0.0

        let out = BenchMPSWorkerResult(
            batchSize: batch,
            imageSize: imageSize,
            inflight: inflight,
            optimizationLevel: optimizationLevel,
            warmupSeconds: warmup,
            warmupBatches: warmupBatches,
            measureSeconds: seconds,
            elapsedSeconds: r.elapsed,
            seeds: r.seeds,
            seedsPerSecond: rate,
            avgScore: avgScore,
            gpuActiveResidencyAvg: gpuSummary?.avg,
            gpuActiveResidencyMin: gpuSummary?.min,
            gpuActiveResidencyMax: gpuSummary?.max,
            gpuActiveResidencySamples: gpuSummary?.samples,
            deviceName: deviceName
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(out)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    private static func parseBatchesCSV(_ s: String) throws -> [Int] {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if parts.isEmpty { throw GobxError.usage("Empty --batches list") }
        var out: [Int] = []
        for p in parts {
            guard let v = Int(p), v > 0 else {
                throw GobxError.usage("Invalid batch size in --batches: \(p)")
            }
            out.append(v)
        }
        return out
    }

    private struct GPUUtilSummary {
        let avg: Double
        let min: Double
        let max: Double
        let samples: Int
    }

    private final class PowermetricsSampler {
        private let durationSeconds: Double
        private let intervalMs: Int
        private var process: Process?
        private let outPipe = Pipe()
        private let errPipe = Pipe()

        init(durationSeconds: Double, intervalMs: Int) {
            self.durationSeconds = max(0.1, durationSeconds)
            self.intervalMs = max(50, intervalMs)
        }

        func start() {
            let exe = "/usr/bin/powermetrics"
            guard FileManager.default.isExecutableFile(atPath: exe) else { return }

            let sampleCount = max(1, Int(ceil(durationSeconds * 1000.0 / Double(intervalMs))))
            let proc = Process()
            let args = ["--samplers", "gpu_power", "-i", String(intervalMs), "-n", String(sampleCount)]
            if geteuid() == 0 {
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = args
            } else {
                let sudoExe = "/usr/bin/sudo"
                guard FileManager.default.isExecutableFile(atPath: sudoExe) else { return }
                proc.executableURL = URL(fileURLWithPath: sudoExe)
                proc.arguments = ["-n", exe] + args
            }
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                return
            }
            process = proc
        }

        func finish() -> GPUUtilSummary? {
            guard let proc = process else { return nil }
            proc.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            let output = outStr + "\n" + errStr
            let samples = parseActiveResidency(from: output)
            guard !samples.isEmpty else { return nil }
            let minV = samples.min() ?? 0
            let maxV = samples.max() ?? 0
            let avgV = samples.reduce(0, +) / Double(samples.count)
            return GPUUtilSummary(avg: avgV, min: minV, max: maxV, samples: samples.count)
        }

        private func parseActiveResidency(from output: String) -> [Double] {
            var values: [Double] = []
            let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#, options: [])
            var idleValues: [Double] = []
            for lineSub in output.split(separator: "\n") {
                let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                let lower = line.lowercased()
                guard lower.contains("gpu") else { continue }
                let isActive = lower.contains("active residency") || lower.contains("gpu active") || lower.contains("gpu busy") || lower.contains("utilization")
                let isIdle = lower.contains("idle residency") || lower.contains("gpu idle")
                guard isActive || isIdle else { continue }
                if let regex {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    if let match = regex.firstMatch(in: line, options: [], range: range),
                       let numRange = Range(match.range(at: 1), in: line),
                       let v = Double(line[numRange]) {
                        if isActive {
                            values.append(v)
                        } else {
                            idleValues.append(v)
                        }
                        continue
                    }
                }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                for part in parts {
                    guard part.contains("%") else { continue }
                    let token = part.trimmingCharacters(in: CharacterSet(charactersIn: "%,;:()[]"))
                    if let v = Double(token) {
                        if isActive {
                            values.append(v)
                        } else {
                            idleValues.append(v)
                        }
                        break
                    }
                }
            }
            if !values.isEmpty { return values }
            if !idleValues.isEmpty {
                return idleValues.map { max(0.0, min(100.0, 100.0 - $0)) }
            }
            return []
        }
    }
}
