import Dispatch
import Foundation

final class ExploreStats: @unchecked Sendable {
    struct Snapshot {
        let cpuCount: UInt64
        let cpuScoreSum: Double
        let mpsCount: UInt64
        let mpsScoreSum: Double
        let mps2Count: UInt64
        let mps2ScoreSum: Double
    }

    private let lock = NSLock()
    private var cpuCount: UInt64 = 0
    private var cpuScoreSum: Double = 0
    private var mpsCount: UInt64 = 0
    private var mpsScoreSum: Double = 0
    private var mps2Count: UInt64 = 0
    private var mps2ScoreSum: Double = 0

    func addCPU(count: Int, scoreSum: Double) {
        guard count > 0 else { return }
        lock.lock()
        cpuCount &+= UInt64(count)
        cpuScoreSum += scoreSum
        lock.unlock()
    }

    func addMPS(count: Int, scoreSum: Double) {
        guard count > 0 else { return }
        lock.lock()
        mpsCount &+= UInt64(count)
        mpsScoreSum += scoreSum
        lock.unlock()
    }

    func addMPS2(count: Int, scoreSum: Double) {
        guard count > 0 else { return }
        lock.lock()
        mps2Count &+= UInt64(count)
        mps2ScoreSum += scoreSum
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(
            cpuCount: cpuCount,
            cpuScoreSum: cpuScoreSum,
            mpsCount: mpsCount,
            mpsScoreSum: mpsScoreSum,
            mps2Count: mps2Count,
            mps2ScoreSum: mps2ScoreSum
        )
        lock.unlock()
        return s
    }
}

final class BestTracker: @unchecked Sendable {
    struct Snapshot {
        let seed: UInt64
        let score: Double
        let source: String?
    }

    private let lock = NSLock()
    private var bestSeed: UInt64 = 0
    private var bestScore: Double = -Double.infinity
    private var bestSource: String? = nil

    func updateIfBetter(seed: UInt64, score: Double, source: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard score > bestScore else { return false }
        bestSeed = seed
        bestScore = score
        bestSource = source
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(seed: bestSeed, score: bestScore, source: bestSource)
        lock.unlock()
        return s
    }
}

final class ApproxBestTracker: @unchecked Sendable {
    struct Snapshot {
        let seed: UInt64
        let score: Float
    }

    private let lock = NSLock()
    private var bestSeed: UInt64 = 0
    private var bestScore: Float = -Float.infinity

    func updateIfBetter(seed: UInt64, score: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard score > bestScore else { return false }
        bestSeed = seed
        bestScore = score
        return true
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(seed: bestSeed, score: bestScore)
        lock.unlock()
        return s
    }
}

final class SubmissionState: @unchecked Sendable {
    struct Snapshot {
        let top500Threshold: Double
        let lastRefresh: Date
        let knownCount: Int
        let attemptedCount: Int
    }

    private let lock = NSLock()
    private var knownSeeds = Set<UInt64>()
    private var attemptedSeeds = Set<UInt64>()
    private var top500Threshold: Double = -Double.infinity
    private var lastRefresh: Date = .distantPast

    func mergeTop(_ top: TopResponse) {
        lock.lock()
        for img in top.images {
            knownSeeds.insert(img.seed)
        }
        if let last = top.images.last {
            top500Threshold = last.score
        }
        lastRefresh = Date()
        lock.unlock()
    }

    func effectiveThreshold(userMinScore: Double) -> Double {
        lock.lock()
        let t = max(userMinScore, top500Threshold)
        lock.unlock()
        return t
    }

    func markAttemptIfEligible(seed: UInt64, score: Double, userMinScore: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard top500Threshold.isFinite else { return false }
        let threshold = max(userMinScore, top500Threshold)
        guard score > threshold else { return false }
        if knownSeeds.contains(seed) { return false }
        if attemptedSeeds.contains(seed) { return false }
        attemptedSeeds.insert(seed)
        return true
    }

    func markAccepted(seed: UInt64) {
        lock.lock()
        knownSeeds.insert(seed)
        attemptedSeeds.insert(seed)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(
            top500Threshold: top500Threshold,
            lastRefresh: lastRefresh,
            knownCount: knownSeeds.count,
            attemptedCount: attemptedSeeds.count
        )
        lock.unlock()
        return s
    }
}

final class SubmissionManager: @unchecked Sendable {
    private let config: AppConfig
    private let state: SubmissionState
    private let userMinScore: Double
    private let printLock: NSLock
    private let queue = DispatchQueue(label: "gobx.submit", qos: .utility)
    private let pending = DispatchGroup()

    init(config: AppConfig, state: SubmissionState, userMinScore: Double, printLock: NSLock) {
        self.config = config
        self.state = state
        self.userMinScore = userMinScore
        self.printLock = printLock
    }

    func effectiveThreshold() -> Double {
        state.effectiveThreshold(userMinScore: userMinScore)
    }

    func stateSnapshot() -> SubmissionState.Snapshot {
        state.snapshot()
    }

    func enqueueRefreshTop500(limit: Int = 500, reason: String? = nil) {
        queue.async {
            Task {
                guard let top = await fetchTop(limit: limit, config: self.config) else { return }
                self.state.mergeTop(top)
                let snap = self.state.snapshot()
                self.printLock.withLock {
                    let why = reason.map { " (\($0))" } ?? ""
                    print("Refreshed top \(limit) threshold=\(String(format: "%.6f", snap.top500Threshold)) known=\(snap.knownCount)\(why)")
                }
            }
        }
    }

    func maybeEnqueueSubmission(seed: UInt64, score: Double, source: String?) {
        guard score > userMinScore else { return }
        guard state.markAttemptIfEligible(seed: seed, score: score, userMinScore: userMinScore) else { return }
        pending.enter()
        queue.async {
            Task {
                defer { self.pending.leave() }

                guard let res = await submitScore(seed: seed, score: score, config: self.config) else {
                    self.printLock.withLock {
                        print("Submission failed for \(seed)")
                    }
                    return
                }

                let tag = source.map { " (\($0))" } ?? ""
                if res.accepted {
                    self.state.markAccepted(seed: seed)
                    self.printLock.withLock {
                        print("Accepted seed=\(seed) score=\(String(format: "%.6f", score)) rank=\(res.rank ?? 0)\(tag)")
                    }
                } else {
                    self.printLock.withLock {
                        print("Rejected seed=\(seed) score=\(String(format: "%.6f", score)) (\(res.message ?? "unknown"))\(tag)")
                    }
                }
            }
        }
    }

    func waitForPendingSubmissions() {
        pending.wait()
    }
}

final class CandidateVerifier: @unchecked Sendable {
    private let best: BestTracker
    private let submission: SubmissionManager?
    private let printLock: NSLock
    private let queue = DispatchQueue(label: "gobx.verify", qos: .utility)
    private let pending = DispatchGroup()
    private let seenLock = NSLock()
    private var seenSeeds = Set<UInt64>()
    private let pendingLock = NSLock()
    private var pendingCount = 0
    private let maxPending: Int
    private let scorer: Scorer

    init(best: BestTracker, submission: SubmissionManager?, printLock: NSLock, maxPending: Int = 512) {
        self.best = best
        self.submission = submission
        self.printLock = printLock
        self.maxPending = max(1, maxPending)
        self.scorer = Scorer(size: 128)
    }

    func enqueue(seed: UInt64, source: String) {
        pendingLock.lock()
        if pendingCount >= maxPending {
            pendingLock.unlock()
            return
        }
        pendingCount += 1
        pendingLock.unlock()

        seenLock.lock()
        if seenSeeds.contains(seed) {
            seenLock.unlock()
            pendingLock.lock()
            pendingCount -= 1
            pendingLock.unlock()
            return
        }
        seenSeeds.insert(seed)
        seenLock.unlock()

        pending.enter()
        queue.async {
            defer { self.pending.leave() }
            defer {
                self.pendingLock.lock()
                self.pendingCount -= 1
                self.pendingLock.unlock()
            }
            let exact = self.scorer.score(seed: seed).totalScore

            if self.best.updateIfBetter(seed: seed, score: exact, source: source) {
                let tag = " (\(source))"
                self.printLock.lock()
                print("New best score: \(String(format: "%.6f", exact)) seed: \(seed)\(tag)")
                self.printLock.unlock()
            }

            self.submission?.maybeEnqueueSubmission(seed: seed, score: exact, source: source)
        }
    }

    func wait() {
        pending.wait()
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func isStopRequested() -> Bool {
        lock.lock()
        let v = stopRequested
        lock.unlock()
        return v
    }
}
