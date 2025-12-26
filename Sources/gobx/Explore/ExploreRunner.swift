@preconcurrency import Dispatch
import Foundation

enum ExploreRunner {
    static func run(options: ExploreOptions) async throws {
        var count = options.count
        var endlessFlag = options.endlessFlag
        let startSeed = options.startSeed
        let threads = options.threads
        let batch = options.batch
        var backend = options.backend
        let backendSpecified = options.backendSpecified
        var gpuBackend = options.gpuBackend
        let gpuBackendSpecified = options.gpuBackendSpecified
        let topNArg = options.topN
        var doSubmit = options.doSubmit
        let doSubmitSpecified = options.doSubmitSpecified
        var minScore = options.minScore
        let minScoreSpecified = options.minScoreSpecified
        var topUniqueUsers = options.topUniqueUsers
        let topUniqueUsersSpecified = options.topUniqueUsersSpecified
        var mpsVerifyMargin = options.mpsVerifyMargin
        var mpsScoreShift: Double = 0.0
        let mpsMarginSpecified = options.mpsMarginSpecified
        var mpsMarginAuto = options.mpsMarginAuto
        let mpsMarginAutoSpecified = options.mpsMarginAutoSpecified
        let setupConfig = options.setupConfig
        let mpsInflight = options.mpsInflight
        let mpsWorkers = options.mpsWorkers
        var mpsInflightAuto = options.mpsInflightAuto
        var mpsInflightMin = options.mpsInflightMin
        var mpsInflightMax = options.mpsInflightMax
        let mpsInflightMinSpecified = options.mpsInflightMinSpecified
        let mpsInflightMaxSpecified = options.mpsInflightMaxSpecified
        let mpsReinitEverySec = options.mpsReinitEverySec
        var mpsBatchAuto = options.mpsBatchAuto
        let mpsBatchAutoSpecified = options.mpsBatchAutoSpecified
        var mpsBatchMin = options.mpsBatchMin
        var mpsBatchMax = options.mpsBatchMax
        let mpsBatchMinSpecified = options.mpsBatchMinSpecified
        let mpsBatchMaxSpecified = options.mpsBatchMaxSpecified
        let mpsBatchTuneEverySec = options.mpsBatchTuneEverySec
        let refreshEverySec = options.refreshEverySec
        let reportEverySec = options.reportEverySec
        let seedMode = options.seedMode
        let statePath = options.statePath
        let stateReset = options.stateReset
        let stateWriteEverySec = options.stateWriteEverySec
        let claimSize = options.claimSize
        let uiEnabledArg = options.uiEnabled
        let memGuardMaxGB = options.memGuardMaxGB
        let memGuardMaxFrac = options.memGuardMaxFrac
        let memGuardMaxGBSpecified = options.memGuardMaxGBSpecified
        let memGuardMaxFracSpecified = options.memGuardMaxFracSpecified
        let memGuardEverySec = options.memGuardEverySec

        let printLock = NSLock()

        if let c = count, c <= 0 {
            count = nil
            endlessFlag = true
        }

        let endless = endlessFlag || count == nil
        let totalTarget: Int? = endless ? nil : max(1, count ?? 0)
        let total = totalTarget ?? 0

        let uiEnabledFinal: Bool = {
            if let v = uiEnabledArg { return v }
            return Terminal.isInteractiveStdout()
        }()

        let uiRefreshEverySec: Double = {
            guard uiEnabledFinal else { return reportEverySec }
            if reportEverySec.isFinite, reportEverySec > 0 { return reportEverySec }
            return 0.25
        }()

        let eventLog: ExploreEventLog? = uiEnabledFinal ? ExploreEventLog(capacity: 400) : nil

        func emit(_ kind: ExploreEventKind = .info, _ message: String) {
            if let eventLog {
                eventLog.append(kind, message)
            } else {
                printLock.withLock { print(message) }
            }
        }

        func waitForDispatchGroup(_ group: DispatchGroup) async {
            await withCheckedContinuation { cont in
                group.notify(queue: DispatchQueue.global(qos: .utility)) {
                    cont.resume()
                }
            }
        }

        let cpuFlushIntervalNs: UInt64 = {
            guard endless else { return 0 }
            let sec = min(1.0, max(0.25, uiRefreshEverySec / 2.0))
            return UInt64(sec * 1e9)
        }()

        let metalAvailable = MPSScorer.isMetalAvailable()
        if !backendSpecified {
            backend = metalAvailable ? .mps : .cpu
        }
        if !gpuBackendSpecified {
            gpuBackend = .metal
        }
        if !doSubmitSpecified {
            doSubmit = true
        }
        if !topUniqueUsersSpecified {
            topUniqueUsers = true
        }
        if !mpsBatchAutoSpecified, backend == .mps || backend == .all {
            mpsBatchAuto = true
        }
        if !mpsMarginAutoSpecified, backend == .mps || backend == .all {
            mpsMarginAuto = true
        }
        if !mpsInflightAuto, backend == .mps || backend == .all {
            mpsInflightAuto = true
        }

        let mpsBatch = max(1, batch)
        if mpsBatchAuto {
            if !mpsBatchMinSpecified {
                mpsBatchMin = max(1, mpsBatch / 2)
            }
            if !mpsBatchMaxSpecified {
                mpsBatchMax = max(mpsBatch, 12288)
            }
            if mpsBatchMax < mpsBatchMin {
                throw GobxError.usage("--mps-batch-max must be >= --mps-batch-min")
            }
        }
        let mpsBatchMinFinal = mpsBatchAuto ? mpsBatchMin : mpsBatch
        let mpsBatchMaxFinal = mpsBatchAuto ? mpsBatchMax : mpsBatch
        let mpsBatchAutoFinal = mpsBatchAuto
        let mpsInflightFinal = max(1, mpsInflight)
        let claimSizeFinal = claimSize
        if mpsWorkers < 0 {
            throw GobxError.usage("--mps-workers must be >= 0")
        }
        if mpsInflightAuto {
            if !mpsInflightMinSpecified {
                mpsInflightMin = max(1, mpsInflightFinal / 2)
            }
            if !mpsInflightMaxSpecified {
                mpsInflightMax = max(mpsInflightFinal, 16)
            }
            if mpsInflightMax < mpsInflightMin {
                throw GobxError.usage("--mps-inflight-max must be >= --mps-inflight-min")
            }
        }
        let mpsInflightStart: Int = {
            guard mpsInflightAuto else { return mpsInflightFinal }
            return min(mpsInflightMax, max(mpsInflightMin, mpsInflightFinal))
        }()
        let mpsInflightAutoSnapshot = mpsInflightAuto
        let mpsInflightMinSnapshot = mpsInflightMin
        let mpsInflightMaxSnapshot = mpsInflightMax
        let mpsReinitIntervalNs: UInt64 = {
            guard mpsReinitEverySec.isFinite && mpsReinitEverySec > 0 else { return 0 }
            let ns = mpsReinitEverySec * 1e9
            if ns <= 0 { return 0 }
            if ns >= Double(UInt64.max) { return UInt64.max }
            return UInt64(ns)
        }()

        let baseSeedForStride = normalizeV2Seed(startSeed ?? UInt64.random(in: V2SeedSpace.min..<(V2SeedSpace.maxExclusive)))

        var resolvedBackend = backend
        var gpuScorer: (any GPUScorer)? = nil
        var makeScorer: (@Sendable (Int, Int) throws -> any GPUScorer)? = nil
        if backend == .mps || backend == .all {
            do {
                let gpuBackendSnapshot = gpuBackend
                makeScorer = { batchSize, inflight in
                    switch gpuBackendSnapshot {
                    case .mps:
                        return try MPSScorer(batchSize: batchSize, inflight: inflight)
                    case .metal:
                        return try MetalPyramidScorer(batchSize: batchSize, inflight: inflight)
                    }
                }
                if let makeScorer {
                    gpuScorer = try makeScorer(mpsBatch, mpsInflightStart)
                }
            } catch {
                if backend == .all {
                    emit(.warning, "Warning: failed to initialize GPU backend (\(error)); falling back to --backend cpu")
                    resolvedBackend = .cpu
                } else {
                    throw error
                }
            }
        }

        let resolvedBackendFinal = resolvedBackend

        let mpsWorkerCount: Int = {
            let maxWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount)
            if mpsWorkers > 0 {
                return min(maxWorkers, mpsWorkers)
            }
            switch resolvedBackendFinal {
            case .mps:
                return max(1, maxWorkers / 2)
            case .all:
                return 1
            case .cpu:
                return 1
            }
        }()

        let cpuThreadCount: Int = {
            switch resolvedBackendFinal {
            case .cpu:
                return max(1, threads ?? ProcessInfo.processInfo.activeProcessorCount)
            case .mps:
                return 0
            case .all:
                if let t = threads { return max(1, t) }
                let n = ProcessInfo.processInfo.activeProcessorCount
                return max(1, n / 2)
            }
        }()

        let topN: Int = {
            if let v = topNArg { return max(0, v) }
            switch resolvedBackendFinal {
            case .mps, .all:
                return 10
            case .cpu:
                return 0
            }
        }()

        let stats = ExploreStats()
        let best = BestTracker()
        let bestApprox = ApproxBestTracker()
        let stop = StopFlag()
        let topApproxTracker = TopApproxTracker(limit: topN)

        var memGuardTimer: DispatchSourceTimer? = nil
        let usesMps = resolvedBackendFinal == .mps || resolvedBackendFinal == .all
        if memGuardMaxFracSpecified, memGuardMaxFrac > 1.0 {
            throw GobxError.usage("--mem-guard-frac must be between 0 and 1")
        }
        let memGuardLimitBytes: UInt64? = {
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            var explicitLimits: [UInt64] = []
            var explicitDisable = false

            if memGuardMaxGBSpecified {
                if memGuardMaxGB <= 0 {
                    explicitDisable = true
                } else {
                    let bytes = UInt64(memGuardMaxGB * 1024.0 * 1024.0 * 1024.0)
                    explicitLimits.append(bytes)
                }
            }
            if memGuardMaxFracSpecified {
                if memGuardMaxFrac <= 0 {
                    explicitDisable = true
                } else {
                    let bytes = UInt64(Double(physicalMemory) * memGuardMaxFrac)
                    explicitLimits.append(bytes)
                }
            }

            if let limit = explicitLimits.min() {
                return limit
            }
            if explicitDisable {
                return nil
            }
            guard usesMps else { return nil }

            let defaultFrac = 0.8
            return UInt64(Double(physicalMemory) * defaultFrac)
        }()

        if let limitBytes = memGuardLimitBytes {
            let interval: Double = {
                if memGuardEverySec.isFinite {
                    return max(0.25, memGuardEverySec)
                }
                return 5.0
            }()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
            timer.setEventHandler {
                if stop.isStopRequested() { return }
                guard let snap = ProcessMemory.snapshot() else { return }
                if snap.physFootprintBytes >= limitBytes {
                    let usedGiB = Double(snap.physFootprintBytes) / 1_073_741_824.0
                    let limitGiB = Double(limitBytes) / 1_073_741_824.0
                    emit(.warning, String(format: "Memory guard: phys_footprint=%.2fGiB limit=%.2fGiB; stopping to avoid Jetsam", usedGiB, limitGiB))
                    stop.requestStop()
                    timer.cancel()
                }
            }
            timer.resume()
            memGuardTimer = timer

            let physGiB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let limitGiB = Double(limitBytes) / 1_073_741_824.0
            emit(.info, String(format: "Memory guard enabled: limit=%.2fGiB (phys=%.2fGiB) interval=%.2fs", limitGiB, physGiB, interval))
        }

        var seedAllocator: SeedRangeAllocator? = nil
        var seedStateTimer: DispatchSourceTimer? = nil

        if seedMode == .state {
            let url = URL(fileURLWithPath: GobxPaths.expandPath(statePath ?? GobxPaths.seedStateURL.path))

            var state: SeedExploreState
            if !stateReset, let loaded = loadSeedState(from: url) {
                state = loaded
            } else {
                let start = normalizeV2Seed(startSeed ?? UInt64.random(in: V2SeedSpace.min..<(V2SeedSpace.maxExclusive)))
                let offset = start &- V2SeedSpace.min
                let step = chooseCoprimeStep(spaceSize: V2SeedSpace.size)
                state = SeedExploreState(startOffset: offset, step: step, nextIndex: 0, updatedAt: Date())
                do {
                    try saveSeedState(state, to: url)
                } catch {
                    emit(.warning, "Warning: failed to write seed state to \(url.path): \(error)")
                }
            }

            if state.step == 0 || gcd(state.step % V2SeedSpace.size, V2SeedSpace.size) != 1 {
                let fixed = chooseCoprimeStep(spaceSize: V2SeedSpace.size)
                state.step = fixed
                state.nextIndex = 0
                state.updatedAt = Date()
            }
            state.startOffset %= V2SeedSpace.size
            state.step %= V2SeedSpace.size
            state.nextIndex %= V2SeedSpace.size

            seedAllocator = SeedRangeAllocator(state: state, totalTarget: totalTarget)

            let start = V2SeedSpace.min &+ state.startOffset
            emit(.info, "Seed mode: state file=\(url.path)")
            emit(.info, "Seed permutation: start=\(start) step=\(state.step) nextIndex=\(state.nextIndex)")

            let interval = max(1.0, stateWriteEverySec)
            let writeQueue = DispatchQueue(label: "gobx.seedstate", qos: .utility)
            let allocForTimer = seedAllocator
            let timer = DispatchSource.makeTimerSource(queue: writeQueue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
            timer.setEventHandler {
                guard let alloc = allocForTimer else { return }
                guard let snap = alloc.snapshotForSave() else { return }
                do {
                    try saveSeedState(snap, to: url)
                    alloc.markSaved(nextIndex: snap.nextIndex)
                } catch {
                    // keep dirty; try again later
                }
            }
            timer.resume()
            seedStateTimer = timer
        }

        var signalSources: [DispatchSourceSignal] = []
        defer { signalSources.forEach { $0.cancel() } }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global(qos: .utility))
        sigintSource.setEventHandler { stop.requestStop() }
        sigintSource.resume()
        signalSources.append(sigintSource)

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global(qos: .utility))
        sigtermSource.setEventHandler { stop.requestStop() }
        sigtermSource.resume()
        signalSources.append(sigtermSource)

        let effectiveDoSubmit = doSubmit
        let startNs = DispatchTime.now().uptimeNanoseconds

        let configPath = GobxPaths.configURL.path
        let configExists = FileManager.default.fileExists(atPath: configPath)
        var config = loadConfig()
        let configIssue: FirstRunSetup.ConfigIssue? = {
            guard config == nil else { return nil }
            return configExists ? .unreadable : .missing
        }()

        if setupConfig {
            if Terminal.isInteractiveStdout() && Terminal.isInteractiveStdin() {
                if let configured = FirstRunSetup.run(
                    trigger: .explicit,
                    backend: resolvedBackendFinal,
                    gpuBackend: gpuBackend,
                    doSubmit: effectiveDoSubmit,
                    mpsMarginSpecified: mpsMarginSpecified,
                    emit: emit
                ) {
                    config = configured
                }
            } else {
                emit(.warning, "--setup requires an interactive terminal; skipping.")
            }
        }

        if config == nil, let issue = configIssue, !setupConfig {
            if Terminal.isInteractiveStdout() && Terminal.isInteractiveStdin() {
                if let configured = FirstRunSetup.run(
                    trigger: .auto(issue),
                    backend: resolvedBackendFinal,
                    gpuBackend: gpuBackend,
                    doSubmit: effectiveDoSubmit,
                    mpsMarginSpecified: mpsMarginSpecified,
                    emit: emit
                ) {
                    config = configured
                }
            } else {
                let note: String
                switch issue {
                case .missing:
                    note = "No config found at \(configPath)."
                case .unreadable:
                    note = "Config found at \(configPath) but could not be parsed."
                }
                emit(.warning, "\(note) Create \(configPath) to configure submissions.")
            }
        }

        var submission: SubmissionManager? = nil
        var refreshTimer: DispatchSourceTimer? = nil

        if effectiveDoSubmit {
            let defaultProfile = AppConfig.Profile.defaultAuthor
            let configForSubmit: AppConfig = {
                if let cfg = config {
                    if cfg.profile == nil {
                        let handle = defaultProfile.xProfile.map { "@\($0)" } ?? "(none)"
                        emit(.warning, "No profile configured at \(GobxPaths.configURL.path); using default author profile id=\(defaultProfile.id) name=\(defaultProfile.name) x=\(handle)")
                        return AppConfig(baseUrl: cfg.baseUrl, profile: defaultProfile)
                    }
                    return cfg
                }
                let handle = defaultProfile.xProfile.map { "@\($0)" } ?? "(none)"
                emit(.warning, "No config found at \(GobxPaths.configURL.path); using default author profile id=\(defaultProfile.id) name=\(defaultProfile.name) x=\(handle)")
                return AppConfig(baseUrl: nil, profile: defaultProfile)
            }()

            let state = SubmissionState()
            if topUniqueUsers {
                emit(.info, "Using unique-user top list for thresholds")
            }
            if let top = await fetchTop(limit: 500, config: configForSubmit, uniqueUsers: topUniqueUsers) {
                state.mergeTop(top)
                let snap = state.snapshot()
                if !minScoreSpecified, snap.top500Threshold.isFinite {
                    emit(.info, "Calibrated min-score from \(minScore) to \(snap.top500Threshold) (Rank #\(top.images.count))")
                    minScore = snap.top500Threshold
                }
                emit(.info, "Cached \(snap.knownCount) known seeds. Top500 threshold=\(String(format: "%.6f", snap.top500Threshold))")
            } else {
                emit(.warning, "Warning: failed to fetch top 500; submissions may be rejected until refresh succeeds")
            }

            if let p = configForSubmit.profile {
                emit(.info, "Participating as \(p.name) (\(p.id))")
            }

            submission = SubmissionManager(
                config: configForSubmit,
                state: state,
                userMinScore: minScore,
                topUniqueUsers: topUniqueUsers,
                printLock: printLock,
                events: eventLog
            )

            let interval = max(10.0, refreshEverySec)
            if interval.isFinite && interval > 0 {
                let submissionForRefresh = submission
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
                timer.setEventHandler { submissionForRefresh?.enqueueRefreshTop500(limit: 500, reason: "timer") }
                timer.resume()
                refreshTimer = timer
            }
        }

        if effectiveDoSubmit, !mpsMarginSpecified, (resolvedBackendFinal == .mps || resolvedBackendFinal == .all) {
            switch gpuBackend {
            case .metal:
                if let cal = CalibrateMetal.loadIfValid() {
                    mpsVerifyMargin = max(0.0, cal.recommendedMargin)
                    mpsScoreShift = max(0.0, cal.recommendedScoreShift)
                    emit(.info, "Loaded Metal calibration: mps-margin=\(String(format: "%.6f", mpsVerifyMargin)) shift=\(String(format: "%.6f", mpsScoreShift)) q=\(String(format: "%.4f", cal.quantile)) verified=\(cal.verifiedCount)")
                } else {
                    emit(.warning, "No valid Metal calibration found; run: gobx calibrate-metal (or set --mps-margin explicitly)")
                }
            case .mps:
                if let cal = CalibrateMPS.loadIfValid(optLevel: 1) {
                    mpsVerifyMargin = max(0.0, cal.recommendedMargin)
                    emit(.info, "Loaded MPS calibration: mps-margin=\(String(format: "%.6f", mpsVerifyMargin)) q=\(String(format: "%.4f", cal.quantile)) verified=\(cal.verifiedCount)")
                } else {
                    emit(.warning, "No valid MPS calibration found; run: gobx calibrate-mps (or set --mps-margin explicitly)")
                }
            }
        }

        let mpsMarginAutoFinal = mpsMarginAuto && effectiveDoSubmit && (resolvedBackendFinal == .mps || resolvedBackendFinal == .all)
        let mpsMarginTracker = AdaptiveMargin(initial: mpsVerifyMargin, autoEnabled: mpsMarginAutoFinal)
        let mpsShiftAutoFinal = mpsMarginAutoFinal && (gpuBackend == .metal)
        let mpsShiftTracker = AdaptiveScoreShift(initial: mpsScoreShift, autoEnabled: mpsShiftAutoFinal)
        if mpsMarginAutoFinal {
            emit(.info, "Adaptive mps-margin enabled: initial=\(String(format: "%.6f", mpsMarginTracker.current()))")
        }

        let candidateVerifier: CandidateVerifier? = {
            guard effectiveDoSubmit else { return nil }
            switch resolvedBackendFinal {
            case .mps, .all:
                return CandidateVerifier(
                    best: best,
                    submission: submission,
                    printLock: printLock,
                    events: eventLog,
                    stats: stats,
                    margin: mpsMarginTracker,
                    scoreShift: mpsShiftTracker
                )
            case .cpu:
                return nil
            }
        }()

        var reportTimer: DispatchSourceTimer? = nil
        if endless, !uiEnabledFinal, reportEverySec.isFinite, reportEverySec > 0 {
            final class ReportState: @unchecked Sendable {
                var lastSnap: ExploreStats.Snapshot
                var lastNs: UInt64

                init(lastSnap: ExploreStats.Snapshot, lastNs: UInt64) {
                    self.lastSnap = lastSnap
                    self.lastNs = lastNs
                }
            }

            let state = ReportState(lastSnap: stats.snapshot(), lastNs: startNs)
            let interval = max(0.25, reportEverySec)
            let submissionForStatus = submission

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
            timer.setEventHandler {
                let now = DispatchTime.now().uptimeNanoseconds
                let snap = stats.snapshot()
                let dt = Double(now - state.lastNs) / 1e9
                guard dt > 0 else { return }

                let cpuDelta = Double(snap.cpuCount &- state.lastSnap.cpuCount)
                let cpuVerifyDelta = Double(snap.cpuVerifyCount &- state.lastSnap.cpuVerifyCount)
                let mpsDelta = Double(snap.mpsCount &- state.lastSnap.mpsCount)
                let cpuRate = cpuDelta / dt
                let cpuVerifyRate = cpuVerifyDelta / dt
                let mpsRate = mpsDelta / dt

                let cpuAvg = snap.cpuCount > 0 ? snap.cpuScoreSum / Double(snap.cpuCount) : 0.0
                let cpuVerifyAvg = snap.cpuVerifyCount > 0 ? snap.cpuVerifyScoreSum / Double(snap.cpuVerifyCount) : 0.0
                let mpsAvg = snap.mpsCount > 0 ? snap.mpsScoreSum / Double(snap.mpsCount) : 0.0

                let totalCount = snap.cpuCount &+ snap.mpsCount &+ snap.cpuVerifyCount
                let totalSum = snap.cpuScoreSum + snap.mpsScoreSum + snap.cpuVerifyScoreSum
                let totalDelta = Double(totalCount &- (state.lastSnap.cpuCount &+ state.lastSnap.mpsCount &+ state.lastSnap.cpuVerifyCount))
                let totalRate = totalDelta / dt
                let totalAvg = totalCount > 0 ? totalSum / Double(totalCount) : 0.0

                let elapsed = Double(now - startNs) / 1e9
                let bestSnap = best.snapshot()
                let approxSnap = bestApprox.snapshot()
                let bestExactStr: String? = {
                    guard bestSnap.score.isFinite else { return nil }
                    return "\(String(format: "%.6f", bestSnap.score)) (\(bestSnap.seed)\(bestSnap.source.map { ",\($0)" } ?? ""))"
                }()
                let approxTag: String? = {
                    switch resolvedBackendFinal {
                    case .cpu:
                        return nil
                    case .mps, .all:
                        return "mps"
                    }
                }()
                let bestApproxStr: String? = {
                    guard let tag = approxTag else { return nil }
                    guard approxSnap.score.isFinite else { return nil }
                    return "≈\(String(format: "%.6f", Double(approxSnap.score))) (\(approxSnap.seed),\(tag))"
                }()
                let bestStr = bestExactStr ?? bestApproxStr ?? "?"
                let bestApproxSuffix: String = {
                    guard bestExactStr != nil, let s = bestApproxStr else { return "" }
                    return " best≈=\(s)"
                }()

                var thrSuffix = ""
                if let sub = submissionForStatus {
                    let topSnap = sub.stateSnapshot()
                    let thrStr = String(format: "%.6f", sub.effectiveThreshold())
                    let topThrStr = topSnap.top500Threshold.isFinite ? String(format: "%.6f", topSnap.top500Threshold) : "?"
                    thrSuffix = " thr=\(thrStr) top500=\(topThrStr)"
                }

                let cpuVerifySuffix: String = {
                    guard snap.cpuVerifyCount > 0 else { return "" }
                    return String(format: " cpuv=%llu (%.0f/s avg=%.6f)", snap.cpuVerifyCount, cpuVerifyRate, cpuVerifyAvg)
                }()

                printLock.withLock {
                    switch resolvedBackendFinal {
                    case .all:
                        let base = String(format: "t=%.1fs cpu=%llu (%.0f/s avg=%.6f) mps=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f)",
                                          elapsed,
                                          snap.cpuCount, cpuRate, cpuAvg,
                                          snap.mpsCount, mpsRate, mpsAvg,
                                          totalCount, totalRate, totalAvg)
                        print("\(base)\(cpuVerifySuffix) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                    case .cpu:
                        let base = String(format: "t=%.1fs cpu=%llu (%.0f/s avg=%.6f)",
                                          elapsed,
                                          snap.cpuCount, cpuRate, cpuAvg)
                        print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                    case .mps:
                        let base = String(format: "t=%.1fs mps=%llu (%.0f/s avg=%.6f)",
                                          elapsed,
                                          snap.mpsCount, mpsRate, mpsAvg)
                        print("\(base)\(cpuVerifySuffix) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                    }
                }

                state.lastSnap = snap
                state.lastNs = now
            }
            timer.resume()
            reportTimer = timer
        }

        var ui: ExploreLiveUI? = nil
        if uiEnabledFinal, let eventLog {
            ui = ExploreLiveUI(
                context: .init(
                    backend: resolvedBackendFinal,
                    endless: endless,
                    totalTarget: totalTarget,
                    mpsVerifyMargin: mpsMarginTracker,
                    mpsScoreShift: mpsShiftTracker,
                    minScore: minScore
                ),
                stats: stats,
                best: best,
                bestApprox: bestApprox,
                submission: submission,
                events: eventLog,
                refreshEverySec: uiRefreshEverySec
            )
            ui?.start()
        }
        defer { ui?.stop() }

        let group = DispatchGroup()
        let seedAllocatorForWorkers = seedAllocator
        let submissionForWorkers = submission
        let effectiveDoSubmitForWorkers = effectiveDoSubmit
        let minScoreForWorkers = minScore
        let gpuScorerBox = gpuScorer.map(UnsafeSendableBox.init)

        if resolvedBackendFinal == .cpu || resolvedBackendFinal == .all {
            group.enter()
            let cpuQos: DispatchQoS.QoSClass = (resolvedBackendFinal == .all ? .utility : .userInitiated)
            DispatchQueue.global(qos: cpuQos).async {
                defer { group.leave() }
                let worker = ExploreCPUWorker(params: .init(
                    resolvedBackend: resolvedBackendFinal,
                    threadCount: cpuThreadCount,
                    endless: endless,
                    total: total,
                    claimSize: claimSizeFinal,
                    allocator: seedAllocatorForWorkers,
                    baseSeed: baseSeedForStride,
                    flushIntervalNs: cpuFlushIntervalNs,
                    printLock: printLock,
                    events: eventLog,
                    stats: stats,
                    best: best,
                    submission: submissionForWorkers,
                    effectiveDoSubmit: effectiveDoSubmitForWorkers,
                    minScore: minScoreForWorkers,
                    stop: stop
                ))
                worker.run()
            }
        }

        let makeScorerSnapshot = makeScorer
        let mpsScoreShiftSnapshot = mpsShiftTracker
        if resolvedBackendFinal == .mps || resolvedBackendFinal == .all {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let scorer = gpuScorerBox?.value else { return }

                let manager = ExploreMPSManager(params: .init(
                    resolvedBackend: resolvedBackendFinal,
                    endless: endless,
                    total: total,
                    cpuThreadCount: cpuThreadCount,
                    mpsBatch: mpsBatch,
                    mpsInflight: mpsInflightStart,
                    mpsReinitIntervalNs: mpsReinitIntervalNs,
                    mpsBatchAuto: mpsBatchAutoFinal,
                    mpsBatchMin: mpsBatchMinFinal,
                    mpsBatchMax: mpsBatchMaxFinal,
                    mpsBatchTuneEverySec: mpsBatchTuneEverySec,
                    mpsInflightAuto: mpsInflightAutoSnapshot,
                    mpsInflightMin: mpsInflightMinSnapshot,
                    mpsInflightMax: mpsInflightMaxSnapshot,
                    mpsWorkers: mpsWorkerCount,
                    claimSize: claimSizeFinal,
                    allocator: seedAllocatorForWorkers,
                    baseSeed: baseSeedForStride,
                    minScore: minScoreForWorkers,
                    mpsVerifyMargin: mpsMarginTracker,
                    mpsScoreShift: mpsScoreShiftSnapshot,
                    effectiveDoSubmit: effectiveDoSubmitForWorkers,
                    submission: submissionForWorkers,
                    verifier: candidateVerifier,
                    printLock: printLock,
                    events: eventLog,
                    stats: stats,
                    bestApprox: bestApprox,
                    topApproxLimit: topN,
                    topApproxTracker: topApproxTracker,
                    stop: stop,
                    scorer: scorer,
                    makeScorer: makeScorerSnapshot
                ))
                manager.run()
            }
        }

        await waitForDispatchGroup(group)

        refreshTimer?.cancel()
        reportTimer?.cancel()
        seedStateTimer?.cancel()
        memGuardTimer?.cancel()

        let stopRequested = stop.isStopRequested()
        if stopRequested {
            submission?.flushJournal()
        } else {
            candidateVerifier?.wait()
            submission?.waitForPendingSubmissions()
        }

        if !stopRequested, topN > 0, resolvedBackendFinal != .cpu {
            let top = topApproxTracker.snapshot()
            if !top.isEmpty {
                printLock.withLock {
                    print("Top \(top.count) (mps approx -> cpu verified):")
                }

                let cpu = Scorer(size: 128)
                for (idx, e) in top.enumerated() {
                    let exact = cpu.score(seed: e.seed).totalScore
                    printLock.withLock {
                        print("#\(idx + 1) seed=\(e.seed) approx=\(String(format: "%.6f", Double(e.score))) exact=\(String(format: "%.6f", exact))")
                    }
                }
            }
        }

        let endNs = DispatchTime.now().uptimeNanoseconds
        let dt = Double(endNs - startNs) / 1e9
        let snap = stats.snapshot()
        let cpuRate = Double(snap.cpuCount) / max(1e-9, dt)
        let cpuVerifyRate = Double(snap.cpuVerifyCount) / max(1e-9, dt)
        let mpsRate = Double(snap.mpsCount) / max(1e-9, dt)
        let totalCount = snap.cpuCount &+ snap.mpsCount &+ snap.cpuVerifyCount
        let totalRate = Double(totalCount) / max(1e-9, dt)
        let cpuAvg = snap.cpuCount > 0 ? snap.cpuScoreSum / Double(snap.cpuCount) : 0.0
        let cpuVerifyAvg = snap.cpuVerifyCount > 0 ? snap.cpuVerifyScoreSum / Double(snap.cpuVerifyCount) : 0.0
        let mpsAvg = snap.mpsCount > 0 ? snap.mpsScoreSum / Double(snap.mpsCount) : 0.0
        let totalAvg = totalCount > 0 ? (snap.cpuScoreSum + snap.mpsScoreSum + snap.cpuVerifyScoreSum) / Double(totalCount) : 0.0
        let bestSnap = best.snapshot()
        let approxSnap = bestApprox.snapshot()
        let bestFinal: (seed: UInt64, score: Double, tag: String) = {
            if bestSnap.score.isFinite {
                let tag = bestSnap.source.map { " (\($0))" } ?? ""
                return (bestSnap.seed, bestSnap.score, tag)
            }
            if approxSnap.score.isFinite {
                switch resolvedBackendFinal {
                case .cpu:
                    break
                case .mps, .all:
                    return (approxSnap.seed, Double(approxSnap.score), " (mps≈)")
                }
            }
            return (0, -Double.infinity, "")
        }()

        let cpuVerifySuffix: String = {
            guard snap.cpuVerifyCount > 0 else { return "" }
            return String(format: " cpuv=%llu (%.0f/s avg=%.6f)", snap.cpuVerifyCount, cpuVerifyRate, cpuVerifyAvg)
        }()

        printLock.withLock {
            switch resolvedBackendFinal {
            case .all:
                print(String(format: "elapsed=%.2fs cpu=%llu (%.0f/s avg=%.6f) mps=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f)%@ best=%.6f (%llu)%@",
                             dt,
                             snap.cpuCount, cpuRate, cpuAvg,
                             snap.mpsCount, mpsRate, mpsAvg,
                             totalCount, totalRate, totalAvg,
                             cpuVerifySuffix,
                             bestFinal.score, bestFinal.seed, bestFinal.tag))
            case .cpu:
                print(String(format: "elapsed=%.2fs cpu=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                             dt,
                             snap.cpuCount, cpuRate, cpuAvg,
                             bestFinal.score, bestFinal.seed, bestFinal.tag))
            case .mps:
                print(String(format: "elapsed=%.2fs mps=%llu (%.0f/s avg=%.6f)%@ best=%.6f (%llu)%@",
                             dt,
                             snap.mpsCount, mpsRate, mpsAvg,
                             cpuVerifySuffix,
                             bestFinal.score, bestFinal.seed, bestFinal.tag))
            }
        }
    }
}
