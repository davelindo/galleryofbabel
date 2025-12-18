@preconcurrency import Dispatch
import Foundation

enum ExploreRunner {
    static func run(options: ExploreOptions) async throws {
        var count = options.count
        var endlessFlag = options.endlessFlag
        let startSeed = options.startSeed
        let threads = options.threads
        let batch = options.batch
        let backend = options.backend
        let topNArg = options.topN
        let doSubmit = options.doSubmit
        var minScore = options.minScore
        let minScoreSpecified = options.minScoreSpecified
        var mpsVerifyMargin = options.mpsVerifyMargin
        let mpsMarginSpecified = options.mpsMarginSpecified
        let mpsInflight = options.mpsInflight
        let mpsReinitEverySec = options.mpsReinitEverySec
        let mpsTwoStage = options.mpsTwoStage
        let mpsStage1Size = options.mpsStage1Size
        var mpsStage1Margin = options.mpsStage1Margin
        let mpsStage1MarginSpecified = options.mpsStage1MarginSpecified
        let mpsStage2Batch = options.mpsStage2Batch
        let refreshEverySec = options.refreshEverySec
        let reportEverySec = options.reportEverySec
        let seedMode = options.seedMode
        let statePath = options.statePath
        let stateReset = options.stateReset
        let stateWriteEverySec = options.stateWriteEverySec
        let claimSize = options.claimSize
        let uiEnabledArg = options.uiEnabled

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

        let cpuFlushIntervalNs: UInt64 = {
            guard endless else { return 0 }
            let sec = min(1.0, max(0.25, uiRefreshEverySec / 2.0))
            return UInt64(sec * 1e9)
        }()

        let mpsBatch = max(1, batch)
        let mpsInflightFinal = max(1, mpsInflight)
        let claimSizeFinal = claimSize
        let mpsReinitIntervalNs: UInt64 = {
            guard mpsReinitEverySec.isFinite && mpsReinitEverySec > 0 else { return 0 }
            let ns = mpsReinitEverySec * 1e9
            if ns <= 0 { return 0 }
            if ns >= Double(UInt64.max) { return UInt64.max }
            return UInt64(ns)
        }()

        let cpuThreadCount: Int = {
            switch backend {
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
            switch backend {
            case .mps, .all:
                return 10
            case .cpu:
                return 0
            }
        }()

        let baseSeedForStride = normalizeV2Seed(startSeed ?? UInt64.random(in: V2SeedSpace.min..<(V2SeedSpace.maxExclusive)))

        var resolvedBackend = backend
        var mpsScorer: MPSScorer? = nil
        var mpsScorer2: MPSScorer? = nil
        var resolvedTwoStage = mpsTwoStage

        if backend == .mps || backend == .all {
            if mpsTwoStage {
                guard mpsStage1Size > 0, mpsStage1Size < 128, (mpsStage1Size & (mpsStage1Size - 1)) == 0 else {
                    throw GobxError.usage("Invalid --mps-stage1-size: \(mpsStage1Size) (expected power-of-two < 128)\n\n\(gobxHelpText)")
                }
            }
            do {
                if mpsTwoStage {
                    mpsScorer = try MPSScorer(batchSize: mpsBatch, imageSize: mpsStage1Size, inflight: mpsInflightFinal)
                    mpsScorer2 = try MPSScorer(batchSize: max(1, mpsStage2Batch), imageSize: 128, inflight: 1)
                } else {
                    mpsScorer = try MPSScorer(batchSize: mpsBatch, inflight: mpsInflightFinal)
                }
            } catch {
                var fellBackToSingleStage = false
                if mpsTwoStage {
                    do {
                        mpsScorer = try MPSScorer(batchSize: mpsBatch, inflight: mpsInflightFinal)
                        mpsScorer2 = nil
                        resolvedTwoStage = false
                        fellBackToSingleStage = true
                        emit(.warning, "Warning: failed to initialize two-stage MPS (\(error)); falling back to single-stage 128")
                    } catch {
                        // keep original error handling below
                    }
                }
                if fellBackToSingleStage {
                    // Keep resolvedBackend as-is (MPS still available).
                } else if backend == .all {
                    emit(.warning, "Warning: failed to initialize MPS backend (\(error)); falling back to --backend cpu")
                    resolvedBackend = .cpu
                    resolvedTwoStage = false
                } else {
                    throw error
                }
            }
        }

        let resolvedBackendFinal = resolvedBackend
        let mpsTwoStageFinal = resolvedTwoStage && (resolvedBackendFinal == .mps || resolvedBackendFinal == .all)

        let stats = ExploreStats()
        let best = BestTracker()
        let bestApprox = ApproxBestTracker()
        let bestApproxStage1 = ApproxBestTracker()
        let stop = StopFlag()
        let topApproxTracker = TopApproxTracker(limit: topN)

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

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global(qos: .utility))
        sigintSource.setEventHandler { stop.requestStop() }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global(qos: .utility))
        sigtermSource.setEventHandler { stop.requestStop() }
        sigtermSource.resume()

        let startNs = DispatchTime.now().uptimeNanoseconds

        let config = loadConfig()
        var submission: SubmissionManager? = nil
        var refreshTimer: DispatchSourceTimer? = nil

        var effectiveDoSubmit = doSubmit
        if effectiveDoSubmit {
            if config?.profile == nil {
                emit(.warning, "Warning: --submit requested but no config/profile found at \(GobxPaths.configURL.path)")
                effectiveDoSubmit = false
            } else if let cfg = config {
                let state = SubmissionState()
                if let top = await fetchTop(limit: 500, config: cfg) {
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

                if let p = cfg.profile {
                    emit(.info, "Participating as \(p.name) (\(p.id))")
                }

                submission = SubmissionManager(config: cfg, state: state, userMinScore: minScore, printLock: printLock, events: eventLog)

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
        }

        let mpsCandidateVerifier: CandidateVerifier? = {
            guard effectiveDoSubmit else { return nil }
            guard resolvedBackendFinal == .mps || resolvedBackendFinal == .all else { return nil }
            return CandidateVerifier(best: best, submission: submission, printLock: printLock, events: eventLog)
        }()

        if effectiveDoSubmit, !mpsMarginSpecified, (resolvedBackendFinal == .mps || resolvedBackendFinal == .all) {
            if let cal = CalibrateMPS.loadIfValid(optLevel: 1) {
                mpsVerifyMargin = max(0.0, cal.recommendedMargin)
                emit(.info, "Loaded MPS calibration: mps-margin=\(String(format: "%.6f", mpsVerifyMargin)) q=\(String(format: "%.4f", cal.quantile)) verified=\(cal.verifiedCount)")
            } else {
                emit(.warning, "No valid MPS calibration found; run: gobx calibrate-mps (or set --mps-margin explicitly)")
            }
        }

        if mpsTwoStageFinal, !mpsStage1MarginSpecified {
            if let cal = CalibrateMPSStage1.loadIfValid(optLevel: 1, stage1Size: mpsStage1Size) {
                mpsStage1Margin = max(0.0, cal.recommendedMargin)
                emit(.info, "Loaded MPS stage1 calibration: stage1-margin=\(String(format: "%.6f", mpsStage1Margin)) q=\(String(format: "%.4f", cal.quantile)) verified=\(cal.verifiedCount) size=\(mpsStage1Size)")
            } else {
                emit(.warning, "No valid MPS stage1 calibration found; run: gobx calibrate-mps-stage1 (or set --mps-stage1-margin explicitly)")
            }
        }

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
                let mpsDelta = Double(snap.mpsCount &- state.lastSnap.mpsCount)
                let mps2Delta = Double(snap.mps2Count &- state.lastSnap.mps2Count)
                let cpuRate = cpuDelta / dt
                let mpsRate = mpsDelta / dt
                let mps2Rate = mps2Delta / dt

                let cpuAvg = snap.cpuCount > 0 ? snap.cpuScoreSum / Double(snap.cpuCount) : 0.0
                let mpsAvg = snap.mpsCount > 0 ? snap.mpsScoreSum / Double(snap.mpsCount) : 0.0
                let mps2Avg = snap.mps2Count > 0 ? snap.mps2ScoreSum / Double(snap.mps2Count) : 0.0

                let totalCount = snap.cpuCount &+ snap.mpsCount
                let totalSum = snap.cpuScoreSum + snap.mpsScoreSum
                let totalDelta = Double(totalCount &- (state.lastSnap.cpuCount &+ state.lastSnap.mpsCount))
                let totalRate = totalDelta / dt
                let totalAvg = totalCount > 0 ? totalSum / Double(totalCount) : 0.0

                let elapsed = Double(now - startNs) / 1e9
                let bestSnap = best.snapshot()
                let approxSnap = bestApprox.snapshot()
                let approx1Snap = bestApproxStage1.snapshot()
                let bestExactStr: String? = {
                    guard bestSnap.score.isFinite else { return nil }
                    return "\(String(format: "%.6f", bestSnap.score)) (\(bestSnap.seed)\(bestSnap.source.map { ",\($0)" } ?? ""))"
                }()
                let bestApproxStr: String? = {
                    guard resolvedBackendFinal != .cpu else { return nil }
                    guard approxSnap.score.isFinite else { return nil }
                    let tag = mpsTwoStageFinal ? "mps128" : "mps"
                    return "≈\(String(format: "%.6f", Double(approxSnap.score))) (\(approxSnap.seed),\(tag))"
                }()
                let bestApprox1Str: String? = {
                    guard mpsTwoStageFinal else { return nil }
                    guard approx1Snap.score.isFinite else { return nil }
                    return "≈\(String(format: "%.6f", Double(approx1Snap.score))) (\(approx1Snap.seed),mps64)"
                }()
                let bestStr = bestExactStr ?? bestApproxStr ?? bestApprox1Str ?? "?"
                var bestApproxSuffix = ""
                if bestExactStr != nil {
                    if let s = bestApproxStr { bestApproxSuffix += " best≈=\(s)" }
                    if let s = bestApprox1Str { bestApproxSuffix += " best≈64=\(s)" }
                } else if bestApproxStr != nil, let s = bestApprox1Str {
                    bestApproxSuffix = " best≈64=\(s)"
                }

                var thrSuffix = ""
                if let sub = submissionForStatus {
                    let topSnap = sub.stateSnapshot()
                    let thrStr = String(format: "%.6f", sub.effectiveThreshold())
                    let topThrStr = topSnap.top500Threshold.isFinite ? String(format: "%.6f", topSnap.top500Threshold) : "?"
                    thrSuffix = " thr=\(thrStr) top500=\(topThrStr)"
                }

                printLock.withLock {
                    switch resolvedBackendFinal {
                    case .all:
                        if mpsTwoStageFinal {
                            let base = String(format: "t=%.1fs cpu=%llu (%.0f/s avg=%.6f) mps64=%llu (%.0f/s avg=%.6f) mps128=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f)",
                                              elapsed,
                                              snap.cpuCount, cpuRate, cpuAvg,
                                              snap.mpsCount, mpsRate, mpsAvg,
                                              snap.mps2Count, mps2Rate, mps2Avg,
                                              totalCount, totalRate, totalAvg)
                            print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                        } else {
                            let base = String(format: "t=%.1fs cpu=%llu (%.0f/s avg=%.6f) mps=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f)",
                                              elapsed,
                                              snap.cpuCount, cpuRate, cpuAvg,
                                              snap.mpsCount, mpsRate, mpsAvg,
                                              totalCount, totalRate, totalAvg)
                            print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                        }
                    case .cpu:
                        let base = String(format: "t=%.1fs cpu=%llu (%.0f/s avg=%.6f)",
                                          elapsed,
                                          snap.cpuCount, cpuRate, cpuAvg)
                        print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                    case .mps:
                        if mpsTwoStageFinal {
                            let base = String(format: "t=%.1fs mps64=%llu (%.0f/s avg=%.6f) mps128=%llu (%.0f/s avg=%.6f)",
                                              elapsed,
                                              snap.mpsCount, mpsRate, mpsAvg,
                                              snap.mps2Count, mps2Rate, mps2Avg)
                            print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                        } else {
                            let base = String(format: "t=%.1fs mps=%llu (%.0f/s avg=%.6f)",
                                              elapsed,
                                              snap.mpsCount, mpsRate, mpsAvg)
                            print("\(base) best=\(bestStr)\(bestApproxSuffix)\(thrSuffix)")
                        }
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
                    mpsTwoStage: mpsTwoStageFinal,
                    mpsVerifyMargin: mpsVerifyMargin,
                    stage1Margin: mpsStage1Margin,
                    minScore: minScore
                ),
                stats: stats,
                best: best,
                bestApprox: bestApprox,
                bestApproxStage1: bestApproxStage1,
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
        let mpsVerifyMarginForWorkers = mpsVerifyMargin
        let mpsStage1MarginForWorkers = mpsStage1Margin
        let mpsScorerBox = mpsScorer.map(UnsafeSendableBox.init)
        let mpsScorer2Box = mpsScorer2.map(UnsafeSendableBox.init)

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
                    stop: stop
                ))
                worker.run()
            }
        }

        if resolvedBackendFinal == .mps || resolvedBackendFinal == .all {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let stage1Scorer = mpsScorerBox?.value else { return }

                let manager = ExploreMPSManager(params: .init(
                    resolvedBackend: resolvedBackendFinal,
                    endless: endless,
                    total: total,
                    cpuThreadCount: cpuThreadCount,
                    mpsBatch: mpsBatch,
                    mpsInflight: mpsInflightFinal,
                    mpsReinitIntervalNs: mpsReinitIntervalNs,
                    twoStage: mpsTwoStageFinal,
                    stage1Size: mpsStage1Size,
                    stage1Margin: mpsStage1MarginForWorkers,
                    stage2Batch: max(1, mpsStage2Batch),
                    claimSize: claimSizeFinal,
                    allocator: seedAllocatorForWorkers,
                    baseSeed: baseSeedForStride,
                    minScore: minScoreForWorkers,
                    mpsVerifyMargin: mpsVerifyMarginForWorkers,
                    effectiveDoSubmit: effectiveDoSubmitForWorkers,
                    submission: submissionForWorkers,
                    verifier: mpsCandidateVerifier,
                    printLock: printLock,
                    events: eventLog,
                    stats: stats,
                    bestApprox: bestApprox,
                    bestApproxStage1: bestApproxStage1,
                    topApproxTracker: topApproxTracker,
                    stop: stop,
                    stage1Scorer: stage1Scorer,
                    stage2Scorer: mpsScorer2Box?.value
                ))
                manager.run()
            }
        }

        await waitForDispatchGroup(group)

        ui?.stop()

        refreshTimer?.cancel()
        reportTimer?.cancel()
        seedStateTimer?.cancel()

        mpsCandidateVerifier?.wait()
        submission?.waitForPendingSubmissions()

        if topN > 0, resolvedBackendFinal != .cpu {
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
        let mpsRate = Double(snap.mpsCount) / max(1e-9, dt)
        let mps2Rate = Double(snap.mps2Count) / max(1e-9, dt)
        let totalCount = snap.cpuCount &+ snap.mpsCount
        let totalRate = Double(totalCount) / max(1e-9, dt)
        let cpuAvg = snap.cpuCount > 0 ? snap.cpuScoreSum / Double(snap.cpuCount) : 0.0
        let mpsAvg = snap.mpsCount > 0 ? snap.mpsScoreSum / Double(snap.mpsCount) : 0.0
        let mps2Avg = snap.mps2Count > 0 ? snap.mps2ScoreSum / Double(snap.mps2Count) : 0.0
        let totalAvg = totalCount > 0 ? (snap.cpuScoreSum + snap.mpsScoreSum) / Double(totalCount) : 0.0
        let bestSnap = best.snapshot()
        let approxSnap = bestApprox.snapshot()
        let approx1Snap = bestApproxStage1.snapshot()
        let bestFinal: (seed: UInt64, score: Double, tag: String) = {
            if bestSnap.score.isFinite {
                let tag = bestSnap.source.map { " (\($0))" } ?? ""
                return (bestSnap.seed, bestSnap.score, tag)
            }
            if approxSnap.score.isFinite, resolvedBackendFinal != .cpu {
                let tag = mpsTwoStageFinal ? " (mps128≈)" : " (mps≈)"
                return (approxSnap.seed, Double(approxSnap.score), tag)
            }
            if mpsTwoStageFinal, approx1Snap.score.isFinite, resolvedBackendFinal != .cpu {
                return (approx1Snap.seed, Double(approx1Snap.score), " (mps64≈)")
            }
            return (0, -Double.infinity, "")
        }()

        printLock.withLock {
            if resolvedBackendFinal == .all {
                if mpsTwoStageFinal {
                    print(String(format: "elapsed=%.2fs cpu=%llu (%.0f/s avg=%.6f) mps64=%llu (%.0f/s avg=%.6f) mps128=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                                 dt,
                                 snap.cpuCount, cpuRate, cpuAvg,
                                 snap.mpsCount, mpsRate, mpsAvg,
                                 snap.mps2Count, mps2Rate, mps2Avg,
                                 totalCount, totalRate, totalAvg,
                                 bestFinal.score, bestFinal.seed, bestFinal.tag))
                } else {
                    print(String(format: "elapsed=%.2fs cpu=%llu (%.0f/s avg=%.6f) mps=%llu (%.0f/s avg=%.6f) total=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                                 dt,
                                 snap.cpuCount, cpuRate, cpuAvg,
                                 snap.mpsCount, mpsRate, mpsAvg,
                                 totalCount, totalRate, totalAvg,
                                 bestFinal.score, bestFinal.seed, bestFinal.tag))
                }
            } else if resolvedBackendFinal == .cpu {
                print(String(format: "elapsed=%.2fs cpu=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                             dt,
                             snap.cpuCount, cpuRate, cpuAvg,
                             bestFinal.score, bestFinal.seed, bestFinal.tag))
            } else {
                if mpsTwoStageFinal {
                    print(String(format: "elapsed=%.2fs mps64=%llu (%.0f/s avg=%.6f) mps128=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                                 dt,
                                 snap.mpsCount, mpsRate, mpsAvg,
                                 snap.mps2Count, mps2Rate, mps2Avg,
                                 bestFinal.score, bestFinal.seed, bestFinal.tag))
                } else {
                    print(String(format: "elapsed=%.2fs mps=%llu (%.0f/s avg=%.6f) best=%.6f (%llu)%@",
                                 dt,
                                 snap.mpsCount, mpsRate, mpsAvg,
                                 bestFinal.score, bestFinal.seed, bestFinal.tag))
                }
            }
            if !endless {
                print("requestedCount=\(total)")
            }
        }
    }

    private static func waitForDispatchGroup(_ group: DispatchGroup) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                continuation.resume()
            }
        }
    }
}
