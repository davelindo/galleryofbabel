import Darwin
import Dispatch
import Foundation
import Metal

enum BenchMetal {
    private static func defaultBatches(for imageSize: Int) -> [Int] {
        if imageSize <= 32 {
            return [1024, 1536, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192, 9216, 10240, 11264, 12288]
        }
        return [16, 32, 48, 64, 80, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512]
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx bench-metal [--seconds <s>] [--warmup <s>] [--reps <n>] [--batches <csv>] [--size <n>] [--inflight <n>] [--tg <n>] [--cb-dispatches <n>] [--gpu-util] [--gpu-interval-ms <n>] [--gpu-trace <path>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var seconds: Double = 5.0
        var warmup: Double = 1.0
        var reps: Int = 2
        var batches: [Int] = []
        var batchesSpecified = false
        var imageSize = 128
        var inflight = 2
        var threadgroupSize = MetalPyramidScorer.defaultThreadgroupSize
        var commandBufferDispatches = 0
        var gpuUtil = false
        var gpuIntervalMs = 500
        var gpuTracePath: String? = nil

        while let a = parser.pop() {
            switch a {
            case "--seconds":
                seconds = max(0.1, try parser.requireDouble(for: "--seconds"))
            case "--warmup":
                warmup = max(0.0, try parser.requireDouble(for: "--warmup"))
            case "--reps":
                reps = max(1, try parser.requireInt(for: "--reps"))
            case "--batches":
                batches = try parseBatchesCSV(try parser.requireValue(for: "--batches"))
                batchesSpecified = true
            case "--size":
                imageSize = max(1, try parser.requireInt(for: "--size"))
            case "--inflight":
                inflight = max(1, try parser.requireInt(for: "--inflight"))
            case "--tg":
                threadgroupSize = max(1, try parser.requireInt(for: "--tg"))
            case "--cb-dispatches":
                commandBufferDispatches = max(1, try parser.requireInt(for: "--cb-dispatches"))
            case "--gpu-util":
                gpuUtil = true
            case "--gpu-interval-ms":
                gpuIntervalMs = max(50, try parser.requireInt(for: "--gpu-interval-ms"))
            case "--gpu-trace":
                gpuTracePath = try parser.requireValue(for: "--gpu-trace")
            default:
                throw parser.unknown(a)
            }
        }

        if !batchesSpecified {
            batches = defaultBatches(for: imageSize)
        }
        if imageSize != 128 {
            throw GobxError.usage("bench-metal supports --size 128 only")
        }
        if threadgroupSize % MetalPyramidScorer.simdWidth != 0 {
            throw GobxError.usage("--tg must be a multiple of \(MetalPyramidScorer.simdWidth)")
        }
        if threadgroupSize > MetalPyramidScorer.maxThreadgroupSize {
            throw GobxError.usage("--tg must be <= \(MetalPyramidScorer.maxThreadgroupSize)")
        }

        let traceOutput = try resolveTraceOutput(path: gpuTracePath, runs: batches.count * reps)
        if let traceOutput {
            try prepareTraceOutput(traceOutput)
            print("GPU trace output: \(traceOutput.description)")
        }

        let batchList = batches.map(String.init).joined(separator: ",")
        let gpuStr = gpuUtil ? " gpu-util=on interval=\(gpuIntervalMs)ms" : ""
        let cbStr = commandBufferDispatches > 0 ? " cb=\(commandBufferDispatches)" : " cb=auto"
        print("Sweeping batches: \(batchList) (size=\(imageSize), reps=\(reps), warmup=\(String(format: "%.2f", warmup))s, seconds=\(String(format: "%.2f", seconds))s, inflight=\(inflight) tg=\(threadgroupSize)\(cbStr)\(gpuStr))")

        struct Record {
            let batch: Int
            let rate: Double
            let avgScore: Double
            let gpuSummary: GPUUtilSummary?
        }

        var records: [Record] = []
        records.reserveCapacity(batches.count * reps)

        for b in batches {
            for rep in 1...reps {
                let scorer = try MetalPyramidScorer(
                    batchSize: b,
                    imageSize: imageSize,
                    inflight: inflight,
                    threadgroupSize: threadgroupSize,
                    commandBufferDispatches: commandBufferDispatches
                )
                if warmup > 0 {
                    _ = try run(scorer: scorer, batch: b, inflight: inflight, durationNs: UInt64(warmup * 1e9))
                }
                let gpuSampler = gpuUtil ? PowermetricsSampler(durationSeconds: seconds, intervalMs: gpuIntervalMs) : nil
                let traceURL = traceOutput?.url(forBatch: b, rep: rep)
                let capture = traceURL.map { MetalTraceCapture(commandQueue: scorer.captureCommandQueue, outputURL: $0) }
                try capture?.start()
                defer { capture?.stop() }
                gpuSampler?.start()
                let r = try run(scorer: scorer, batch: b, inflight: inflight, durationNs: UInt64(seconds * 1e9))
                let gpuSummary = gpuSampler?.finish()
                let rate = Double(r.seeds) / max(1e-9, r.elapsed)
                let avgScore = r.seeds > 0 ? (r.scoreSum / Double(r.seeds)) : 0.0
                records.append(Record(batch: b, rate: rate, avgScore: avgScore, gpuSummary: gpuSummary))
                let gpu = gpuSummary.map { String(format: " gpu=%.0f%%", $0.avg) } ?? ""
                print("[\(records.count)/\(batches.count * reps)] batch=\(b) rep=\(rep) OK \(String(format: "%.0f", rate))/s avg=\(String(format: "%.6f", avgScore))\(gpu)")
            }
        }

        let grouped = Dictionary(grouping: records, by: { $0.batch })
        let sortedBatches = grouped.keys.sorted()
        print("")
        print("   batch      ok      median        mean")
        var bestBatch: Int = 0
        var bestMedian: Double = 0
        for b in sortedBatches {
            let rows = grouped[b, default: []]
            let rates = rows.map { $0.rate }.sorted()
            let median = rates[rates.count / 2]
            let mean = rates.reduce(0, +) / Double(rates.count)
            if median > bestMedian {
                bestMedian = median
                bestBatch = b
            }
            let ok = "\(rows.count)/\(reps)"
            print(String(format: "%8d %6@ %10.0f/s %10.0f/s", b, ok as NSString, median, mean))
        }

        if bestBatch > 0 {
            print("")
            print("Best batch: \(bestBatch) (\(String(format: "%.0f", bestMedian))/s median)")
        }
    }

    private static func run(scorer: MetalPyramidScorer, batch: Int, inflight: Int, durationNs: UInt64) throws -> (seeds: UInt64, scoreSum: Double, elapsed: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let endTarget = start &+ durationNs
        var totalSeeds: UInt64 = 0
        var scoreSum: Double = 0

        var seeds = [UInt64](repeating: 0, count: batch)
        var seed: UInt64 = 0x1_0000_0000

        let inflightFinal = max(1, inflight)
        var pending: [GPUJob] = []
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

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return (totalSeeds, scoreSum, elapsed)
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

    private enum TraceOutput {
        case single(URL)
        case directory(URL)

        func url(forBatch batch: Int, rep: Int) -> URL {
            switch self {
            case .single(let url):
                return url
            case .directory(let dir):
                return dir.appendingPathComponent("bench-metal-batch\(batch)-rep\(rep).gputrace")
            }
        }

        var description: String {
            switch self {
            case .single(let url):
                return url.path
            case .directory(let dir):
                return dir.path
            }
        }
    }

    private static func resolveTraceOutput(path: String?, runs: Int) throws -> TraceOutput? {
        guard let path else { return nil }
        let expanded = GobxPaths.expandPath(path)
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return .directory(url)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "gputrace" {
            guard runs <= 1 else {
                throw GobxError.usage("--gpu-trace with multiple runs requires a directory path")
            }
            return .single(url)
        }
        if runs > 1 {
            return .directory(url)
        }
        return .single(url.appendingPathExtension("gputrace"))
    }

    private static func prepareTraceOutput(_ output: TraceOutput) throws {
        switch output {
        case .directory(let dir):
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        case .single(let url):
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    private final class MetalTraceCapture {
        private let manager = MTLCaptureManager.shared()
        private let commandQueue: MTLCommandQueue
        private let outputURL: URL
        private var started = false

        init(commandQueue: MTLCommandQueue, outputURL: URL) {
            self.commandQueue = commandQueue
            self.outputURL = outputURL
        }

        func start() throws {
            guard !started else { return }
            let descriptor = MTLCaptureDescriptor()
            descriptor.captureObject = commandQueue
            descriptor.destination = .gpuTraceDocument
            descriptor.outputURL = outputURL
            try manager.startCapture(with: descriptor)
            started = true
        }

        func stop() {
            guard started else { return }
            manager.stopCapture()
            started = false
        }
    }
}
