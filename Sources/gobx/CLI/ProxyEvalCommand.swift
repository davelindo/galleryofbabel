import Dispatch
import Foundation

enum ProxyEvalCommand {
    private struct Record {
        let seed: UInt64
        let cpuScore: Double
        let proxyScore: Double
    }

    static func run(args: [String]) throws {
        let usage = "Usage: gobx proxy-eval [--n <n>] [--top <n>] [--gate <csv>] [--seed <seed>] [--weights <path>] [--gpu-backend mps|metal] [--report-every <sec>]"
        var parser = ArgumentParser(args: args, usage: usage)

        var n = 20_000
        var topCount = 500
        var gateCSV = "0.01,0.02,0.05"
        var seedArg: UInt64? = nil
        var weightsPath: String? = nil
        var gpuBackend: GPUBackend = .metal
        var reportEverySec = 1.0

        while let a = parser.pop() {
            switch a {
            case "--n":
                n = max(1, try parser.requireInt(for: "--n"))
            case "--top":
                topCount = max(1, try parser.requireInt(for: "--top"))
            case "--gate":
                gateCSV = try parser.requireValue(for: "--gate")
            case "--seed":
                seedArg = try parseSeed(try parser.requireValue(for: "--seed"))
            case "--weights":
                weightsPath = try parser.requireValue(for: "--weights")
            case "--gpu-backend":
                gpuBackend = try parser.requireEnum(for: "--gpu-backend", GPUBackend.self)
            case "--report-every":
                reportEverySec = max(0, try parser.requireDouble(for: "--report-every"))
            default:
                throw parser.unknown(a)
            }
        }

        let gates = try parseGates(gateCSV, usage: usage)
        let imageSize = 128
        let config = ProxyConfig.defaultConfig(for: gpuBackend, imageSize: imageSize)
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: config)
        let defaultWeightsURL = (gpuBackend == .metal) ? GobxPaths.metalProxyWeightsURL : GobxPaths.proxyWeightsURL
        let weightsURL = weightsPath.map { URL(fileURLWithPath: GobxPaths.expandPath($0)) } ?? defaultWeightsURL

        let weights: ProxyWeights
        if weightsPath != nil {
            guard let loaded = ProxyWeights.loadValid(from: weightsURL, imageSize: imageSize, featureCount: featureCount, expectedConfig: config) else {
                throw GobxError.usage("Invalid or missing weights at \(weightsURL.path)\n\n\(usage)")
            }
            weights = loaded
        } else {
            let loaded = ProxyWeights.loadOrDefault(from: weightsURL, imageSize: imageSize, featureCount: featureCount, expectedConfig: config)
            weights = loaded.weights
            if loaded.usedDefault {
                print("Warning: no proxy weights found, using zeros (\(weightsURL.path))")
            }
        }

        let v2Min = V2SeedSpace.min
        let v2MaxExclusive = V2SeedSpace.maxExclusive
        var seed = normalizeV2Seed(seedArg ?? UInt64.random(in: v2Min..<v2MaxExclusive))

        let scorer = Scorer(size: imageSize)
        var wavelet = WaveletProxy(size: imageSize)

        var records: [Record] = []
        records.reserveCapacity(n)

        let startNs = DispatchTime.now().uptimeNanoseconds
        var lastPrintNs = startNs

        for i in 0..<n {
            let cpu = scorer.score(seed: seed)
            let features = wavelet.featureVector(seed: seed, config: config)
            let proxyScore = weights.predict(features: features) + (config.includeNeighborPenalty ? cpu.neighborCorrPenalty : 0)
            records.append(Record(seed: seed, cpuScore: cpu.totalScore, proxyScore: proxyScore))
            seed = nextV2Seed(seed, by: 1)

            if reportEverySec > 0 {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastPrintNs >= UInt64(reportEverySec * 1e9) {
                    let dt = Double(now - startNs) / 1e9
                    let rate = Double(i + 1) / max(1e-9, dt)
                    print("scan \(i + 1)/\(n) (\(String(format: "%.0f", rate))/s)")
                    lastPrintNs = now
                }
            }
        }

        let cpuSorted = records.sorted { $0.cpuScore > $1.cpuScore }
        let topFinal = min(topCount, cpuSorted.count)
        let topCPU = cpuSorted.prefix(topFinal)
        let topCPUSet = Set(topCPU.map { $0.seed })

        let proxySorted = records.sorted { $0.proxyScore > $1.proxyScore }

        print("proxy-eval n=\(records.count) top=\(topFinal) gates=\(formatGateList(gates))")
        for gate in gates {
            let keep = max(1, min(records.count, Int(Double(records.count) * gate)))
            let topProxySet = Set(proxySorted.prefix(keep).map { $0.seed })
            let hits = topCPUSet.intersection(topProxySet).count
            let recall = topCPUSet.isEmpty ? 0.0 : Double(hits) / Double(topCPUSet.count)
            let thresh = proxySorted[min(keep - 1, proxySorted.count - 1)].proxyScore
            print("gate \(formatPercent(gate)) recall \(format(recall)) hits \(hits)/\(topCPUSet.count) thr=\(format(thresh))")
        }
    }

    private static func parseGates(_ s: String, usage: String) throws -> [Double] {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [Double] = []
        for p in parts where !p.isEmpty {
            guard let v = Double(p), v > 0, v <= 1 else {
                throw GobxError.usage("Invalid --gate value: \(p)\n\n\(usage)")
            }
            out.append(v)
        }
        if out.isEmpty {
            throw GobxError.usage("Invalid --gate value: \(s)\n\n\(usage)")
        }
        return out.sorted()
    }

    private static func format(_ v: Double) -> String {
        String(format: "%.4f", v)
    }

    private static func formatPercent(_ v: Double) -> String {
        String(format: "%.2f%%", v * 100.0)
    }

    private static func formatGateList(_ gates: [Double]) -> String {
        gates.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }
}
