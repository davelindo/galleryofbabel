import Foundation

struct ScoreResult: Codable {
    let seed: UInt64
    let alphaEst: Double
    let alphaScore: Double
    let peakiness: Double
    let peakinessPenalty: Double
    let flatness: Double
    let flatnessPenalty: Double
    let neighborCorr: Double
    let neighborCorrPenalty: Double
    let totalScore: Double
}

struct SelftestGolden: Codable {
    struct Entry: Codable {
        let seed: UInt64
        let totalScoreBits: UInt64
    }

    let version: Int
    let createdAt: Date
    let entries: [Entry]
}

enum GobxError: Error, CustomStringConvertible {
    case usage(String)
    case invalidSeed(String)

    var description: String {
        switch self {
        case .usage(let s): return s
        case .invalidSeed(let s): return "Invalid seed: \(s)"
        }
    }
}

public enum Backend: String, Sendable {
    case cpu
    case mps
    case all
}

public enum GPUBackend: String, Sendable {
    case mps
    case metal
}
