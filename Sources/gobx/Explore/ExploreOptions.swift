import Foundation

struct ExploreOptions {
    var count: Int? = nil
    var endlessFlag: Bool = false

    var startSeed: UInt64? = nil
    var threads: Int? = nil
    var batch: Int = 64
    var backend: Backend = .cpu
    var topN: Int? = nil

    var doSubmit: Bool = false
    var minScore: Double = -8.662
    var minScoreSpecified: Bool = false
    var refreshEverySec: Double = 180.0
    var reportEverySec: Double = 1.0

    var seedMode: SeedMode = .state
    var statePath: String? = nil
    var stateReset: Bool = false
    var stateWriteEverySec: Double = 15.0
    var claimSize: Int = 16384

    var mpsVerifyMargin: Double = 0.0
    var mpsMarginSpecified: Bool = false
    var mpsInflight: Int = 2
    var mpsReinitEverySec: Double = 0.0

    var mpsTwoStage: Bool = false
    var mpsStage1Size: Int = 64
    var mpsStage1Margin: Double = 0.2
    var mpsStage1MarginSpecified: Bool = false
    var mpsStage2Batch: Int = 64

    var endless: Bool { endlessFlag || count == nil }
}

extension ExploreOptions {
    static func parse(args: [String]) throws -> ExploreOptions {
        var parser = ArgumentParser(args: args, usage: gobxHelpText)
        var o = ExploreOptions()

        while let a = parser.pop() {
            switch a {
            case "--count":
                o.count = try parser.requireInt(for: "--count")
            case "--endless":
                o.endlessFlag = true
            case "--start":
                o.startSeed = try parseSeed(try parser.requireValue(for: "--start"))
                o.stateReset = true
                o.seedMode = .state
            case "--threads":
                o.threads = try parser.requireInt(for: "--threads")
            case "--batch":
                o.batch = try parser.requireInt(for: "--batch")
            case "--backend":
                o.backend = try parser.requireEnum(for: "--backend", Backend.self)
            case "--top":
                o.topN = try parser.requireInt(for: "--top")
            case "--submit":
                o.doSubmit = true
            case "--min-score":
                o.minScore = try parser.requireDouble(for: "--min-score")
                o.minScoreSpecified = true
            case "--refresh-every":
                o.refreshEverySec = try parser.requireDouble(for: "--refresh-every")
            case "--report-every":
                o.reportEverySec = try parser.requireDouble(for: "--report-every")
            case "--seed-mode":
                o.seedMode = try parser.requireEnum(for: "--seed-mode", SeedMode.self)
            case "--state":
                o.statePath = try parser.requireValue(for: "--state")
                o.seedMode = .state
            case "--state-reset":
                o.stateReset = true
                o.seedMode = .state
            case "--state-write-every":
                o.stateWriteEverySec = try parser.requireDouble(for: "--state-write-every")
            case "--claim":
                o.claimSize = max(256, try parser.requireInt(for: "--claim"))
            case "--mps-margin":
                o.mpsVerifyMargin = try parser.requireDouble(for: "--mps-margin")
                o.mpsMarginSpecified = true
            case "--mps-inflight":
                o.mpsInflight = max(1, try parser.requireInt(for: "--mps-inflight"))
            case "--mps-reinit-every":
                o.mpsReinitEverySec = max(0.0, try parser.requireDouble(for: "--mps-reinit-every"))
            case "--mps-two-stage":
                o.mpsTwoStage = true
            case "--mps-stage1-size":
                o.mpsStage1Size = try parser.requireInt(for: "--mps-stage1-size")
            case "--mps-stage1-margin":
                o.mpsStage1Margin = max(0.0, try parser.requireDouble(for: "--mps-stage1-margin"))
                o.mpsStage1MarginSpecified = true
            case "--mps-stage2-batch":
                o.mpsStage2Batch = max(1, try parser.requireInt(for: "--mps-stage2-batch"))
            default:
                throw parser.unknown(a)
            }
        }

        if let c = o.count, c <= 0 {
            o.count = nil
            o.endlessFlag = true
        }

        return o
    }
}

