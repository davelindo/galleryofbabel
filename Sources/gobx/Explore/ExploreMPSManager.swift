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

        let twoStage: Bool
        let stage1Size: Int
        let stage1Margin: Double
        let stage2Batch: Int

        let claimSize: Int
        let allocator: SeedRangeAllocator?
        let baseSeed: UInt64

        let minScore: Double
        let mpsVerifyMargin: Double

        let effectiveDoSubmit: Bool
        let submission: SubmissionManager?
        let verifier: CandidateVerifier?

        let printLock: NSLock
        let stats: ExploreStats
        let bestApprox: ApproxBestTracker
        let bestApproxStage1: ApproxBestTracker
        let topApproxTracker: TopApproxTracker
        let stop: StopFlag

        let stage1Scorer: MPSScorer
        let stage2Scorer: MPSScorer?
    }

    private let p: Params

    init(params: Params) {
        self.p = params
    }

    func run() {
        var stage1 = p.stage1Scorer
        let stage2 = p.stage2Scorer

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

        if p.twoStage, let stage2 {
            runTwoStage(stage1: &stage1, stage2: stage2, startSeedForLog: startSeedForLog, nextSeed: nextSeed, quota: quota, claimCount: claimCount, useState: useState, stride: stride)
            return
        }

        if p.twoStage, stage2 == nil {
            p.printLock.lock()
            print("Warning: two-stage requested but stage2 scorer missing; falling back to single-stage")
            p.printLock.unlock()
        }

        runSingleStage(stage1: &stage1, startSeedForLog: startSeedForLog, nextSeed: nextSeed, quota: quota, claimCount: claimCount, useState: useState, stride: stride)
    }

    private func runTwoStage(
        stage1: inout MPSScorer,
        stage2: MPSScorer,
        startSeedForLog: UInt64,
        nextSeed: () -> UInt64?,
        quota: Int?,
        claimCount: Int,
        useState: Bool,
        stride: UInt64
    ) {
        let stage2Batch = max(1, p.stage2Batch)
        let seedQueue = SeedQueue()
        let stage2Group = DispatchGroup()

        p.printLock.lock()
        if useState {
            print("MPS stage1 (\(p.stage1Size)x\(p.stage1Size)) start: \(startSeedForLog) claim=\(claimCount) batch=\(p.mpsBatch) inflight=\(p.mpsInflight) count=\(p.endless ? "∞" : "\(p.total)")")
        } else {
            print("MPS stage1 (\(p.stage1Size)x\(p.stage1Size)) start: \(startSeedForLog) stride=\(stride) batch=\(p.mpsBatch) inflight=\(p.mpsInflight) count=\(quota.map(String.init) ?? "∞")")
        }
        print("MPS stage2 (128x128) batch=\(stage2Batch) inflight=\(stage2.inflight)")
        p.printLock.unlock()

        let stage2Box = UnsafeSendableBox(stage2)
        stage2Group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stage2Group.leave() }
            self.runStage2Consumer(stage2: stage2Box.value, seedQueue: seedQueue, stage2Batch: stage2Batch)
        }

        runStage1Producer(stage1: &stage1, nextSeed: nextSeed, quota: quota, seedQueue: seedQueue, stage2Group: stage2Group)
    }

    private func runStage2Consumer(stage2: MPSScorer, seedQueue: SeedQueue, stage2Batch: Int) {
        var buf: [UInt64] = []
        buf.reserveCapacity(stage2Batch)
        let kMax = 4

        while true {
            if p.stop.isStopRequested() { break }

            if buf.count < stage2Batch {
                guard let got = seedQueue.popBatch(max: stage2Batch - buf.count, timeout: .now() + .milliseconds(200)) else {
                    break
                }
                if got.isEmpty {
                    if buf.isEmpty { continue }
                    // flush partial batch on timeout
                } else {
                    buf.append(contentsOf: got)
                    if buf.count < stage2Batch { continue }
                }
            }

            let n = min(stage2Batch, buf.count)
            if n <= 0 { continue }
            let seedsToScore = Array(buf.prefix(n))
            buf.removeFirst(n)

            let job = seedsToScore.withUnsafeBufferPointer { ptr in
                stage2.enqueue(seeds: ptr, count: n)
            }
            do {
                try stage2.withCompletedJob(job) { seedsBuf, scoresBuf in
                    var sum = 0.0
                    var localBest: Float = -Float.infinity
                    var localBestSeed: UInt64 = 0

                    if p.effectiveDoSubmit, let sub = p.submission, let verifier = p.verifier {
                        let gate = Float(sub.effectiveThreshold() - p.mpsVerifyMargin)
                        var candidates: [(seed: UInt64, score: Float)] = []
                        candidates.reserveCapacity(kMax)

                        for idx in 0..<job.count {
                            let sc = scoresBuf[idx]
                            guard sc.isFinite else { continue }
                            let s = seedsBuf[idx]
                            sum += Double(sc)
                            p.topApproxTracker.update(seed: s, score: sc)
                            if sc > localBest {
                                localBest = sc
                                localBestSeed = s
                            }
                            if sc >= gate {
                                candidates.append((seed: s, score: sc))
                            }
                        }
                        p.stats.addMPS2(count: job.count, scoreSum: sum)
                        if localBest.isFinite {
                            _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                        }

                        if !candidates.isEmpty {
                            candidates.sort { $0.score > $1.score }
                            if candidates.count > kMax { candidates.removeSubrange(kMax..<candidates.count) }
                            for c in candidates {
                                verifier.enqueue(seed: c.seed, source: "mps")
                            }
                        }
                        return
                    }

                    for idx in 0..<job.count {
                        let sc = scoresBuf[idx]
                        guard sc.isFinite else { continue }
                        let s = seedsBuf[idx]
                        sum += Double(sc)
                        p.topApproxTracker.update(seed: s, score: sc)
                        if sc > localBest {
                            localBest = sc
                            localBestSeed = s
                        }
                    }
                    p.stats.addMPS2(count: job.count, scoreSum: sum)
                    if localBest.isFinite {
                        _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                    }
                }
            } catch {
                p.printLock.lock()
                print("Warning: MPS stage2 run error: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
                break
            }
        }

        // Drain remaining buffered seeds after close/stop
        while !p.stop.isStopRequested(), !buf.isEmpty {
            let n = min(stage2Batch, buf.count)
            let seedsToScore = Array(buf.prefix(n))
            buf.removeFirst(n)
            let job = seedsToScore.withUnsafeBufferPointer { ptr in
                stage2.enqueue(seeds: ptr, count: n)
            }
            do {
                try stage2.withCompletedJob(job) { seedsBuf, scoresBuf in
                    var sum = 0.0
                    var localBest: Float = -Float.infinity
                    var localBestSeed: UInt64 = 0

                    if p.effectiveDoSubmit, let sub = p.submission, let verifier = p.verifier {
                        let gate = Float(sub.effectiveThreshold() - p.mpsVerifyMargin)
                        var candidates: [(seed: UInt64, score: Float)] = []
                        candidates.reserveCapacity(4)

                        for idx in 0..<job.count {
                            let sc = scoresBuf[idx]
                            guard sc.isFinite else { continue }
                            let s = seedsBuf[idx]
                            sum += Double(sc)
                            p.topApproxTracker.update(seed: s, score: sc)
                            if sc > localBest {
                                localBest = sc
                                localBestSeed = s
                            }
                            if sc >= gate {
                                candidates.append((seed: s, score: sc))
                            }
                        }

                        p.stats.addMPS2(count: job.count, scoreSum: sum)
                        if localBest.isFinite {
                            _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                        }

                        if !candidates.isEmpty {
                            candidates.sort { $0.score > $1.score }
                            if candidates.count > 4 { candidates.removeSubrange(4..<candidates.count) }
                            for c in candidates {
                                verifier.enqueue(seed: c.seed, source: "mps")
                            }
                        }
                        return
                    }

                    for idx in 0..<job.count {
                        let sc = scoresBuf[idx]
                        guard sc.isFinite else { continue }
                        let s = seedsBuf[idx]
                        sum += Double(sc)
                        p.topApproxTracker.update(seed: s, score: sc)
                        if sc > localBest {
                            localBest = sc
                            localBestSeed = s
                        }
                    }

                    p.stats.addMPS2(count: job.count, scoreSum: sum)
                    if localBest.isFinite {
                        _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                    }
                }
            } catch {
                p.printLock.lock()
                print("Warning: MPS stage2 run error: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
                break
            }
        }
    }

    private func runStage1Producer(
        stage1: inout MPSScorer,
        nextSeed: () -> UInt64?,
        quota: Int?,
        seedQueue: SeedQueue,
        stage2Group: DispatchGroup
    ) {
        let batch = max(1, p.mpsBatch)
        let inflightFinal = max(1, p.mpsInflight)
        var pending: [MPSScorer.Job] = []
        pending.reserveCapacity(inflightFinal)

        var enqueued = 0
        var completed = 0
        var seeds = [UInt64](repeating: 0, count: batch)

        var lastReinitNs = DispatchTime.now().uptimeNanoseconds
        var reinitCheck = 0

        func maybeReinit() {
            guard p.mpsReinitIntervalNs > 0 else { return }
            reinitCheck = (reinitCheck + 1) & 127
            guard reinitCheck == 0 else { return }
            guard pending.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReinitNs < p.mpsReinitIntervalNs { return }

            p.printLock.lock()
            print("Reinitializing MPS scorer…")
            p.printLock.unlock()

            do {
                stage1 = try MPSScorer(batchSize: batch, imageSize: p.stage1Size, inflight: inflightFinal)
            } catch {
                p.printLock.lock()
                print("Warning: MPS reinit failed: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
            }
            lastReinitNs = now
        }

        func enqueueNext() -> Bool {
            if p.stop.isStopRequested() { return false }
            if let q = quota, enqueued >= q { return false }

            var n = batch
            if let q = quota {
                n = min(batch, q - enqueued)
                if n <= 0 { return false }
            }

            for i in 0..<n {
                guard let s = nextSeed() else { return false }
                seeds[i] = s
            }
            if n < batch {
                for i in n..<batch { seeds[i] = 0 }
            }

            let job = seeds.withUnsafeBufferPointer { ptr in
                stage1.enqueue(seeds: ptr, count: n)
            }
            pending.append(job)
            enqueued += n
            return true
        }

        func drainOne() -> Bool {
            guard !pending.isEmpty else { return false }
            let job = pending.removeFirst()
            var survivors: [UInt64] = []
            do {
                try stage1.withCompletedJob(job) { seedsBuf, scoresBuf in
                    var sum = 0.0
                    var localBest: Float = -Float.infinity
                    var localBestSeed: UInt64 = 0

                    let baseThr = p.submission?.effectiveThreshold() ?? p.minScore
                    let stage2Gate = Float(baseThr - p.mpsVerifyMargin)
                    let stage1Gate = stage2Gate - Float(p.stage1Margin)

                    for idx in 0..<job.count {
                        let sc = scoresBuf[idx]
                        guard sc.isFinite else { continue }
                        let s = seedsBuf[idx]
                        sum += Double(sc)
                        if sc > localBest {
                            localBest = sc
                            localBestSeed = s
                        }
                        if sc >= stage1Gate {
                            survivors.append(s)
                        }
                    }

                    p.stats.addMPS(count: job.count, scoreSum: sum)
                    if localBest.isFinite {
                        _ = p.bestApproxStage1.updateIfBetter(seed: localBestSeed, score: localBest)
                    }
                }
            } catch {
                p.printLock.lock()
                print("Warning: MPS stage1 run error: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
            }

            completed += job.count
            if !survivors.isEmpty {
                seedQueue.pushMany(survivors)
            }
            return true
        }

        while true {
            maybeReinit()

            while pending.count < inflightFinal {
                if !enqueueNext() { break }
            }
            if !drainOne() { break }
            if p.stop.isStopRequested(), pending.isEmpty { break }
            if let q = quota, completed >= q, pending.isEmpty { break }
        }

        while drainOne() {}

        seedQueue.close()
        stage2Group.wait()
    }

    private func runSingleStage(
        stage1: inout MPSScorer,
        startSeedForLog: UInt64,
        nextSeed: () -> UInt64?,
        quota: Int?,
        claimCount: Int,
        useState: Bool,
        stride: UInt64
    ) {
        p.printLock.lock()
        if useState {
            print("MPS start: \(startSeedForLog) claim=\(claimCount) batch=\(p.mpsBatch) inflight=\(stage1.inflight) count=\(p.endless ? "∞" : "\(p.total)")")
        } else {
            print("MPS start: \(startSeedForLog) stride=\(stride) batch=\(p.mpsBatch) inflight=\(stage1.inflight) count=\(quota.map(String.init) ?? "∞")")
        }
        p.printLock.unlock()

        let inflightFinal = max(1, p.mpsInflight)
        var pending: [MPSScorer.Job] = []
        pending.reserveCapacity(inflightFinal)

        var enqueued = 0
        var completed = 0
        var seeds = [UInt64](repeating: 0, count: max(1, p.mpsBatch))

        var lastReinitNs = DispatchTime.now().uptimeNanoseconds
        var reinitCheck = 0

        func maybeReinit() {
            guard p.mpsReinitIntervalNs > 0 else { return }
            reinitCheck = (reinitCheck + 1) & 127
            guard reinitCheck == 0 else { return }
            guard pending.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReinitNs < p.mpsReinitIntervalNs { return }

            p.printLock.lock()
            print("Reinitializing MPS scorer…")
            p.printLock.unlock()

            do {
                stage1 = try MPSScorer(batchSize: max(1, p.mpsBatch), inflight: inflightFinal)
            } catch {
                p.printLock.lock()
                print("Warning: MPS reinit failed: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
            }
            lastReinitNs = now
        }

        func enqueueNext() -> Bool {
            if p.stop.isStopRequested() { return false }
            if let q = quota, enqueued >= q { return false }

            var n = max(1, p.mpsBatch)
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
                stage1.enqueue(seeds: ptr, count: n)
            }
            pending.append(job)
            enqueued += n
            return true
        }

        func drainOne() -> Bool {
            guard !pending.isEmpty else { return false }
            let job = pending.removeFirst()
            do {
                try stage1.withCompletedJob(job) { seedsBuf, scoresBuf in
                    var sum = 0.0
                    var localBest: Float = -Float.infinity
                    var localBestSeed: UInt64 = 0

                    if p.effectiveDoSubmit, let sub = p.submission, let verifier = p.verifier {
                        let gate = Float(sub.effectiveThreshold() - p.mpsVerifyMargin)
                        var candidates: [(seed: UInt64, score: Float)] = []
                        candidates.reserveCapacity(4)
                        let kMax = 4

                        for idx in 0..<job.count {
                            let sc = scoresBuf[idx]
                            guard sc.isFinite else { continue }
                            let s = seedsBuf[idx]
                            sum += Double(sc)
                            p.topApproxTracker.update(seed: s, score: sc)
                            if sc > localBest {
                                localBest = sc
                                localBestSeed = s
                            }
                            if sc >= gate {
                                candidates.append((seed: s, score: sc))
                            }
                        }
                        p.stats.addMPS(count: job.count, scoreSum: sum)
                        if localBest.isFinite {
                            _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                        }

                        if !candidates.isEmpty {
                            candidates.sort { $0.score > $1.score }
                            if candidates.count > kMax { candidates.removeSubrange(kMax..<candidates.count) }
                            for c in candidates {
                                verifier.enqueue(seed: c.seed, source: "mps")
                            }
                        }
                        return
                    }

                    for idx in 0..<job.count {
                        let sc = scoresBuf[idx]
                        guard sc.isFinite else { continue }
                        let s = seedsBuf[idx]
                        sum += Double(sc)
                        p.topApproxTracker.update(seed: s, score: sc)
                        if sc > localBest {
                            localBest = sc
                            localBestSeed = s
                        }
                    }
                    p.stats.addMPS(count: job.count, scoreSum: sum)
                    if localBest.isFinite {
                        _ = p.bestApprox.updateIfBetter(seed: localBestSeed, score: localBest)
                    }
                }
            } catch {
                p.printLock.lock()
                print("Warning: MPS run error: \(error)")
                p.printLock.unlock()
                p.stop.requestStop()
            }
            completed += job.count
            return true
        }

        while true {
            maybeReinit()

            while pending.count < inflightFinal {
                if !enqueueNext() { break }
            }
            if !drainOne() { break }
            if p.stop.isStopRequested(), pending.isEmpty { break }
            if let q = quota, completed >= q, pending.isEmpty { break }
        }

        while drainOne() {}
    }
}
