import Foundation

enum ScoreCommand {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx score <seed> [--backend cpu|mps] [--batch <n>] [--gpu-backend mps|metal] [--json]"
        var parser = ArgumentParser(args: args, usage: usage)
        let seed = try parseSeed(try parser.requirePositional("seed"))

        var backend: Backend = .cpu
        var batch: Int = 1
        var json = false
        var gpuBackend: GPUBackend = .metal

        while let a = parser.pop() {
            switch a {
            case "--json":
                json = true
            case "--backend":
                let b = try parser.requireEnum(for: "--backend", Backend.self)
                if b == .all {
                    throw GobxError.usage("score does not support --backend all\n\n\(usage)")
                }
                backend = b
            case "--batch":
                batch = max(1, try parser.requireInt(for: "--batch"))
            case "--gpu-backend":
                gpuBackend = try parser.requireEnum(for: "--gpu-backend", GPUBackend.self)
            default:
                throw parser.unknown(a)
            }
        }

        switch backend {
        case .cpu:
            let scorer = Scorer(size: 128)
            let r = scorer.score(seed: seed)
            if json {
                let data = try JSONEncoder().encode(r)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            } else {
                print(r)
            }
        case .mps:
            let score: Double
            switch gpuBackend {
            case .mps:
                let scorer = try MPSScorer(batchSize: max(1, batch))
                score = Double(scorer.score(seeds: [seed]).first ?? 0)
            case .metal:
                let scorer = try MetalPyramidScorer(batchSize: max(1, batch))
                score = Double(scorer.score(seeds: [seed]).first ?? 0)
            }
            let gpuLabel = gpuBackend == .metal ? "metal" : "mps"
            if json {
                let obj: [String: Any] = ["seed": seed, "score": score, "backend": gpuLabel]
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            } else {
                print("seed=\(seed) score=\(String(format: "%.6f", score)) backend=\(gpuLabel) (approx)")
            }
        case .all:
            // guarded above
            break
        }
    }
}
