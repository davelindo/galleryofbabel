@preconcurrency import Dispatch
import Foundation

final class ExploreMPSManager: @unchecked Sendable {
    struct Params {
        let resolvedBackend: Backend
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

        let claimSize: Int
        let allocator: SeedRangeAllocator?
        let baseSeed: UInt64

        let minScore: Double
        let mpsVerifyMargin: AdaptiveMargin

        let effectiveDoSubmit: Bool
        let submission: SubmissionManager?
        let verifier: CandidateVerifier?

        let printLock: NSLock
        let events: ExploreEventLog?
        let stats: ExploreStats
        let bestApprox: ApproxBestTracker
        let topApproxTracker: TopApproxTracker
        let stop: StopFlag

        let scorer: MPSScorer
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
            p.printLock.withLock { print(message) }
        }
    }

    func run() {
        var scorer = p.scorer

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
        scorer: inout MPSScorer,
        startSeedForLog: UInt64,
        nextSeed: () -> UInt64?,
        quota: Int?,
        claimCount: Int,
        useState: Bool,
        stride: UInt64
    ) {
        let inflightFinal = max(1, p.mpsInflight)
        var batch = max(1, p.mpsBatch)
        let autoEnabled = p.mpsBatchAuto
        let batchMin = autoEnabled ? max(1, p.mpsBatchMin) : batch
        let batchMax = autoEnabled ? max(batchMin, p.mpsBatchMax) : batch
        let tuneInterval = tuneIntervalNs()
        let tuneLabel = "MPS autotune"
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

        func updateSampleStats(_ value: Double) {
            sampleCount += 1
            let delta = value - sampleMean
            sampleMean += delta / Double(sampleCount)
            let delta2 = value - sampleMean
            sampleM2 += delta * delta2
        }

        func currentSampleGate(baseThr: Double, margin: Double) -> Double? {
            guard autoMarginEnabled, sampleCount >= sampleMinCount else { return nil }
            let variance = sampleCount > 1 ? sampleM2 / Double(sampleCount - 1) : 0.0
            let std = sqrt(max(0.0, variance))
            let zGate = sampleMean + sampleZ * std
            let bandGate = baseThr - margin - sampleSlack
            return max(zGate, bandGate)
        }

        func allowSample(now: UInt64) -> Bool {
            if now &- sampleWindowStartNs >= sampleWindowNs {
                sampleWindowStartNs = now
                sampleWindowCount = 0
            }
            guard sampleWindowCount < sampleMaxPerWindow else { return false }
            sampleWindowCount += 1
            return true
        }

        var pending: [MPSScorer.Job] = []
        pending.reserveCapacity(inflightFinal)

        var enqueued = 0
        var completed = 0
        var seeds = [UInt64](repeating: 0, count: batch)

        var lastReinitNs = DispatchTime.now().uptimeNanoseconds
        var reinitCheck = 0
        var lastTuneNs = lastReinitNs
        var lastTuneCompleted = 0
        var lastTuneRate: Double? = nil
        var bestTuneRate: Double? = nil
        var bestTuneBatch = batch
        var tuneDirection = 1
        var tuneDirectionChanges = 0
        var pendingTuneBatch: Int? = nil
        var pendingTuneReason: String? = nil
        var tuneSettled = false
        let tuneImproveFactor = 1.005
        let tuneDropFactor = 0.98
        let tuneStepLevels: [(up: Double, down: Double)] = [(1.2, 0.85), (1.1, 0.9), (1.05, 0.95)]
        let tuneAlignLevels = [16, 8, 1]
        let maxTuneLevel = tuneStepLevels.count - 1
        var tuneLevel = 0
        let tuneWarmupIntervals = 1
        var tuneWarmupRemaining = autoEnabled ? tuneWarmupIntervals : 0

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

        func rebuildScorer(newBatch: Int, reason: String) {
            guard newBatch > 0, newBatch != batch else { return }
            emit(.info, "Reinitializing MPS scorer (\(reason), batch=\(newBatch))…")
            do {
                scorer = try MPSScorer(batchSize: newBatch, inflight: inflightFinal)
                batch = newBatch
                seeds = [UInt64](repeating: 0, count: batch)
                tuneWarmupRemaining = tuneWarmupIntervals
                lastReinitNs = DispatchTime.now().uptimeNanoseconds
            } catch {
                emit(.warning, "Warning: MPS reinit failed: \(error)")
            }
        }

        if autoEnabled {
            let aligned = min(batchMax, max(batchMin, alignedBatch(batch, align: currentAlign())))
            if aligned != batch {
                rebuildScorer(newBatch: aligned, reason: "autotune-init")
            }
        }

        func scheduleTune(next: Int, reason: String) {
            pendingTuneBatch = next
            pendingTuneReason = reason
        }

        func settle(rate: Double) {
            tuneSettled = true
            let bestRate = bestTuneRate ?? rate
            if bestTuneBatch != batch {
                scheduleTune(next: bestTuneBatch, reason: String(format: "autotune settle best=%.0f/s", bestRate))
            } else {
                emit(.info, "\(tuneLabel) settled: batch=\(batch) rate=\(String(format: "%.0f", bestRate))/s")
            }
        }

        func applyPendingTune(now: UInt64) {
            guard let next = pendingTuneBatch, pending.isEmpty else { return }
            let reason = pendingTuneReason ?? "autotune"
            rebuildScorer(newBatch: next, reason: reason)
            pendingTuneBatch = nil
            pendingTuneReason = nil
            lastTuneNs = now
            lastTuneCompleted = completed
        }

        if useState {
            emit(.info, "MPS start: \(startSeedForLog) claim=\(claimCount) batch=\(batch) inflight=\(scorer.inflight) count=\(p.endless ? "∞" : "\(p.total)")")
        } else {
            emit(.info, "MPS start: \(startSeedForLog) stride=\(stride) batch=\(batch) inflight=\(scorer.inflight) count=\(quota.map(String.init) ?? "∞")")
        }
        if autoEnabled {
            emit(.info, "\(tuneLabel): batch=\(batch) min=\(batchMin) max=\(batchMax) interval=\(String(format: "%.2f", Double(tuneInterval) / 1e9))s")
        }

        func maybeReinit() {
            guard p.mpsReinitIntervalNs > 0 else { return }
            reinitCheck = (reinitCheck + 1) & 127
            guard reinitCheck == 0 else { return }
            guard pendingTuneBatch == nil else { return }
            guard pending.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReinitNs < p.mpsReinitIntervalNs { return }

            emit(.info, "Reinitializing MPS scorer…")

            do {
                scorer = try MPSScorer(batchSize: batch, inflight: inflightFinal)
                tuneWarmupRemaining = tuneWarmupIntervals
            } catch {
                emit(.warning, "Warning: MPS reinit failed: \(error)")
                p.stop.requestStop()
            }
            lastReinitNs = now
        }

        func maybeTune(now: UInt64) {
            guard autoEnabled else { return }
            guard !tuneSettled else { return }
            guard pendingTuneBatch == nil else { return }
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
            scheduleTune(next: next, reason: String(format: "autotune rate=%.0f/s", rate))
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
                guard let s = nextSeed() else { return false }
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
                    var sum = 0.0
                    var sumSq = 0.0
                    var localBest: Float = -Float.infinity
                    var localBestSeed: UInt64 = 0

                    if p.effectiveDoSubmit, let sub = p.submission, let verifier = p.verifier {
                        let baseThr = sub.effectiveThreshold()
                        let margin = p.mpsVerifyMargin.current()
                        let gate = Float(baseThr - margin)
                        let sampleGate = currentSampleGate(baseThr: baseThr, margin: margin)
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        var candidates: [(seed: UInt64, score: Float)] = []
                        let kMax = 4
                        candidates.reserveCapacity(kMax)

                        for idx in 0..<job.count {
                            let sc = scoresBuf[idx]
                            guard sc.isFinite else { continue }
                            let s = seedsBuf[idx]
                            let d = Double(sc)
                            sum += d
                            sumSq += d * d
                            if autoMarginEnabled {
                                updateSampleStats(d)
                            }
                            p.topApproxTracker.update(seed: s, score: sc)
                            if sc > localBest {
                                localBest = sc
                                localBestSeed = s
                            }
                            if sc >= gate {
                                candidates.append((seed: s, score: sc))
                            } else if let sampleGate, autoMarginEnabled, d >= sampleGate, allowSample(now: nowNs) {
                                verifier.enqueue(seed: s, source: "mps-sample", mpsScore: sc)
                            }
                        }
                        p.stats.addMPS(count: job.count, scoreSum: sum, scoreSumSq: sumSq)
                        if localBest.isFinite {
                            _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                        }

                        if !candidates.isEmpty {
                            candidates.sort { $0.score > $1.score }
                            if candidates.count > kMax { candidates.removeSubrange(kMax..<candidates.count) }
                            for c in candidates {
                                verifier.enqueue(seed: c.seed, source: "mps", mpsScore: c.score)
                            }
                        }
                        return
                    }

                    for idx in 0..<job.count {
                        let sc = scoresBuf[idx]
                        guard sc.isFinite else { continue }
                        let s = seedsBuf[idx]
                        let d = Double(sc)
                        sum += d
                        sumSq += d * d
                        p.topApproxTracker.update(seed: s, score: sc)
                        if sc > localBest {
                            localBest = sc
                            localBestSeed = s
                        }
                    }
                    p.stats.addMPS(count: job.count, scoreSum: sum, scoreSumSq: sumSq)
                    if localBest.isFinite {
                        _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                    }
                }
            } catch {
                emit(.warning, "Warning: MPS run error: \(error)")
                p.stop.requestStop()
            }
            completed += job.count
            return true
        }

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            applyPendingTune(now: now)
            maybeReinit()
            maybeTune(now: now)

            if pendingTuneBatch == nil {
                while pending.count < inflightFinal {
                    if !enqueueNext() { break }
                }
            }
            if !drainOne() { break }
            if p.stop.isStopRequested(), pending.isEmpty { break }
            if let q = quota, completed >= q, pending.isEmpty { break }
        }

        while drainOne() {}
    }
}
