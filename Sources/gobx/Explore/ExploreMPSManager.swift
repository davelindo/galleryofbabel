@preconcurrency import Dispatch
import Foundation

private struct WelfordStats {
    var count: UInt64 = 0
    var mean: Double = 0.0
    var m2: Double = 0.0

    init(count: UInt64 = 0, mean: Double = 0.0, m2: Double = 0.0) {
        self.count = count
        self.mean = mean
        self.m2 = m2
    }

    mutating func add(_ value: Double) {
        count &+= 1
        let delta = value - mean
        mean += delta / Double(count)
        let delta2 = value - mean
        m2 += delta * delta2
    }

    mutating func merge(_ other: WelfordStats) {
        guard other.count > 0 else { return }
        if count == 0 {
            self = other
            return
        }
        let total = count &+ other.count
        let delta = other.mean - mean
        mean += delta * Double(other.count) / Double(total)
        m2 += other.m2 + delta * delta * Double(count) * Double(other.count) / Double(total)
        count = total
    }
}

private struct LocalCandidate {
    let seed: UInt64
    let score: Float
    let raw: Float
}

private struct LocalResult {
    var sum: Double = 0.0
    var sumSq: Double = 0.0
    var bestScore: Float = -Float.infinity
    var bestSeed: UInt64 = 0
    var sampleStats = WelfordStats()
    var candidates: [LocalCandidate] = []
    var candidateWorst: Float = -Float.infinity
    var sampleCandidates: [LocalCandidate] = []
    var sampleWorst: Float = -Float.infinity
    var topApprox: [TopApproxEntry] = []
    var topApproxWorst: Float = -Float.infinity

    mutating func considerCandidate(_ candidate: LocalCandidate, limit: Int) {
        guard limit > 0 else { return }
        if candidates.count < limit {
            candidates.append(candidate)
            if candidates.count == limit {
                candidateWorst = candidates.map(\.score).min() ?? candidate.score
            }
            return
        }
        guard candidate.score > candidateWorst else { return }
        var worstIdx = 0
        var worstScore = candidates[0].score
        for i in 1..<candidates.count {
            let s = candidates[i].score
            if s < worstScore {
                worstScore = s
                worstIdx = i
            }
        }
        candidates[worstIdx] = candidate
        candidateWorst = candidates.map(\.score).min() ?? candidateWorst
    }

    mutating func considerTopApprox(seed: UInt64, score: Float, limit: Int) {
        guard limit > 0 else { return }
        if topApprox.count < limit {
            topApprox.append(TopApproxEntry(seed: seed, score: score))
            if topApprox.count == limit {
                topApproxWorst = topApprox.map(\.score).min() ?? score
            }
            return
        }
        guard score > topApproxWorst else { return }
        var worstIdx = 0
        var worstScore = topApprox[0].score
        for i in 1..<topApprox.count {
            let s = topApprox[i].score
            if s < worstScore {
                worstScore = s
                worstIdx = i
            }
        }
        topApprox[worstIdx] = TopApproxEntry(seed: seed, score: score)
        topApproxWorst = topApprox.map(\.score).min() ?? topApproxWorst
    }

    mutating func considerSampleCandidate(_ candidate: LocalCandidate, limit: Int) {
        guard limit > 0 else { return }
        if sampleCandidates.count < limit {
            sampleCandidates.append(candidate)
            if sampleCandidates.count == limit {
                sampleWorst = sampleCandidates.map(\.score).min() ?? candidate.score
            }
            return
        }
        guard candidate.score > sampleWorst else { return }
        var worstIdx = 0
        var worstScore = sampleCandidates[0].score
        for i in 1..<sampleCandidates.count {
            let s = sampleCandidates[i].score
            if s < worstScore {
                worstScore = s
                worstIdx = i
            }
        }
        sampleCandidates[worstIdx] = candidate
        sampleWorst = sampleCandidates.map(\.score).min() ?? sampleWorst
    }
}

private final class LocalResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [LocalResult]

    init(count: Int) {
        self.results = [LocalResult](repeating: LocalResult(), count: max(0, count))
    }

    func set(_ index: Int, _ value: LocalResult) {
        lock.lock()
        if index >= 0 && index < results.count {
            results[index] = value
        }
        lock.unlock()
    }

    func snapshot() -> [LocalResult] {
        lock.lock()
        let out = results
        lock.unlock()
        return out
    }
}

private enum ExploreMPSStallError: Error, LocalizedError {
    case noProgress(seconds: Double)
    case noSeeds

    var errorDescription: String? {
        switch self {
        case .noProgress(let seconds):
            return String(format: "no GPU progress for %.1fs", seconds)
        case .noSeeds:
            return "seed allocator returned no seeds for endless explore"
        }
    }
}

final class ExploreMPSManager: @unchecked Sendable {
    struct Params {
        let resolvedBackend: Backend
        let gpuBackend: GPUBackend
        let endless: Bool
        let total: Int
        let cpuThreadCount: Int

        let mpsBatch: Int
        let mpsInflight: Int
        let mpsReinitIntervalNs: UInt64
        let mpsBatchAuto: Bool
        let mpsBatchMin: Int
        let mpsBatchMax: Int
        let mpsBatchTuneEverySec: Double
        let mpsInflightAuto: Bool
        let mpsInflightMin: Int
        let mpsInflightMax: Int
        let mpsWorkers: Int

        let claimSize: Int
        let allocator: SeedRangeAllocator?
        let baseSeed: UInt64

        let minScore: Double
        let mpsVerifyMargin: AdaptiveMargin
        let mpsScoreShift: AdaptiveScoreShift

        let effectiveDoSubmit: Bool
        let submission: SubmissionManager?
        let verifier: CandidateVerifier?

        let printLock: NSLock
        let logTimestamps: Bool
        let events: ExploreEventLog?
        let stats: ExploreStats
        let bestApprox: ApproxBestTracker
        let topApproxLimit: Int
        let topApproxTracker: TopApproxTracker
        let stop: StopFlag

        let scorer: any GPUScorer
        let makeScorer: (@Sendable (Int, Int) throws -> any GPUScorer)?
    }

    private let p: Params

    init(params: Params) {
        self.p = params
    }

    private func alignedBatch(_ value: Int, align: Int) -> Int {
        let step = max(1, align)
        if value <= 0 { return step }
        return ((value + step - 1) / step) * step
    }

    private func tuneIntervalNs() -> UInt64 {
        let sec = max(0.25, p.mpsBatchTuneEverySec)
        let ns = sec * 1e9
        if ns >= Double(UInt64.max) { return UInt64.max }
        return UInt64(ns)
    }

    private func emit(_ kind: ExploreEventKind, _ message: String) {
        if let events = p.events {
            events.append(kind, message)
        } else {
            p.printLock.withLock { print(formatLogLine(message, includeTimestamp: p.logTimestamps)) }
        }
    }

    func run() {
        var scorer: any GPUScorer = p.scorer

        let allocator = p.allocator
        let useState = (allocator != nil)
        let step = allocator?.stepValue ?? 0
        let spaceSize = allocator?.spaceSizeValue ?? 0

        let totalWorkers = p.cpuThreadCount + (p.resolvedBackend == .all ? 1 : 0)
        let stride: UInt64 = p.resolvedBackend == .all ? UInt64(max(1, totalWorkers)) : 1
        let quota: Int? = (useState || p.endless) ? nil : {
            if p.resolvedBackend == .all {
                let workers = max(1, totalWorkers)
                let base = p.total / workers
                let rem = p.total % workers
                return base + (p.cpuThreadCount < rem ? 1 : 0)
            }
            return p.total
        }()

        var seed: UInt64 = p.resolvedBackend == .all ? nextV2Seed(p.baseSeed, by: UInt64(p.cpuThreadCount)) : p.baseSeed
        var offset: UInt64 = 0
        var remainingInClaim = 0

        let claimCount: Int = {
            let raw = max(p.claimSize, p.mpsBatch * 4)
            let m = max(1, p.mpsBatch)
            let aligned = raw - (raw % m)
            return max(m, aligned)
        }()

        func claimIfNeeded() -> Bool {
            guard useState else { return true }
            if remainingInClaim > 0 { return true }
            guard let alloc = allocator, let c = alloc.claim(maxCount: claimCount) else { return false }
            offset = c.offset
            remainingInClaim = c.count
            seed = V2SeedSpace.min &+ offset
            return true
        }

        func nextSeed() -> UInt64? {
            if useState {
                guard claimIfNeeded() else { return nil }
                let out = V2SeedSpace.min &+ offset
                offset &+= step
                if offset >= spaceSize { offset &-= spaceSize }
                remainingInClaim -= 1
                return out
            }
            let out = seed
            seed = nextV2Seed(seed, by: stride)
            return out
        }

        // Ensure we have an initial claim in state mode.
        if useState, !claimIfNeeded() {
            return
        }

        let startSeedForLog: UInt64 = useState ? (V2SeedSpace.min &+ offset) : seed
        runSingleStage(scorer: &scorer, startSeedForLog: startSeedForLog, nextSeed: nextSeed, quota: quota, claimCount: claimCount, useState: useState, stride: stride)
    }

    private func runSingleStage(
        scorer: inout any GPUScorer,
        startSeedForLog: UInt64,
        nextSeed: () -> UInt64?,
        quota: Int?,
        claimCount: Int,
        useState: Bool,
        stride: UInt64
    ) {
        var inflight = max(1, p.mpsInflight)
        var batch = max(1, p.mpsBatch)
        let autoEnabled = p.mpsBatchAuto
        let batchMin = autoEnabled ? max(1, p.mpsBatchMin) : batch
        var batchMax = autoEnabled ? max(batchMin, p.mpsBatchMax) : batch
        let tuneInterval = tuneIntervalNs()
        let tuneLabel = "GPU autotune"
        let inflightTuneInterval: UInt64 = {
            let maxSafe = UInt64.max / 2
            return tuneInterval > maxSafe ? UInt64.max : tuneInterval * 2
        }()
        let inflightAuto = p.mpsInflightAuto
        let inflightMin = inflightAuto ? max(1, p.mpsInflightMin) : inflight
        var inflightMax = inflightAuto ? max(inflightMin, p.mpsInflightMax) : inflight
        if inflight < inflightMin { inflight = inflightMin }
        if inflight > inflightMax { inflight = inflightMax }
        let processingWorkers = max(1, p.mpsWorkers)
        let parallelChunkTarget = 1024
        let minParallelCount = 2048
        let autoMarginEnabled = p.mpsVerifyMargin.autoEnabled
        let sampleZ = 1.645
        let sampleSlack = 0.1
        let sampleMinCount: UInt64 = 2048
        let sampleWindowNs: UInt64 = 1_000_000_000
        let sampleMaxPerWindow = 2
        var sampleWindowStartNs = DispatchTime.now().uptimeNanoseconds
        var sampleWindowCount = 0
        var sampleCount: UInt64 = 0
        var sampleMean = 0.0
        var sampleM2 = 0.0
        let sampleLock = NSLock()
        let topApproxLimit = max(0, p.topApproxLimit)
        let stallTimeoutNs: UInt64 = 30_000_000_000
        var lastProgressNs = DispatchTime.now().uptimeNanoseconds

        func currentSampleGate(baseThr: Double, margin: Double) -> Double? {
            guard autoMarginEnabled, sampleCount >= sampleMinCount else { return nil }
            let variance = sampleCount > 1 ? sampleM2 / Double(sampleCount - 1) : 0.0
            let std = sqrt(max(0.0, variance))
            let zGate = sampleMean + sampleZ * std
            let bandGate = baseThr - margin - sampleSlack
            return max(zGate, bandGate)
        }

        func allowSample() -> Bool {
            sampleLock.lock()
            defer { sampleLock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- sampleWindowStartNs >= sampleWindowNs {
                sampleWindowStartNs = now
                sampleWindowCount = 0
            }
            guard sampleWindowCount < sampleMaxPerWindow else { return false }
            sampleWindowCount += 1
            return true
        }

        func processBatch(
            seedsBuf: UnsafeBufferPointer<UInt64>,
            scoresBuf: UnsafeBufferPointer<Float>,
            count: Int
        ) {
            guard count > 0 else { return }

            let scoreShift = Float(p.mpsScoreShift.current())
            let doSubmit = p.effectiveDoSubmit && p.submission != nil && p.verifier != nil
            let baseThr = doSubmit ? (p.submission?.effectiveThreshold() ?? 0.0) : 0.0
            let margin = doSubmit ? p.mpsVerifyMargin.current() : 0.0
            let gate = Float(baseThr - margin) - scoreShift
            let sampleGate = (doSubmit && autoMarginEnabled) ? currentSampleGate(baseThr: baseThr, margin: margin).map { $0 - Double(scoreShift) } : nil
            let sampleEnabled = doSubmit && autoMarginEnabled && sampleGate != nil

            let maxWorkers = max(1, processingWorkers)
            let suggestedWorkers = (count + parallelChunkTarget - 1) / parallelChunkTarget
            let workerCount = (count >= minParallelCount && maxWorkers > 1) ? min(maxWorkers, max(1, suggestedWorkers)) : 1
            let chunkSize = (count + workerCount - 1) / workerCount

            let candidateMax = 4
            let sampleCandidateMax = 4

            var locals: [LocalResult] = []
            if workerCount == 1 {
                var local = LocalResult()
                local.candidates.reserveCapacity(candidateMax)
                local.sampleCandidates.reserveCapacity(sampleCandidateMax)
                local.topApprox.reserveCapacity(min(16, topApproxLimit))
                for idx in 0..<count {
                    let scRaw = scoresBuf[idx]
                    guard scRaw.isFinite else { continue }
                    let s = seedsBuf[idx]
                    let sc = scRaw - scoreShift
                    let d = Double(sc)
                    local.sum += d
                    local.sumSq += d * d
                    if autoMarginEnabled {
                        local.sampleStats.add(d)
                    }
                    if topApproxLimit > 0 {
                        local.considerTopApprox(seed: s, score: sc, limit: topApproxLimit)
                    }
                    if sc > local.bestScore {
                        local.bestScore = sc
                        local.bestSeed = s
                    }
                    if doSubmit {
                        if sc >= gate {
                            local.considerCandidate(LocalCandidate(seed: s, score: sc, raw: scRaw), limit: candidateMax)
                        } else if sampleEnabled, let sampleGate, d >= sampleGate {
                            local.considerSampleCandidate(LocalCandidate(seed: s, score: sc, raw: scRaw), limit: sampleCandidateMax)
                        }
                    }
                }
                locals = [local]
            } else {
                let seedsBox = UnsafeSendableBox(seedsBuf)
                let scoresBox = UnsafeSendableBox(scoresBuf)
                let resultsBox = LocalResultsBox(count: workerCount)
                DispatchQueue.concurrentPerform(iterations: workerCount) { workerIdx in
                    let start = workerIdx * chunkSize
                    let end = min(start + chunkSize, count)
                    if start >= end { return }
                    let seeds = seedsBox.value
                    let scores = scoresBox.value
                    var local = LocalResult()
                    local.candidates.reserveCapacity(candidateMax)
                    local.sampleCandidates.reserveCapacity(sampleCandidateMax)
                    local.topApprox.reserveCapacity(min(16, topApproxLimit))
                    for idx in start..<end {
                        let scRaw = scores[idx]
                        guard scRaw.isFinite else { continue }
                        let s = seeds[idx]
                        let sc = scRaw - scoreShift
                        let d = Double(sc)
                        local.sum += d
                        local.sumSq += d * d
                        if autoMarginEnabled {
                            local.sampleStats.add(d)
                        }
                        if topApproxLimit > 0 {
                            local.considerTopApprox(seed: s, score: sc, limit: topApproxLimit)
                        }
                        if sc > local.bestScore {
                            local.bestScore = sc
                            local.bestSeed = s
                        }
                        if doSubmit {
                            if sc >= gate {
                                local.considerCandidate(LocalCandidate(seed: s, score: sc, raw: scRaw), limit: candidateMax)
                            } else if sampleEnabled, let sampleGate, d >= sampleGate {
                                local.considerSampleCandidate(LocalCandidate(seed: s, score: sc, raw: scRaw), limit: sampleCandidateMax)
                            }
                        }
                    }
                    resultsBox.set(workerIdx, local)
                }
                locals = resultsBox.snapshot()
            }

            var sum = 0.0
            var sumSq = 0.0
            var localBest: Float = -Float.infinity
            var localBestSeed: UInt64 = 0
            var mergedSample = WelfordStats(count: sampleCount, mean: sampleMean, m2: sampleM2)
            var bestCandidates: [LocalCandidate] = []
            var bestSamples: [LocalCandidate] = []

            for local in locals {
                sum += local.sum
                sumSq += local.sumSq
                if local.bestScore > localBest {
                    localBest = local.bestScore
                    localBestSeed = local.bestSeed
                }
                if autoMarginEnabled {
                    mergedSample.merge(local.sampleStats)
                }
                if doSubmit {
                    for c in local.candidates {
                        if bestCandidates.count < candidateMax {
                            bestCandidates.append(c)
                        } else {
                            var worstIdx = 0
                            var worstScore = bestCandidates[0].score
                            for i in 1..<bestCandidates.count {
                                let s = bestCandidates[i].score
                                if s < worstScore {
                                    worstScore = s
                                    worstIdx = i
                                }
                            }
                            if c.score > worstScore {
                                bestCandidates[worstIdx] = c
                            }
                        }
                    }
                    for s in local.sampleCandidates {
                        if bestSamples.count < sampleCandidateMax {
                            bestSamples.append(s)
                        } else {
                            var worstIdx = 0
                            var worstScore = bestSamples[0].score
                            for i in 1..<bestSamples.count {
                                let v = bestSamples[i].score
                                if v < worstScore {
                                    worstScore = v
                                    worstIdx = i
                                }
                            }
                            if s.score > worstScore {
                                bestSamples[worstIdx] = s
                            }
                        }
                    }
                }
                if topApproxLimit > 0, !local.topApprox.isEmpty {
                    for entry in local.topApprox {
                        p.topApproxTracker.update(seed: entry.seed, score: entry.score)
                    }
                }
            }

            if autoMarginEnabled {
                sampleCount = mergedSample.count
                sampleMean = mergedSample.mean
                sampleM2 = mergedSample.m2
            }

            p.stats.addMPS(count: count, scoreSum: sum, scoreSumSq: sumSq)
            if localBest.isFinite {
                _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
            }

            if doSubmit, let verifier = p.verifier, !bestCandidates.isEmpty {
                bestCandidates.sort { $0.score > $1.score }
                if bestCandidates.count > candidateMax {
                    bestCandidates.removeSubrange(candidateMax..<bestCandidates.count)
                }
                for c in bestCandidates {
                    verifier.enqueue(seed: c.seed, source: "mps", mpsScore: c.score, mpsScoreRaw: c.raw)
                }
            }

            if sampleEnabled, let verifier = p.verifier, !bestSamples.isEmpty {
                bestSamples.sort { $0.score > $1.score }
                if bestSamples.count > sampleCandidateMax {
                    bestSamples.removeSubrange(sampleCandidateMax..<bestSamples.count)
                }
                for s in bestSamples {
                    if allowSample() {
                        verifier.enqueue(seed: s.seed, source: "mps-sample", mpsScore: s.score, mpsScoreRaw: s.raw)
                    }
                }
            }
        }

        var pending: [GPUJob] = []
        pending.reserveCapacity(inflight)

        var enqueued = 0
        var completed = 0
        var seeds = [UInt64](repeating: 0, count: batch)
        var retiredScorers: [any GPUScorer] = []
        let maxRetiredScorers = 2

        var lastReinitNs = DispatchTime.now().uptimeNanoseconds
        var reinitCheck = 0
        var lastTuneNs = lastReinitNs
        var lastTuneCompleted = 0
        var lastTuneRate: Double? = nil
        var bestTuneRate: Double? = nil
        var bestTuneBatch = batch
        var tuneDirection = 1
        var tuneDirectionChanges = 0
        var tuneSettled = false
        let tuneImproveFactor = 1.005
        let tuneDropFactor = 0.98
        let tuneStepLevels: [(up: Double, down: Double)] = [(1.2, 0.85), (1.1, 0.9), (1.05, 0.95)]
        let tuneAlignLevels = [16, 8, 1]
        let maxTuneLevel = tuneStepLevels.count - 1
        var tuneLevel = 0
        let tuneWarmupIntervals = 1
        var tuneWarmupRemaining = autoEnabled ? tuneWarmupIntervals : 0
        var pendingTune: (batch: Int, inflight: Int, reason: String)? = nil
        var inflightTuneSettled = !inflightAuto || inflightMin == inflightMax
        var inflightLastTuneNs = lastReinitNs
        var inflightLastCompleted = 0
        var inflightLastRate: Double? = nil
        var inflightBestRate: Double? = nil
        var inflightBest = inflight
        var inflightDirection = 1
        var inflightDirectionChanges = 0
        let inflightImproveFactor = 1.005
        let inflightDropFactor = 0.98
        let inflightWarmupIntervals = 1
        var inflightWarmupRemaining = inflightAuto ? inflightWarmupIntervals : 0
        var recoveryAttempts = 0
        let maxRecoveryAttempts = 3
        var noSeedsAvailable = false
        var lastSavedBatch = 0
        var lastSavedInflight = 0
        var lastSavedNs: UInt64 = 0
        let saveCooldownNs: UInt64 = 30_000_000_000

        func currentStep() -> (up: Double, down: Double) {
            tuneStepLevels[tuneLevel]
        }

        func currentAlign() -> Int {
            tuneAlignLevels[tuneLevel]
        }

        func noteDirectionChange() {
            tuneDirectionChanges += 1
            if tuneLevel < maxTuneLevel {
                tuneLevel += 1
                tuneDirectionChanges = 0
            }
        }

        func rebuildScorer(newBatch: Int, newInflight: Int, reason: String) {
            guard newBatch > 0, newInflight > 0 else { return }
            guard newBatch != batch || newInflight != inflight else { return }
            emit(.info, "Reinitializing GPU scorer (\(reason), batch=\(newBatch) inflight=\(newInflight))…")
            do {
                guard let makeScorer = p.makeScorer else { return }
                let oldScorer = scorer
                scorer = try makeScorer(newBatch, newInflight)
                retiredScorers.append(oldScorer)
                if retiredScorers.count > maxRetiredScorers {
                    retiredScorers.removeFirst(retiredScorers.count - maxRetiredScorers)
                }
                batch = newBatch
                inflight = newInflight
                seeds = [UInt64](repeating: 0, count: batch)
                pending = []
                pending.reserveCapacity(inflight)
                tuneWarmupRemaining = tuneWarmupIntervals
                inflightWarmupRemaining = inflightWarmupIntervals
                lastReinitNs = DispatchTime.now().uptimeNanoseconds
            } catch {
                emit(.warning, "Warning: GPU reinit failed: \(error)")
            }
        }

        func resetTuningState(now: UInt64) {
            tuneLevel = 0
            tuneDirection = 1
            tuneDirectionChanges = 0
            tuneSettled = !autoEnabled
            lastTuneRate = nil
            bestTuneRate = nil
            bestTuneBatch = batch
            tuneWarmupRemaining = autoEnabled ? tuneWarmupIntervals : 0
            pendingTune = nil
            lastTuneNs = now
            lastTuneCompleted = completed

            inflightTuneSettled = !inflightAuto || inflightMin == inflightMax
            inflightLastRate = nil
            inflightBestRate = nil
            inflightBest = inflight
            inflightDirection = 1
            inflightDirectionChanges = 0
            inflightWarmupRemaining = inflightAuto ? inflightWarmupIntervals : 0
            inflightLastTuneNs = now
            inflightLastCompleted = completed
        }

        func isTimeoutError(_ error: Error) -> Bool {
            if let mpsError = error as? MPSScorerError, case .commandTimeout = mpsError {
                return true
            }
            if let metalError = error as? MetalPyramidScorerError, case .commandTimeout = metalError {
                return true
            }
            if error is ExploreMPSStallError {
                return true
            }
            return false
        }

        func recoverFromError(_ error: Error) -> Bool {
            guard let _ = p.makeScorer else { return false }
            guard recoveryAttempts < maxRecoveryAttempts else { return false }

            recoveryAttempts += 1
            let now = DispatchTime.now().uptimeNanoseconds
            let isTimeout = isTimeoutError(error)
            let scale = (recoveryAttempts >= 2 || isTimeout) ? 0.5 : 0.7
            let targetBatch = max(batchMin, Int(Double(batch) * scale))
            let nextBatch = min(batchMax, max(batchMin, targetBatch))
            let nextInflight = max(inflightMin, min(inflight, 2))

            batchMax = min(batchMax, nextBatch)
            inflightMax = min(inflightMax, nextInflight)

            let label = isTimeout ? "timeout" : "error"
            emit(.warning, "Warning: GPU run \(label) (\(error)); reinitializing with batch=\(nextBatch) inflight=\(nextInflight)")
            enqueued = completed
            pending.removeAll(keepingCapacity: true)
            rebuildScorer(newBatch: nextBatch, newInflight: nextInflight, reason: "recovery")
            resetTuningState(now: now)
            return true
        }

        if autoEnabled {
            let aligned = min(batchMax, max(batchMin, alignedBatch(batch, align: currentAlign())))
            if aligned != batch {
                rebuildScorer(newBatch: aligned, newInflight: inflight, reason: "autotune-init")
            }
        }

        func scheduleTune(batch nextBatch: Int, inflight nextInflight: Int, reason: String) {
            pendingTune = (batch: nextBatch, inflight: nextInflight, reason: reason)
        }

        func settle(rate: Double) {
            tuneSettled = true
            let bestRate = bestTuneRate ?? rate
            if bestTuneBatch != batch {
                scheduleTune(batch: bestTuneBatch, inflight: inflight, reason: String(format: "autotune settle best=%.0f/s", bestRate))
            } else {
                emit(.info, "\(tuneLabel) settled: batch=\(batch) rate=\(String(format: "%.0f", bestRate))/s")
            }
        }

        func applyPendingTune(now: UInt64) {
            guard let tune = pendingTune, pending.isEmpty else { return }
            rebuildScorer(newBatch: tune.batch, newInflight: tune.inflight, reason: tune.reason)
            pendingTune = nil
            lastTuneNs = now
            lastTuneCompleted = completed
            inflightLastTuneNs = now
            inflightLastCompleted = completed
        }

        func maybeSaveTune(now: UInt64) {
            guard autoEnabled || inflightAuto else { return }
            guard (!autoEnabled || tuneSettled), (!inflightAuto || inflightTuneSettled) else { return }
            guard pendingTune == nil else { return }

            let batchToSave = autoEnabled ? bestTuneBatch : batch
            let inflightToSave = inflightAuto ? inflightBest : inflight
            guard batchToSave > 0, inflightToSave > 0 else { return }
            if batchToSave == lastSavedBatch, inflightToSave == lastSavedInflight { return }
            if now &- lastSavedNs < saveCooldownNs { return }

            GPUTuning.save(batch: batchToSave, inflight: inflightToSave, gpuBackend: p.gpuBackend)
            lastSavedBatch = batchToSave
            lastSavedInflight = inflightToSave
            lastSavedNs = now
        }

        if useState {
            emit(.info, "GPU start: \(startSeedForLog) claim=\(claimCount) batch=\(batch) inflight=\(inflight) count=\(p.endless ? "∞" : "\(p.total)")")
        } else {
            emit(.info, "GPU start: \(startSeedForLog) stride=\(stride) batch=\(batch) inflight=\(inflight) count=\(quota.map(String.init) ?? "∞")")
        }
        if autoEnabled {
            emit(.info, "\(tuneLabel): batch=\(batch) min=\(batchMin) max=\(batchMax) interval=\(String(format: "%.2f", Double(tuneInterval) / 1e9))s")
        }
        if inflightAuto && !inflightTuneSettled {
            emit(.info, "Inflight autotune: inflight=\(inflight) min=\(inflightMin) max=\(inflightMax) interval=\(String(format: "%.2f", Double(inflightTuneInterval) / 1e9))s")
        }

        func maybeReinit() {
            guard p.mpsReinitIntervalNs > 0 else { return }
            reinitCheck = (reinitCheck + 1) & 127
            guard reinitCheck == 0 else { return }
            guard pendingTune == nil else { return }
            guard pending.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReinitNs < p.mpsReinitIntervalNs { return }

            emit(.info, "Reinitializing GPU scorer…")

            do {
                guard let makeScorer = p.makeScorer else { return }
                scorer = try makeScorer(batch, inflight)
                tuneWarmupRemaining = tuneWarmupIntervals
                inflightWarmupRemaining = inflightWarmupIntervals
            } catch {
                emit(.warning, "Warning: GPU reinit failed: \(error)")
                p.stop.requestStop()
            }
            lastReinitNs = now
        }

        func maybeTune(now: UInt64) {
            guard autoEnabled else { return }
            guard !tuneSettled else { return }
            guard pendingTune == nil else { return }
            let elapsedNs = now &- lastTuneNs
            guard elapsedNs >= tuneInterval else { return }

            if tuneWarmupRemaining > 0 {
                lastTuneNs = now
                lastTuneCompleted = completed
                tuneWarmupRemaining -= 1
                return
            }

            let completedDelta = completed - lastTuneCompleted
            let dt = Double(elapsedNs) / 1e9
            lastTuneNs = now
            lastTuneCompleted = completed
            guard dt > 0, completedDelta > 0 else { return }

            let rate = Double(completedDelta) / dt
            if bestTuneRate == nil || rate > (bestTuneRate ?? 0) * tuneImproveFactor {
                bestTuneRate = rate
                bestTuneBatch = batch
            }
            if let last = lastTuneRate, rate < last * tuneDropFactor {
                tuneDirection *= -1
                noteDirectionChange()
            }
            lastTuneRate = rate

            if tuneLevel == maxTuneLevel, tuneDirectionChanges >= 2 {
                settle(rate: rate)
                return
            }

            let step = currentStep()
            let align = currentAlign()
            var next = Int(Double(batch) * (tuneDirection > 0 ? step.up : step.down))
            next = alignedBatch(next, align: align)
            next = min(batchMax, max(batchMin, next))
            if next == batch {
                if tuneDirection > 0, batch >= batchMax {
                    tuneDirection = -1
                    noteDirectionChange()
                } else if tuneDirection < 0, batch <= batchMin {
                    tuneDirection = 1
                    noteDirectionChange()
                }
                if tuneLevel == maxTuneLevel, tuneDirectionChanges >= 2 {
                    settle(rate: rate)
                    return
                }
                let retryStep = currentStep()
                let retryAlign = currentAlign()
                var retry = Int(Double(batch) * (tuneDirection > 0 ? retryStep.up : retryStep.down))
                retry = alignedBatch(retry, align: retryAlign)
                retry = min(batchMax, max(batchMin, retry))
                if retry == batch {
                    settle(rate: rate)
                    return
                }
                next = retry
            }
            scheduleTune(batch: next, inflight: inflight, reason: String(format: "autotune rate=%.0f/s", rate))
        }

        func maybeTuneInflight(now: UInt64) {
            guard inflightAuto else { return }
            guard tuneSettled else { return }
            guard !inflightTuneSettled else { return }
            guard pendingTune == nil else { return }
            let elapsedNs = now &- inflightLastTuneNs
            guard elapsedNs >= inflightTuneInterval else { return }

            if inflightWarmupRemaining > 0 {
                inflightLastTuneNs = now
                inflightLastCompleted = completed
                inflightWarmupRemaining -= 1
                return
            }

            let completedDelta = completed - inflightLastCompleted
            let dt = Double(elapsedNs) / 1e9
            inflightLastTuneNs = now
            inflightLastCompleted = completed
            guard dt > 0, completedDelta > 0 else { return }

            let rate = Double(completedDelta) / dt
            if inflightBestRate == nil || rate > (inflightBestRate ?? 0) * inflightImproveFactor {
                inflightBestRate = rate
                inflightBest = inflight
            }
            if let last = inflightLastRate, rate < last * inflightDropFactor {
                inflightDirection *= -1
                inflightDirectionChanges += 1
            }
            inflightLastRate = rate

            if inflightDirectionChanges >= 2 {
                inflightTuneSettled = true
                let bestRate = inflightBestRate ?? rate
                if inflightBest != inflight {
                    scheduleTune(batch: batch, inflight: inflightBest, reason: String(format: "autotune inflight settle best=%.0f/s", bestRate))
                } else {
                    emit(.info, "Inflight autotune settled: inflight=\(inflight) rate=\(String(format: "%.0f", bestRate))/s")
                }
                return
            }

            var next = inflight + inflightDirection
            if next < inflightMin || next > inflightMax {
                inflightDirection *= -1
                inflightDirectionChanges += 1
                next = inflight + inflightDirection
            }
            next = min(inflightMax, max(inflightMin, next))
            if next == inflight {
                inflightTuneSettled = true
                let bestRate = inflightBestRate ?? rate
                emit(.info, "Inflight autotune settled: inflight=\(inflight) rate=\(String(format: "%.0f", bestRate))/s")
                return
            }
            scheduleTune(batch: batch, inflight: next, reason: String(format: "autotune inflight rate=%.0f/s", rate))
        }

        func enqueueNext() -> Bool {
            if p.stop.isStopRequested() { return false }
            if let q = quota, enqueued >= q { return false }

            var n = batch
            if let q = quota {
                n = min(n, q - enqueued)
                if n <= 0 { return false }
            }

            for i in 0..<n {
                guard let s = nextSeed() else {
                    noSeedsAvailable = true
                    return false
                }
                seeds[i] = s
            }
            if n < seeds.count {
                for i in n..<seeds.count { seeds[i] = 0 }
            }

            let job = seeds.withUnsafeBufferPointer { ptr in
                scorer.enqueue(seeds: ptr, count: n)
            }
            pending.append(job)
            enqueued += n
            return true
        }

        func drainOne() -> Bool {
            guard !pending.isEmpty else { return false }
            let job = pending.removeFirst()
            do {
                try scorer.withCompletedJob(job) { seedsBuf, scoresBuf in
                    processBatch(seedsBuf: seedsBuf, scoresBuf: scoresBuf, count: job.count)
                }
                completed += job.count
                lastProgressNs = DispatchTime.now().uptimeNanoseconds
                recoveryAttempts = 0
            } catch {
                let recovered = recoverFromError(error)
                if !recovered {
                    emit(.warning, "Warning: MPS run error: \(error)")
                    p.stop.requestStop()
                }
            }
            return true
        }

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            noSeedsAvailable = false
            applyPendingTune(now: now)
            maybeReinit()
            maybeTune(now: now)
            maybeTuneInflight(now: now)
            maybeSaveTune(now: now)

            if pendingTune == nil {
                while pending.count < inflight {
                    if !enqueueNext() { break }
                }
            }
            if drainOne() { continue }
            if p.stop.isStopRequested(), pending.isEmpty { break }
            if let q = quota, completed >= q, pending.isEmpty { break }
            if noSeedsAvailable, pending.isEmpty {
                if !p.endless { break }
                let recovered = recoverFromError(ExploreMPSStallError.noSeeds)
                lastProgressNs = now
                if !recovered {
                    emit(.warning, "Warning: GPU stalled (seed allocator empty); stopping")
                    p.stop.requestStop()
                    break
                }
                continue
            }
            let stalledForNs = now &- lastProgressNs
            if pending.isEmpty, stalledForNs >= stallTimeoutNs {
                let recovered = recoverFromError(ExploreMPSStallError.noProgress(seconds: Double(stalledForNs) / 1e9))
                lastProgressNs = now
                if !recovered {
                    emit(.warning, String(format: "Warning: GPU stalled for %.1fs; stopping", Double(stalledForNs) / 1e9))
                    p.stop.requestStop()
                    break
                }
                continue
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        while drainOne() {}
    }
}
