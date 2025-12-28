import Dispatch
import Foundation

enum TrainProxyCommand {
    private struct Sample {
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

        static func fitRidge(samples: [Sample], lambda: Double) -> LinearModel {
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

    private struct FitStats {
        var count: Int = 0
        var sumError2: Double = 0
        var sumX: Double = 0
        var sumY: Double = 0
        var sumX2: Double = 0
        var sumY2: Double = 0
        var sumXY: Double = 0

        mutating func add(pred: Double, target: Double) {
            count += 1
            let err = pred - target
            sumError2 += err * err
            sumX += pred
            sumY += target
            sumX2 += pred * pred
            sumY2 += target * target
            sumXY += pred * target
        }

        func mse() -> Double {
            guard count > 0 else { return 0 }
            return sumError2 / Double(count)
        }

        func corr() -> Double {
            guard count > 0 else { return 0 }
            let n = Double(count)
            let meanX = sumX / n
            let meanY = sumY / n
            let cov = (sumXY / n) - (meanX * meanY)
            let varX = (sumX2 / n) - (meanX * meanX)
            let varY = (sumY2 / n) - (meanY * meanY)
            let denom = sqrt(max(0.0, varX * varY))
            if denom == 0 { return 0 }
            return cov / denom
        }
    }

    private final class ProgressTracker: @unchecked Sendable {
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

    private final class SampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var train: [Sample]
        private var val: [Sample]

        init(trainCap: Int, valCap: Int) {
            train = []
            val = []
            train.reserveCapacity(trainCap)
            val.reserveCapacity(valCap)
        }

        func append(train localTrain: [Sample], val localVal: [Sample]) {
            lock.lock()
            train.append(contentsOf: localTrain)
            val.append(contentsOf: localVal)
            lock.unlock()
        }

        func drain() -> (train: [Sample], val: [Sample]) {
            lock.lock()
            let outTrain = train
            let outVal = val
            lock.unlock()
            return (outTrain, outVal)
        }
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx train-proxy [--n <n>] [--seed <seed>] [--out <path>] [--report-every <sec>] [--threads <n>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var n = 1_000_000
        var seedArg: UInt64? = nil
        var outPath: String? = nil
        var reportEverySec = 1.0
        var threadsArg: Int? = nil

        while let a = parser.pop() {
            switch a {
            case "--n":
                n = max(1, try parser.requireInt(for: "--n"))
            case "--seed":
                seedArg = try parseSeed(try parser.requireValue(for: "--seed"))
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            case "--report-every":
                reportEverySec = max(0, try parser.requireDouble(for: "--report-every"))
            case "--threads":
                threadsArg = max(1, try parser.requireInt(for: "--threads"))
            default:
                throw parser.unknown(a)
            }
        }

        let imageSize = 128
        let config = ProxyConfig.metalDefault(imageSize: imageSize)
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: config)
        let ridgeLambda = 1e-3
        let splitMod: UInt64 = 10
        let valTop = 500
        let gateKeeps: [Double] = [1.0, 2.0, 5.0]

        let v2Min = V2SeedSpace.min
        let v2MaxExclusive = V2SeedSpace.maxExclusive
        let baseSeed = normalizeV2Seed(seedArg ?? UInt64.random(in: v2Min..<v2MaxExclusive))
        let outURL: URL = {
            if let outPath {
                return URL(fileURLWithPath: GobxPaths.expandPath(outPath))
            }
            return GobxPaths.metalProxyWeightsURL
        }()

        let progress = ProgressTracker(total: n, reportEverySec: reportEverySec)
        let available = ProcessInfo.processInfo.activeProcessorCount
        let threadCount = min(max(1, threadsArg ?? 1), max(1, min(n, available)))
        let valCap = max(1, n / Int(splitMod))
        let collector = SampleCollector(trainCap: n - valCap, valCap: valCap)

        if threadCount == 1 {
            let scorer = Scorer(size: imageSize)
            var wavelet = WaveletProxy(size: imageSize)
            var seed = baseSeed
            for _ in 0..<n {
                let cpu = scorer.score(seed: seed)
                let features = wavelet.featureVector(seed: seed, config: config)
                if features.count != featureCount {
                    throw GobxError.usage("Wavelet features expected \(featureCount) values, got \(features.count)")
                }
                let target = config.includeNeighborPenalty ? (cpu.totalScore - cpu.neighborCorrPenalty) : cpu.totalScore
                let sample = Sample(features: features, target: target)
                if seed % splitMod == 0 {
                    collector.append(train: [], val: [sample])
                } else {
                    collector.append(train: [sample], val: [])
                }
                seed = nextV2Seed(seed, by: 1)
                progress.add(1)
            }
        } else {
            let spaceSize = V2SeedSpace.size
            let baseOffset = baseSeed &- V2SeedSpace.min
            let chunk = (n + threadCount - 1) / threadCount
            let group = DispatchGroup()
            let progressStride = 256

            for t in 0..<threadCount {
                let startIndex = t * chunk
                let endIndex = min(n, startIndex + chunk)
                if startIndex >= endIndex { continue }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let scorer = Scorer(size: imageSize)
                    var wavelet = WaveletProxy(size: imageSize)
                    var localTrain: [Sample] = []
                    var localVal: [Sample] = []
                    localTrain.reserveCapacity(endIndex - startIndex)
                    localVal.reserveCapacity(max(1, (endIndex - startIndex) / Int(splitMod)))

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
                        let sample = Sample(features: features, target: target)
                        if seed % splitMod == 0 {
                            localVal.append(sample)
                        } else {
                            localTrain.append(sample)
                        }
                        seed = nextV2Seed(seed, by: 1)
                        localProgress += 1
                        if localProgress % progressStride == 0 {
                            progress.add(progressStride)
                        }
                    }
                    let rem = localProgress % progressStride
                    if rem > 0 { progress.add(rem) }
                    collector.append(train: localTrain, val: localVal)
                    group.leave()
                }
            }

            group.wait()
        }

        var (trainSamples, valSamples) = collector.drain()
        if trainSamples.isEmpty, !valSamples.isEmpty {
            trainSamples = valSamples
            valSamples = []
        }
        if trainSamples.isEmpty {
            throw GobxError.usage("No training samples collected.")
        }

        let model = LinearModel.fitRidge(samples: trainSamples, lambda: ridgeLambda)

        var trainStats = FitStats()
        for s in trainSamples {
            let pred = model.predict(s.features)
            trainStats.add(pred: pred, target: s.target)
        }
        var valStats = FitStats()
        var valPreds: [Double] = []
        var valTargets: [Double] = []
        if !valSamples.isEmpty {
            valPreds.reserveCapacity(valSamples.count)
            valTargets.reserveCapacity(valSamples.count)
            for s in valSamples {
                let pred = model.predict(s.features)
                valStats.add(pred: pred, target: s.target)
                valPreds.append(pred)
                valTargets.append(s.target)
            }
        }

        let weights = ProxyWeights(
            schemaVersion: ProxyWeights.schemaVersion,
            createdAt: Date(),
            imageSize: imageSize,
            featureCount: featureCount,
            config: config,
            objective: "ridge",
            quantile: nil,
            scoreShift: nil,
            scoreShiftQuantile: nil,
            bias: model.bias,
            weights: model.weights
        )
        try ProxyWeights.save(weights, to: outURL)

        print("train-proxy n=\(trainSamples.count + valSamples.count) train=\(trainSamples.count) val=\(valSamples.count) ridge=\(String(format: "%.6f", ridgeLambda))")
        print("fit train mse=\(String(format: "%.6f", trainStats.mse())) corr=\(String(format: "%.4f", trainStats.corr())) bias=\(String(format: "%.6f", model.bias))")
        if !valSamples.isEmpty {
            print("fit val mse=\(String(format: "%.6f", valStats.mse())) corr=\(String(format: "%.4f", valStats.corr()))")
            let recalls = recallAtKeeps(preds: valPreds, targets: valTargets, topCount: valTop, keepPercents: gateKeeps)
            for r in recalls {
                print("gate \(String(format: "%.2f", r.keepPercent))% recall \(String(format: "%.4f", r.recall)) hits \(r.hits)/\(valTop) thr=\(String(format: "%.4f", r.threshold))")
            }
        }
        print("wrote weights: \(outURL.path)")
    }

    private struct GateRecall {
        let keepPercent: Double
        let hits: Int
        let recall: Double
        let threshold: Double
    }

    private static func recallAtKeeps(
        preds: [Double],
        targets: [Double],
        topCount: Int,
        keepPercents: [Double]
    ) -> [GateRecall] {
        guard preds.count == targets.count, !preds.isEmpty else { return [] }
        let n = preds.count
        let top = min(topCount, n)
        let cpuOrder = targets.indices.sorted { targets[$0] < targets[$1] }
        let topSet = Set(cpuOrder.prefix(top))
        let predOrder = preds.indices.sorted { preds[$0] < preds[$1] }

        var out: [GateRecall] = []
        out.reserveCapacity(keepPercents.count)
        for keepPct in keepPercents {
            let keep = max(1, Int((Double(n) * keepPct / 100.0).rounded(.up)))
            let chosen = predOrder.prefix(keep)
            var hits = 0
            for idx in chosen where topSet.contains(idx) {
                hits += 1
            }
            let thr = preds[chosen.last ?? predOrder[0]]
            let recall = top > 0 ? Double(hits) / Double(top) : 0.0
            out.append(GateRecall(keepPercent: keepPct, hits: hits, recall: recall, threshold: thr))
        }
        return out
    }
}
