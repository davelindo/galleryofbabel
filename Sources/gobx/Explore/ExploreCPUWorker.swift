@preconcurrency import Dispatch
import Foundation

final class ExploreCPUWorker: @unchecked Sendable {
    struct Params {
        let resolvedBackend: Backend
        let threadCount: Int
        let endless: Bool
        let total: Int
        let claimSize: Int
        let allocator: SeedRangeAllocator?
        let baseSeed: UInt64
        let flushIntervalNs: UInt64
        let printLock: NSLock
        let stats: ExploreStats
        let best: BestTracker
        let submission: SubmissionManager?
        let effectiveDoSubmit: Bool
        let stop: StopFlag
    }

    private let p: Params

    init(params: Params) {
        self.p = params
    }

    func run() {
        let allocator = p.allocator
        let useState = (allocator != nil)
        let step = allocator?.stepValue ?? 0
        let spaceSize = allocator?.spaceSizeValue ?? 0

        let baseSeed = p.baseSeed
        let totalWorkers = max(1, p.threadCount + (p.resolvedBackend == .all ? 1 : 0))
        let stride = UInt64(totalWorkers)

        @Sendable func workerQuota(workerIndex: Int, totalWorkers: Int) -> Int {
            let base = p.total / totalWorkers
            let rem = p.total % totalWorkers
            return base + (workerIndex < rem ? 1 : 0)
        }

        DispatchQueue.concurrentPerform(iterations: p.threadCount) { tid in
            let scorer = Scorer(size: 128)
            let quota = (useState || p.endless) ? nil : workerQuota(workerIndex: tid, totalWorkers: totalWorkers)

            var seed: UInt64 = nextV2Seed(baseSeed, by: UInt64(tid))
            var offset: UInt64 = 0
            var remainingInClaim = 0

            if useState, let alloc = allocator, let c = alloc.claim(maxCount: p.claimSize) {
                offset = c.offset
                remainingInClaim = c.count
                seed = V2SeedSpace.min &+ offset
            } else if useState {
                return
            }

            let source = p.resolvedBackend == .all ? "cpu" : nil

            p.printLock.lock()
            if p.resolvedBackend == .all {
                if useState {
                    print("CPU thread \(tid) start: \(seed) claim=\(p.claimSize) count=\(p.endless ? "∞" : "\(p.total)")")
                } else {
                    print("CPU thread \(tid) start: \(seed) stride=\(stride) count=\(quota.map(String.init) ?? "∞")")
                }
            } else {
                if useState {
                    print("Thread \(tid) start: \(seed) claim=\(p.claimSize) count=\(p.endless ? "∞" : "\(p.total)")")
                } else {
                    let cpuStride = UInt64(max(1, p.threadCount))
                    print("Thread \(tid) start: \(seed) stride=\(cpuStride) count=\(quota.map(String.init) ?? "∞")")
                }
            }
            p.printLock.unlock()

            var localBest = -Double.infinity
            var processed = 0
            var flushCount = 0
            var flushSum = 0.0
            let flushEvery = 512
            var lastFlushNs = DispatchTime.now().uptimeNanoseconds
            var flushCheck = 0

            var stopCheck = 0
            while true {
                if let q = quota, processed >= q { break }
                if stopCheck == 0, p.stop.isStopRequested() { break }

                if useState {
                    if remainingInClaim == 0 {
                        guard let alloc = allocator, let c = alloc.claim(maxCount: p.claimSize) else { break }
                        offset = c.offset
                        remainingInClaim = c.count
                    }
                    seed = V2SeedSpace.min &+ offset
                    offset &+= step
                    if offset >= spaceSize { offset &-= spaceSize }
                    remainingInClaim -= 1
                }

                let r = scorer.score(seed: seed)
                let score = r.totalScore

                processed += 1
                flushCount += 1
                flushSum += score

                if score > localBest {
                    localBest = score
                    maybePrintNewBest(seed: seed, score: score, source: source)
                }

                if p.effectiveDoSubmit, let sub = p.submission {
                    sub.maybeEnqueueSubmission(seed: seed, score: score, source: source)
                }

                if flushCount >= flushEvery {
                    p.stats.addCPU(count: flushCount, scoreSum: flushSum)
                    flushCount = 0
                    flushSum = 0
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                } else if p.flushIntervalNs > 0 {
                    flushCheck = (flushCheck + 1) & 31
                    if flushCheck == 0 {
                        let now = DispatchTime.now().uptimeNanoseconds
                        if now &- lastFlushNs >= p.flushIntervalNs, flushCount > 0 {
                            p.stats.addCPU(count: flushCount, scoreSum: flushSum)
                            flushCount = 0
                            flushSum = 0
                            lastFlushNs = now
                        }
                    }
                }

                if !useState {
                    seed = nextV2Seed(seed, by: stride)
                }
                stopCheck = (stopCheck + 1) & 1023
            }

            if flushCount > 0 {
                p.stats.addCPU(count: flushCount, scoreSum: flushSum)
            }
        }
    }

    private func maybePrintNewBest(seed: UInt64, score: Double, source: String?) {
        guard p.best.updateIfBetter(seed: seed, score: score, source: source) else { return }
        let tag = source.map { " (\($0))" } ?? ""
        p.printLock.lock()
        print("New best score: \(String(format: "%.6f", score)) seed: \(seed)\(tag)")
        p.printLock.unlock()
    }
}
