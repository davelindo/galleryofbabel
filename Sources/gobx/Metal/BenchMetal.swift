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
        let usage = "Usage: gobx bench-metal [--seconds <s>] [--warmup <s>] [--reps <n>] [--batches <csv>] [--size <n>] [--inflight <n>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var seconds: Double = 5.0
        var warmup: Double = 1.0
        var reps: Int = 2
        var batches: [Int] = []
        var batchesSpecified = false
        var imageSize = 128
        var inflight = 2

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

        let batchList = batches.map(String.init).joined(separator: ",")
        print("Sweeping batches: \(batchList) (size=\(imageSize), reps=\(reps), warmup=\(String(format: "%.2f", warmup))s, seconds=\(String(format: "%.2f", seconds))s, inflight=\(inflight))")

        struct Record {
            let batch: Int
            let rate: Double
            let avgScore: Double
        }

        var records: [Record] = []
        records.reserveCapacity(batches.count * reps)

        for b in batches {
            for rep in 1...reps {
                let scorer = try MetalPyramidScorer(batchSize: b, imageSize: imageSize, inflight: inflight)
                if warmup > 0 {
                    _ = try run(scorer: scorer, batch: b, inflight: inflight, durationNs: UInt64(warmup * 1e9))
                }
                let r = try run(scorer: scorer, batch: b, inflight: inflight, durationNs: UInt64(seconds * 1e9))
                let rate = Double(r.seeds) / max(1e-9, r.elapsed)
                let avgScore = r.seeds > 0 ? (r.scoreSum / Double(r.seeds)) : 0.0
                records.append(Record(batch: b, rate: rate, avgScore: avgScore))
                print("[\(records.count)/\(batches.count * reps)] batch=\(b) rep=\(rep) OK \(String(format: "%.0f", rate))/s avg=\(String(format: "%.6f", avgScore))")
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
}
