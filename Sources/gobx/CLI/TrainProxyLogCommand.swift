import Foundation

enum TrainProxyLogCommand {
    private struct LogEntry: Codable {
        let seed: UInt64
        let energies: [Double]
        let energyRatios: [Double]
        let logEnergies: [Double]
        let shapeLevels: [Int]
        let shapeMaxOverEnergy: [Double]
        let shapeKurtosis: [Double]
        let alphaProxy: Double
        let neighborCorrValue: Double
        let predictedScore: Double
        let cpuScore: Double
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

        static func solve(xtx: [Double], xty: [Double], dim: Int, lambda: Double) -> LinearModel {
            var xtx = xtx
            let xty = xty
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

    private struct GateRecall {
        let keepPercent: Double
        let hits: Int
        let recall: Double
        let threshold: Double
    }

    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let reportEverySec: Double
        private let startNs: UInt64
        private var lastPrintNs: UInt64
        private var processed: Int = 0

        init(reportEverySec: Double) {
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
                print("scan \(processed) (\(String(format: "%.0f", rate))/s)")
                lastPrintNs = now
            }
            lock.unlock()
        }
    }

    private struct NormalEqAccumulator {
        let dim: Int
        var xtx: [Double]
        var xty: [Double]

        init(dim: Int) {
            self.dim = dim
            self.xtx = [Double](repeating: 0, count: dim * dim)
            self.xty = [Double](repeating: 0, count: dim)
        }

        mutating func add(features: [Double], target: Double) {
            var x = [Double](repeating: 0, count: dim)
            x[0] = 1.0
            for i in 0..<min(features.count, dim - 1) {
                x[i + 1] = features[i]
            }
            for i in 0..<dim {
                xty[i] += x[i] * target
                for j in 0..<dim {
                    xtx[i * dim + j] += x[i] * x[j]
                }
            }
        }
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx train-proxy-log [--in <path>] [--out <path>] [--report-every <sec>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var inPath: String? = nil
        var outPath: String? = nil
        var reportEverySec = 1.0

        while let a = parser.pop() {
            switch a {
            case "--in":
                inPath = try parser.requireValue(for: "--in")
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            case "--report-every":
                reportEverySec = max(0, try parser.requireDouble(for: "--report-every"))
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

        let inURL = inPath.map { GobxPaths.resolveURL($0) }
            ?? GobxPaths.configDir.appendingPathComponent("gobx-proxy-samples.jsonl")
        let outURL = outPath.map { GobxPaths.resolveURL($0) } ?? GobxPaths.metalProxyWeightsURL

        let progress = ProgressTracker(reportEverySec: reportEverySec)
        var accumulator = NormalEqAccumulator(dim: featureCount + 1)
        var valFeatures: [Double] = []
        var valTargets: [Double] = []
        var trainCount = 0
        var valCount = 0
        var decodeErrors = 0
        var featureErrors = 0

        try forEachJSONL(inURL: inURL) { line in
            guard let entry = decodeEntry(line: line, errors: &decodeErrors) else { return }
            let features = composeFeatures(entry: entry, config: config)
            if features.count != featureCount {
                featureErrors += 1
                return
            }
            if entry.seed % splitMod == 0 {
                valFeatures.append(contentsOf: features)
                valTargets.append(entry.cpuScore)
                valCount += 1
            } else {
                accumulator.add(features: features, target: entry.cpuScore)
                trainCount += 1
            }
            progress.add(1)
        }

        guard trainCount > 0 else {
            throw GobxError.usage("No training samples found in \(inURL.path).")
        }

        let model = LinearModel.solve(xtx: accumulator.xtx, xty: accumulator.xty, dim: featureCount + 1, lambda: ridgeLambda)

        var trainStats = FitStats()
        try forEachJSONL(inURL: inURL) { line in
            guard let entry = decodeEntry(line: line, errors: &decodeErrors) else { return }
            if entry.seed % splitMod == 0 { return }
            let features = composeFeatures(entry: entry, config: config)
            if features.count != featureCount { return }
            let pred = model.predict(features)
            trainStats.add(pred: pred, target: entry.cpuScore)
        }

        var valStats = FitStats()
        var valPreds: [Double] = []
        valPreds.reserveCapacity(valTargets.count)
        if !valTargets.isEmpty {
            var offset = 0
            for target in valTargets {
                let slice = Array(valFeatures[offset..<(offset + featureCount)])
                let pred = model.predict(slice)
                valPreds.append(pred)
                valStats.add(pred: pred, target: target)
                offset += featureCount
            }
        }

        let weights = ProxyWeights(
            schemaVersion: ProxyWeights.schemaVersion,
            createdAt: Date(),
            imageSize: imageSize,
            featureCount: featureCount,
            config: config,
            objective: "ridge-log",
            quantile: nil,
            scoreShift: nil,
            scoreShiftQuantile: nil,
            bias: model.bias,
            weights: model.weights
        )
        try ProxyWeights.save(weights, to: outURL)

        let total = trainCount + valCount
        print("train-proxy-log n=\(total) train=\(trainCount) val=\(valCount) ridge=\(String(format: "%.6f", ridgeLambda))")
        if decodeErrors > 0 || featureErrors > 0 {
            print("log-errors decode=\(decodeErrors) feature=\(featureErrors)")
        }
        print("fit train mse=\(String(format: "%.6f", trainStats.mse())) corr=\(String(format: "%.4f", trainStats.corr())) bias=\(String(format: "%.6f", model.bias))")
        if !valTargets.isEmpty {
            print("fit val mse=\(String(format: "%.6f", valStats.mse())) corr=\(String(format: "%.4f", valStats.corr()))")
            let recalls = recallAtKeeps(preds: valPreds, targets: valTargets, topCount: valTop, keepPercents: gateKeeps)
            for r in recalls {
                print("gate \(String(format: "%.2f", r.keepPercent))% recall \(String(format: "%.4f", r.recall)) hits \(r.hits)/\(valTop) thr=\(String(format: "%.4f", r.threshold))")
            }
        }
        print("wrote weights: \(outURL.path)")
    }

    private static func decodeEntry(line: Data, errors: inout Int) -> LogEntry? {
        if line.isEmpty { return nil }
        do {
            return try JSONDecoder().decode(LogEntry.self, from: line)
        } catch {
            errors += 1
            return nil
        }
    }

    private static func composeFeatures(entry: LogEntry, config: ProxyConfig) -> [Double] {
        let levels = entry.energies.count
        let ratioLimit = max(0, config.maxRatioLevels ?? (levels - 1))
        let ratioCount = min(max(0, levels - 1), ratioLimit)
        let shapeCount = entry.shapeLevels.count
        let expectShapes = shapeCount > 0 ? shapeCount : entry.shapeMaxOverEnergy.count
        let totalCount = (config.includeEnergies ? levels : 0)
            + ratioCount
            + (config.includeLogEnergyFeatures ? levels : 0)
            + (config.includeShapeFeatures ? (expectShapes * 2) : 0)
            + (config.includeAlphaFeature ? 1 : 0)
            + (config.includeNeighborCorrFeature ? 1 : 0)

        var features: [Double] = []
        features.reserveCapacity(totalCount)
        if config.includeEnergies {
            features.append(contentsOf: entry.energies)
        }
        if ratioCount > 0 {
            features.append(contentsOf: entry.energyRatios.prefix(ratioCount))
        }
        if config.includeLogEnergyFeatures {
            features.append(contentsOf: entry.logEnergies)
        }
        if config.includeShapeFeatures {
            features.append(contentsOf: entry.shapeMaxOverEnergy)
            features.append(contentsOf: entry.shapeKurtosis)
        }
        if config.includeAlphaFeature {
            features.append(entry.alphaProxy)
        }
        if config.includeNeighborCorrFeature {
            features.append(entry.neighborCorrValue)
        }
        return features
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

    private static func forEachJSONL(inURL: URL, handler: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: inURL)
        defer { try? handle.close() }
        var buffer = Data()
        let newline = Data([0x0a])

        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                handler(line)
            }
        }

        if !buffer.isEmpty {
            handler(buffer)
        }
    }
}
