import Dispatch
import Foundation

enum ProxyLogCommand {
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

    private final class JSONLWriter: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()

        init(url: URL, append: Bool) throws {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                if append {
                    handle = try FileHandle(forWritingTo: url)
                    handle.seekToEndOfFile()
                } else {
                    throw GobxError.usage("Output already exists: \(url.path) (use --append to add)")
                }
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try FileHandle(forWritingTo: url)
            }
        }

        func append(_ data: Data) {
            lock.lock()
            handle.write(data)
            handle.write(Data([0x0a]))
            lock.unlock()
        }

        deinit {
            try? handle.close()
        }
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx proxy-log [--n <n>] [--out <path>] [--report-every <sec>] [--threads <n>] [--append]"
        var parser = ArgumentParser(args: args, usage: usage)

        var n = 100_000
        var outPath: String? = nil
        var reportEverySec = 1.0
        var threadsArg: Int? = nil
        var append = false

        while let a = parser.pop() {
            switch a {
            case "--n":
                n = max(1, try parser.requireInt(for: "--n"))
            case "--out":
                outPath = try parser.requireValue(for: "--out")
            case "--report-every":
                reportEverySec = max(0, try parser.requireDouble(for: "--report-every"))
            case "--threads":
                threadsArg = max(1, try parser.requireInt(for: "--threads"))
            case "--append":
                append = true
            default:
                throw parser.unknown(a)
            }
        }

        let imageSize = 128
        let gpuBackend: GPUBackend = .metal
        let config = ProxyConfig.defaultConfig(for: gpuBackend, imageSize: imageSize)
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: config)
        let defaultWeightsURL = GobxPaths.metalProxyWeightsURL
        let weightsURL = defaultWeightsURL
        let (weights, usedDefault) = ProxyWeights.loadOrDefault(
            from: weightsURL,
            imageSize: imageSize,
            featureCount: featureCount,
            expectedConfig: config
        )
        if usedDefault {
            print("Warning: no proxy weights found, using zeros (\(weightsURL.path))")
        }

        let outURL = outPath.map { GobxPaths.resolveURL($0) }
            ?? GobxPaths.configDir.appendingPathComponent("gobx-proxy-samples.jsonl")
        let writer = try JSONLWriter(url: outURL, append: append)

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

        let progress = ProgressTracker(total: n, reportEverySec: reportEverySec)
        let v2Min = V2SeedSpace.min
        let v2MaxExclusive = V2SeedSpace.maxExclusive
        let baseSeed = normalizeV2Seed(UInt64.random(in: v2Min..<v2MaxExclusive))

        let available = ProcessInfo.processInfo.activeProcessorCount
        let threadCount = min(max(1, threadsArg ?? 1), max(1, min(n, available)))

        if threadCount == 1 {
            var wavelet = WaveletProxy(size: imageSize)
            let scorer = Scorer(size: imageSize)
            let encoder = JSONEncoder()
            var seed = baseSeed
            for _ in 0..<n {
                let cpu = scorer.score(seed: seed)
                let breakdown = wavelet.featureBreakdown(seed: seed, config: config)
                let predicted = weights.predict(features: breakdown.featureVector)
                    + (config.includeNeighborPenalty ? cpu.neighborCorrPenalty : 0)
                let entry = LogEntry(
                    seed: seed,
                    energies: breakdown.energies,
                    energyRatios: breakdown.energyRatios,
                    logEnergies: breakdown.logEnergies,
                    shapeLevels: breakdown.shapeLevels,
                    shapeMaxOverEnergy: breakdown.shapeMaxOverEnergy,
                    shapeKurtosis: breakdown.shapeKurtosis,
                    alphaProxy: breakdown.alphaProxy,
                    neighborCorrValue: breakdown.neighborCorrValue,
                    predictedScore: predicted,
                    cpuScore: cpu.totalScore
                )
                let data = try encoder.encode(entry)
                writer.append(data)
                seed = nextV2Seed(seed, by: 1)
                progress.add(1)
            }
        } else {
            let baseOffset = baseSeed &- V2SeedSpace.min
            let spaceSize = V2SeedSpace.size
            let chunk = (n + threadCount - 1) / threadCount
            let group = DispatchGroup()
            let progressStride = 128
            let flushStride = 128

            for t in 0..<threadCount {
                let startIndex = t * chunk
                let endIndex = min(n, startIndex + chunk)
                if startIndex >= endIndex { continue }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let scorer = Scorer(size: imageSize)
                    var wavelet = WaveletProxy(size: imageSize)
                    let encoder = JSONEncoder()
                    var localBuffer: [Data] = []
                    localBuffer.reserveCapacity(flushStride)
                    let seedOffset = (baseOffset &+ UInt64(startIndex)) % spaceSize
                    var seed = V2SeedSpace.min &+ seedOffset
                    var localProgress = 0

                    for _ in startIndex..<endIndex {
                        let cpu = scorer.score(seed: seed)
                        let breakdown = wavelet.featureBreakdown(seed: seed, config: config)
                        let predicted = weights.predict(features: breakdown.featureVector)
                            + (config.includeNeighborPenalty ? cpu.neighborCorrPenalty : 0)
                        let entry = LogEntry(
                            seed: seed,
                            energies: breakdown.energies,
                            energyRatios: breakdown.energyRatios,
                            logEnergies: breakdown.logEnergies,
                            shapeLevels: breakdown.shapeLevels,
                            shapeMaxOverEnergy: breakdown.shapeMaxOverEnergy,
                            shapeKurtosis: breakdown.shapeKurtosis,
                            alphaProxy: breakdown.alphaProxy,
                            neighborCorrValue: breakdown.neighborCorrValue,
                            predictedScore: predicted,
                            cpuScore: cpu.totalScore
                        )
                        if let data = try? encoder.encode(entry) {
                            localBuffer.append(data)
                        }
                        if localBuffer.count >= flushStride {
                            for data in localBuffer {
                                writer.append(data)
                            }
                            localBuffer.removeAll(keepingCapacity: true)
                        }

                        seed = nextV2Seed(seed, by: 1)
                        localProgress += 1
                        if localProgress % progressStride == 0 {
                            progress.add(progressStride)
                        }
                    }

                    if !localBuffer.isEmpty {
                        for data in localBuffer {
                            writer.append(data)
                        }
                    }

                    let rem = localProgress % progressStride
                    if rem > 0 { progress.add(rem) }
                    group.leave()
                }
            }

            group.wait()
        }

        print("proxy-log n=\(n) wrote=\(outURL.path)")
    }
}
