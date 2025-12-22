import Dispatch
import Foundation

enum TrainProxyCommand {
    private struct Sample {
        let seed: UInt64
        let features: [Double]
        let target: Double
        let cpuTotal: Double
    }

    private struct FeatureSample {
        let features: [Double]
        let target: Double
    }

    private struct LinearModel {
        let bias: Double
        let weights: [Double]

        func predict(_ features: [Double]) -> Double {
            let n = min(features.count, weights.count)
            var out = bias
            if n > 0 {
                for i in 0..<n {
                    out += weights[i] * features[i]
                }
            }
            return out
        }

        static func fitRidge(samples: [FeatureSample], lambda: Double) -> LinearModel {
            guard let first = samples.first else { return LinearModel(bias: 0, weights: []) }
            let dim = first.features.count + 1
            var xtx = [Double](repeating: 0, count: dim * dim)
            var xty = [Double](repeating: 0, count: dim)

            for s in samples {
                var x = [Double](repeating: 0, count: dim)
                x[0] = 1.0
                for i in 0..<s.features.count {
                    x[i + 1] = s.features[i]
                }
                for i in 0..<dim {
                    xty[i] += x[i] * s.target
                    for j in 0..<dim {
                        xtx[i * dim + j] += x[i] * x[j]
                    }
                }
            }

            if lambda > 0 {
                for i in 1..<dim {
                    xtx[i * dim + i] += lambda
                }
            }

            let solved = solveLinearSystem(a: xtx, b: xty, dim: dim)
            let bias = solved.first ?? 0
            let weights = Array(solved.dropFirst())
            return LinearModel(bias: bias, weights: weights)
        }

        private static func solveLinearSystem(a: [Double], b: [Double], dim: Int) -> [Double] {
            var a = a
            var b = b
            for i in 0..<dim {
                var maxRow = i
                var maxVal = abs(a[i * dim + i])
                for r in (i + 1)..<dim {
                    let v = abs(a[r * dim + i])
                    if v > maxVal {
                        maxVal = v
                        maxRow = r
                    }
                }
                if maxVal == 0 {
                    return [Double](repeating: 0, count: dim)
                }
                if maxRow != i {
                    for c in 0..<dim {
                        a.swapAt(i * dim + c, maxRow * dim + c)
                    }
                    b.swapAt(i, maxRow)
                }

                let pivot = a[i * dim + i]
                for c in i..<dim {
                    a[i * dim + c] /= pivot
                }
                b[i] /= pivot

                for r in 0..<dim where r != i {
                    let factor = a[r * dim + i]
                    if factor == 0 { continue }
                    for c in i..<dim {
                        a[r * dim + c] -= factor * a[i * dim + c]
                    }
                    b[r] -= factor * b[i]
                }
            }
            return b
        }
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx train-proxy [--n <n>] [--top <n>] [--tail-mult <n>] [--ridge <lambda>] [--seed <seed>] [--out <path>] [--gpu-backend mps|metal] [--report-every <sec>] [--threads <n>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var n = 100_000
        var topCount = 5_000
        var tailMult = 4
        var ridgeLambda = 1e-3
        var seedArg: UInt64? = nil
        var outPath: String? = nil
        var gpuBackend: GPUBackend = .metal
        var reportEverySec = 1.0
        var threadsArg: Int? = nil

        while let a = parser.pop() {
            switch a {
            case "--n":
                n = max(1, try parser.requireInt(for: "--n"))
            case "--top":
                topCount = max(0, try parser.requireInt(for: "--top"))
            case "--tail-mult":
                tailMult = max(1, try parser.requireInt(for: "--tail-mult"))
            case "--ridge":
                ridgeLambda = max(0, try parser.requireDouble(for: "--ridge"))
            case "--seed":
                seedArg = try parseSeed(try parser.requireValue(for: "--seed"))
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            case "--gpu-backend":
                gpuBackend = try parser.requireEnum(for: "--gpu-backend", GPUBackend.self)
            case "--report-every":
                reportEverySec = max(0, try parser.requireDouble(for: "--report-every"))
            case "--threads":
                threadsArg = max(1, try parser.requireInt(for: "--threads"))
            default:
                throw parser.unknown(a)
            }
        }

        let imageSize = 128
        let config = ProxyConfig.defaultConfig(for: gpuBackend, imageSize: imageSize)
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: config)
        let defaultOutURL = (gpuBackend == .metal) ? GobxPaths.metalProxyWeightsURL : GobxPaths.proxyWeightsURL
        let v2Min = V2SeedSpace.min
        let v2MaxExclusive = V2SeedSpace.maxExclusive
        var seed = normalizeV2Seed(seedArg ?? UInt64.random(in: v2Min..<v2MaxExclusive))

        let scorer = Scorer(size: imageSize)
        var samples: [Sample] = []
        samples.reserveCapacity(n)

        final class ProgressTracker: @unchecked Sendable {
            private let lock = NSLock()
            private let total: Int
            private let reportEverySec: Double
            private let startNs: UInt64
            private var lastPrintNs: UInt64
            private var processed: Int = 0

            init(total: Int, reportEverySec: Double) {
                self.total = total
                self.reportEverySec = reportEverySec
                self.startNs = DispatchTime.now().uptimeNanoseconds
                self.lastPrintNs = startNs
            }

            func add(_ delta: Int) {
                guard reportEverySec > 0, delta > 0 else { return }
                lock.lock()
                processed += delta
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPrintNs >= UInt64(reportEverySec * 1e9) {
                    let dt = Double(now - startNs) / 1e9
                    let rate = Double(processed) / max(1e-9, dt)
                    print("scan \(processed)/\(total) (\(String(format: "%.0f", rate))/s)")
                    lastPrintNs = now
                }
                lock.unlock()
            }
        }

        final class SampleCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [Sample]

            init(capacity: Int) {
                self.samples = []
                self.samples.reserveCapacity(capacity)
            }

            func append(_ local: [Sample]) {
                lock.lock()
                samples.append(contentsOf: local)
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                let c = samples.count
                lock.unlock()
                return c
            }

            func drain() -> [Sample] {
                lock.lock()
                let out = samples
                lock.unlock()
                return out
            }
        }

        let progress = ProgressTracker(total: n, reportEverySec: reportEverySec)

        let available = ProcessInfo.processInfo.activeProcessorCount
        let threadCount = min(max(1, threadsArg ?? 1), max(1, min(n, available)))

        if threadCount == 1 {
            var wavelet = WaveletProxy(size: imageSize)
            for _ in 0..<n {
                let cpu = scorer.score(seed: seed)
                let features = wavelet.featureVector(seed: seed, config: config)
                if features.count != featureCount {
                    throw GobxError.usage("Wavelet features expected \(featureCount) values, got \(features.count)")
                }
                let target = config.includeNeighborPenalty ? (cpu.totalScore - cpu.neighborCorrPenalty) : cpu.totalScore
                samples.append(Sample(seed: seed, features: features, target: target, cpuTotal: cpu.totalScore))
                seed = nextV2Seed(seed, by: 1)
                progress.add(1)
            }
        } else {
            let baseOffset = seed &- V2SeedSpace.min
            let spaceSize = V2SeedSpace.size
            let chunk = (n + threadCount - 1) / threadCount
            let group = DispatchGroup()
            let progressStride = 256
            let collector = SampleCollector(capacity: n)

            for t in 0..<threadCount {
                let startIndex = t * chunk
                let endIndex = min(n, startIndex + chunk)
                if startIndex >= endIndex { continue }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let scorer = Scorer(size: imageSize)
                    var wavelet = WaveletProxy(size: imageSize)
                    var local: [Sample] = []
                    local.reserveCapacity(endIndex - startIndex)

                    let seedOffset = (baseOffset &+ UInt64(startIndex)) % spaceSize
                    var seed = V2SeedSpace.min &+ seedOffset
                    var localProgress = 0

                    for _ in startIndex..<endIndex {
                        let cpu = scorer.score(seed: seed)
                        let features = wavelet.featureVector(seed: seed, config: config)
                        if features.count != featureCount {
                            break
                        }
                        let target = config.includeNeighborPenalty ? (cpu.totalScore - cpu.neighborCorrPenalty) : cpu.totalScore
                        local.append(Sample(seed: seed, features: features, target: target, cpuTotal: cpu.totalScore))
                        seed = nextV2Seed(seed, by: 1)
                        localProgress += 1
                        if localProgress % progressStride == 0 {
                            progress.add(progressStride)
                        }
                    }
                    let rem = localProgress % progressStride
                    if rem > 0 { progress.add(rem) }

                    collector.append(local)
                    group.leave()
                }
            }

            group.wait()
            let collected = collector.count
            if collected != n {
                throw GobxError.usage("Training aborted early: collected \(collected)/\(n) samples.")
            }
            samples = collector.drain()
        }

        let tail = samples.sorted { $0.cpuTotal > $1.cpuTotal }.prefix(min(topCount, samples.count))
        var train: [FeatureSample] = samples.map { FeatureSample(features: $0.features, target: $0.target) }
        if tailMult > 1 && !tail.isEmpty {
            let tailSamples = tail.map { FeatureSample(features: $0.features, target: $0.target) }
            for _ in 1..<tailMult {
                train.append(contentsOf: tailSamples)
            }
        }

        let model = LinearModel.fitRidge(samples: train, lambda: ridgeLambda)

        let preds = samples.map { model.predict($0.features) }
        let targets = samples.map { $0.target }
        let mse = meanSquaredError(preds: preds, targets: targets)
        let corr = pearson(preds, targets)

        let outURL: URL = {
            if let outPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(outPath))
            }
            return defaultOutURL
        }()

        let weights = ProxyWeights(
            schemaVersion: ProxyWeights.schemaVersion,
            createdAt: Date(),
            imageSize: imageSize,
            featureCount: featureCount,
            config: config,
            bias: model.bias,
            weights: model.weights
        )
        try ProxyWeights.save(weights, to: outURL)

        print("train-proxy n=\(samples.count) tail=\(tail.count) tailMult=\(tailMult) ridge=\(String(format: "%.6f", ridgeLambda))")
        print("fit mse=\(String(format: "%.6f", mse)) corr=\(String(format: "%.4f", corr)) bias=\(String(format: "%.6f", model.bias))")
        print("wrote weights: \(outURL.path)")
    }

    private static func meanSquaredError(preds: [Double], targets: [Double]) -> Double {
        guard preds.count == targets.count, !preds.isEmpty else { return 0 }
        var sum: Double = 0
        for i in 0..<preds.count {
            let d = preds[i] - targets[i]
            sum += d * d
        }
        return sum / Double(preds.count)
    }

    private static func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = min(xs.count, ys.count)
        if n == 0 { return 0 }
        var meanX: Double = 0
        var meanY: Double = 0
        for i in 0..<n {
            meanX += xs[i]
            meanY += ys[i]
        }
        meanX /= Double(n)
        meanY /= Double(n)
        var sumXY: Double = 0
        var sumX2: Double = 0
        var sumY2: Double = 0
        for i in 0..<n {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sumXY += dx * dy
            sumX2 += dx * dx
            sumY2 += dy * dy
        }
        let denom = sqrt(sumX2 * sumY2)
        if denom == 0 { return 0 }
        return sumXY / denom
    }
}
