import Foundation

public struct ExploreOptions {
    var count: Int? = nil
    var endlessFlag: Bool = false

    var startSeed: UInt64? = nil
    var threads: Int? = nil
    var batch: Int = 64
    var batchSpecified: Bool = false
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
    public var reportEverySec: Double = 1.0
    public var uiEnabled: Bool? = nil
    var setupConfig: Bool = false
    public var statsEnabled: Bool? = nil
    public var statsUrl: String? = nil
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
    var mpsInflightSpecified: Bool = false
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
    public var gpuThroughputProfile: GPUThroughputProfile = .heater

    var endless: Bool { endlessFlag || count == nil }

    public init() {}
}

extension ExploreOptions {
    public static func parse(args: [String]) throws -> ExploreOptions {
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
            case "--report-every":
                o.reportEverySec = try parser.requireDouble(for: "--report-every")
            case "--gpu-profile":
                let raw = try parser.requireValue(for: "--gpu-profile")
                guard let profile = GPUThroughputProfile.parse(raw) else {
                    throw GobxError.usage("Invalid --gpu-profile: \(raw) (use dabbling|interested|lets-go|heater)")
                }
                o.gpuThroughputProfile = profile
            case "--submit":
                o.doSubmit = true
                o.doSubmitSpecified = true
            case "--no-submit":
                o.doSubmit = false
                o.doSubmitSpecified = true
            case "--ui":
                o.uiEnabled = true
            case "--no-ui":
                o.uiEnabled = false
            case "--setup":
                o.setupConfig = true
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
