import Foundation

struct ExploreOptions {
    var count: Int? = nil
    var endlessFlag: Bool = false

    var startSeed: UInt64? = nil
    var threads: Int? = nil
    var batch: Int = 64
    var backend: Backend = .cpu
    var backendSpecified: Bool = false
    var gpuBackend: GPUBackend = .metal
    var gpuBackendSpecified: Bool = false
    var topN: Int? = nil

    var doSubmit: Bool = false
    var doSubmitSpecified: Bool = false
    var minScore: Double = -8.662
    var minScoreSpecified: Bool = false
    var topUniqueUsers: Bool = false
    var topUniqueUsersSpecified: Bool = false
    var refreshEverySec: Double = 180.0
    var reportEverySec: Double = 1.0
    var uiEnabled: Bool? = nil
    var setupConfig: Bool = false
    var memGuardMaxGB: Double = 0.0
    var memGuardMaxFrac: Double = 0.0
    var memGuardMaxGBSpecified: Bool = false
    var memGuardMaxFracSpecified: Bool = false
    var memGuardEverySec: Double = 5.0

    var seedMode: SeedMode = .state
    var statePath: String? = nil
    var stateReset: Bool = false
    var stateWriteEverySec: Double = 15.0
    var claimSize: Int = 16384

    var mpsVerifyMargin: Double = 0.0
    var mpsMarginSpecified: Bool = false
    var mpsMarginAuto: Bool = false
    var mpsMarginAutoSpecified: Bool = false
    var mpsInflight: Int = 2
    var mpsWorkers: Int = 0
    var mpsInflightAuto: Bool = false
    var mpsInflightMin: Int = 0
    var mpsInflightMax: Int = 0
    var mpsInflightMinSpecified: Bool = false
    var mpsInflightMaxSpecified: Bool = false
    var mpsReinitEverySec: Double = 0.0
    var mpsBatchAuto: Bool = false
    var mpsBatchAutoSpecified: Bool = false
    var mpsBatchMin: Int = 0
    var mpsBatchMax: Int = 0
    var mpsBatchMinSpecified: Bool = false
    var mpsBatchMaxSpecified: Bool = false
    var mpsBatchTuneEverySec: Double = 2.0

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
                o.backendSpecified = true
            case "--gpu-backend":
                o.gpuBackend = try parser.requireEnum(for: "--gpu-backend", GPUBackend.self)
                o.gpuBackendSpecified = true
            case "--top":
                o.topN = try parser.requireInt(for: "--top")
            case "--submit":
                o.doSubmit = true
                o.doSubmitSpecified = true
            case "--top-unique-users":
                o.topUniqueUsers = true
                o.topUniqueUsersSpecified = true
            case "--min-score":
                o.minScore = try parser.requireDouble(for: "--min-score")
                o.minScoreSpecified = true
            case "--refresh-every":
                o.refreshEverySec = try parser.requireDouble(for: "--refresh-every")
            case "--report-every":
                o.reportEverySec = try parser.requireDouble(for: "--report-every")
            case "--ui":
                o.uiEnabled = true
            case "--no-ui":
                o.uiEnabled = false
            case "--setup":
                o.setupConfig = true
            case "--mem-guard-gb":
                o.memGuardMaxGB = max(0.0, try parser.requireDouble(for: "--mem-guard-gb"))
                o.memGuardMaxGBSpecified = true
            case "--mem-guard-frac":
                o.memGuardMaxFrac = max(0.0, try parser.requireDouble(for: "--mem-guard-frac"))
                o.memGuardMaxFracSpecified = true
            case "--mem-guard-every":
                o.memGuardEverySec = max(0.25, try parser.requireDouble(for: "--mem-guard-every"))
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
            case "--mps-margin-auto":
                o.mpsMarginAuto = true
                o.mpsMarginAutoSpecified = true
            case "--mps-inflight":
                o.mpsInflight = max(1, try parser.requireInt(for: "--mps-inflight"))
            case "--mps-inflight-auto":
                o.mpsInflightAuto = true
            case "--mps-inflight-min":
                o.mpsInflightMin = max(1, try parser.requireInt(for: "--mps-inflight-min"))
                o.mpsInflightMinSpecified = true
            case "--mps-inflight-max":
                o.mpsInflightMax = max(1, try parser.requireInt(for: "--mps-inflight-max"))
                o.mpsInflightMaxSpecified = true
            case "--mps-workers":
                o.mpsWorkers = try parser.requireInt(for: "--mps-workers")
            case "--mps-reinit-every":
                o.mpsReinitEverySec = max(0.0, try parser.requireDouble(for: "--mps-reinit-every"))
            case "--mps-batch-auto":
                o.mpsBatchAuto = true
                o.mpsBatchAutoSpecified = true
            case "--mps-batch-min":
                o.mpsBatchMin = max(1, try parser.requireInt(for: "--mps-batch-min"))
                o.mpsBatchMinSpecified = true
            case "--mps-batch-max":
                o.mpsBatchMax = max(1, try parser.requireInt(for: "--mps-batch-max"))
                o.mpsBatchMaxSpecified = true
            case "--mps-batch-tune-every":
                o.mpsBatchTuneEverySec = max(0.25, try parser.requireDouble(for: "--mps-batch-tune-every"))
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
