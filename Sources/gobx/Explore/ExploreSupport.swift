import Dispatch
import Foundation

final class ExploreStats: @unchecked Sendable {
    struct Snapshot {
        let cpuCount: UInt64
        let cpuScoreSum: Double
        let cpuScoreSumSq: Double
        let cpuVerifyCount: UInt64
        let cpuVerifyScoreSum: Double
        let cpuVerifyScoreSumSq: Double
        let mpsCount: UInt64
        let mpsScoreSum: Double
        let mpsScoreSumSq: Double
    }

    private let lock = NSLock()
    private var cpuCount: UInt64 = 0
    private var cpuScoreSum: Double = 0
    private var cpuScoreSumSq: Double = 0
    private var cpuVerifyCount: UInt64 = 0
    private var cpuVerifyScoreSum: Double = 0
    private var cpuVerifyScoreSumSq: Double = 0
    private var mpsCount: UInt64 = 0
    private var mpsScoreSum: Double = 0
    private var mpsScoreSumSq: Double = 0

    func addCPU(count: Int, scoreSum: Double, scoreSumSq: Double) {
        guard count > 0 else { return }
        lock.lock()
        cpuCount &+= UInt64(count)
        cpuScoreSum += scoreSum
        cpuScoreSumSq += scoreSumSq
        lock.unlock()
    }

    func addCPUVerify(count: Int, scoreSum: Double, scoreSumSq: Double) {
        guard count > 0 else { return }
        lock.lock()
        cpuVerifyCount &+= UInt64(count)
        cpuVerifyScoreSum += scoreSum
        cpuVerifyScoreSumSq += scoreSumSq
        lock.unlock()
    }

    func addMPS(count: Int, scoreSum: Double, scoreSumSq: Double) {
        guard count > 0 else { return }
        lock.lock()
        mpsCount &+= UInt64(count)
        mpsScoreSum += scoreSum
        mpsScoreSumSq += scoreSumSq
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(
            cpuCount: cpuCount,
            cpuScoreSum: cpuScoreSum,
            cpuScoreSumSq: cpuScoreSumSq,
            cpuVerifyCount: cpuVerifyCount,
            cpuVerifyScoreSum: cpuVerifyScoreSum,
            cpuVerifyScoreSumSq: cpuVerifyScoreSumSq,
            mpsCount: mpsCount,
            mpsScoreSum: mpsScoreSum,
            mpsScoreSumSq: mpsScoreSumSq
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

final class AdaptiveMargin: @unchecked Sendable {
    struct Update {
        let oldValue: Double
        let newValue: Double
        let target: Double
        let sampleCount: Int
        let quantile: Double
    }

    private let lock = NSLock()
    private var margin: Double
    private var samples: [Double] = []

    let autoEnabled: Bool
    private let minMargin: Double
    private let maxMargin: Double
    private let quantile: Double
    private let safety: Double
    private let maxSamples: Int
    private let minSamples: Int
    private let decay: Double
    private let minDelta: Double

    init(
        initial: Double,
        autoEnabled: Bool,
        minMargin: Double = 0.0,
        maxMargin: Double = 0.5,
        quantile: Double = 0.995,
        safety: Double = 0.002,
        maxSamples: Int = 1024,
        minSamples: Int = 64,
        decay: Double = 0.1,
        minDelta: Double = 0.001
    ) {
        self.margin = max(minMargin, initial)
        self.autoEnabled = autoEnabled
        self.minMargin = minMargin
        self.maxMargin = maxMargin
        self.quantile = min(1.0, max(0.5, quantile))
        self.safety = max(0.0, safety)
        self.maxSamples = max(128, maxSamples)
        self.minSamples = max(16, minSamples)
        self.decay = min(1.0, max(0.0, decay))
        self.minDelta = max(0.0, minDelta)
    }

    func current() -> Double {
        lock.lock()
        let v = margin
        lock.unlock()
        return v
    }

    func recordSample(mpsScore: Double, cpuScore: Double) -> Update? {
        guard autoEnabled else { return nil }
        guard mpsScore.isFinite, cpuScore.isFinite else { return nil }
        let under = max(0.0, cpuScore - mpsScore)

        lock.lock()
        samples.append(under)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        guard samples.count >= minSamples else {
            lock.unlock()
            return nil
        }

        let sorted = samples.sorted()
        let qVal = CalibrationSupport.quantile(sorted, q: quantile)
        var target = qVal + safety
        if target < minMargin { target = minMargin }
        if target > maxMargin { target = maxMargin }

        let old = margin
        var next = margin
        if target > margin {
            next = target
        } else if target < margin, decay > 0 {
            next = max(target, margin - (margin - target) * decay)
        }

        guard abs(next - old) >= minDelta else {
            lock.unlock()
            return nil
        }
        margin = next
        let update = Update(oldValue: old, newValue: next, target: target, sampleCount: samples.count, quantile: quantile)
        lock.unlock()
        return update
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
    private var topScores: [Double] = []
    private var top500Threshold: Double = -Double.infinity
    private var lastRefresh: Date = .distantPast

    func mergeTop(_ top: TopResponse) {
        lock.lock()
        topScores = top.images.map { $0.score }.sorted(by: >)
        for img in top.images {
            knownSeeds.insert(img.seed)
        }
        if let last = topScores.last {
            top500Threshold = last
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

    func markAttempted(seed: UInt64) {
        lock.lock()
        attemptedSeeds.insert(seed)
        lock.unlock()
    }

    func isKnown(seed: UInt64) -> Bool {
        lock.lock()
        let known = knownSeeds.contains(seed)
        lock.unlock()
        return known
    }

    func difficultyPercentile(score: Double) -> Double? {
        lock.lock()
        let scores = topScores
        lock.unlock()
        guard !scores.isEmpty else { return nil }
        if scores.count == 1 { return 1.0 }
        if score >= scores[0] { return 1.0 }
        if score <= scores[scores.count - 1] { return 0.0 }

        var lo = 0
        var hi = scores.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if scores[mid] > score {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let above = max(0, min(scores.count - 1, lo))
        return Double(scores.count - above - 1) / Double(scores.count - 1)
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

actor SubmissionRateLimiter {
    private var timestamps: [TimeInterval] = []
    private var backoffUntil: TimeInterval = 0.0
    private var backoffStep: Int = 0
    private let optimistic: Bool

    private let maxPerWindow: Int
    private let windowSec: TimeInterval
    private let baseBackoffSec: TimeInterval
    private let maxBackoffSec: TimeInterval
    private let jitterFrac: Double

    init(
        maxPerWindow: Int = 10,
        windowSec: TimeInterval = 60.0,
        baseBackoffSec: TimeInterval = 1.0,
        maxBackoffSec: TimeInterval = 60.0,
        jitterFrac: Double = 0.15,
        optimistic: Bool = true
    ) {
        self.maxPerWindow = max(1, maxPerWindow)
        self.windowSec = max(1.0, windowSec)
        self.baseBackoffSec = max(0.1, baseBackoffSec)
        self.maxBackoffSec = max(self.baseBackoffSec, maxBackoffSec)
        self.jitterFrac = max(0.0, jitterFrac)
        self.optimistic = optimistic
    }

    func acquire() async {
        while true {
            let now = Date().timeIntervalSinceReferenceDate

            var wait: TimeInterval = 0.0
            if !optimistic {
                timestamps.removeAll { now - $0 >= windowSec }
                if timestamps.count >= maxPerWindow, let oldest = timestamps.first {
                    wait = max(wait, oldest + windowSec - now)
                }
            }
            if backoffUntil > now {
                wait = max(wait, backoffUntil - now)
            }

            if wait <= 0 {
                if !optimistic {
                    timestamps.append(now)
                }
                return
            }

            let ns = UInt64((wait * 1_000_000_000).rounded(.up))
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    func backoffDelay() -> TimeInterval {
        let now = Date().timeIntervalSinceReferenceDate
        if backoffUntil > now {
            return backoffUntil - now
        }
        return 0.0
    }

    func recordRateLimit() -> TimeInterval {
        let now = Date().timeIntervalSinceReferenceDate
        backoffStep = min(backoffStep + 1, 10)
        let raw = baseBackoffSec * pow(2.0, Double(backoffStep - 1))
        let delay = min(maxBackoffSec, raw)
        let jitter = delay * jitterFrac * Double.random(in: -1.0...1.0)
        let finalDelay = max(0.0, delay + jitter)
        backoffUntil = max(backoffUntil, now + finalDelay)
        return finalDelay
    }

    func recordSuccess() {
        backoffStep = 0
        backoffUntil = 0.0
    }
}

final class SubmissionManager: @unchecked Sendable {
    struct AcceptedSeed: Sendable {
        let time: Date
        let seed: UInt64
        let score: Double
        let difficultyPercentile: Double?
        let rank: Int?
        let source: String?
    }

    private struct SubmissionTask: Sendable {
        let seed: UInt64
        let score: Double
        let source: String?
        let seq: UInt64
    }

    private enum SubmissionOutcome {
        case completed
        case requeue(delay: TimeInterval)
    }

    private struct SubmissionJournal: Codable {
        let version: Int
        let updatedAt: Date
        let entries: [SubmissionJournalEntry]
    }

    private struct SubmissionJournalEntry: Codable {
        let seed: UInt64
        let score: Double
        let source: String?
        let seq: UInt64
    }

    struct StatsSnapshot: Sendable {
        let submitAttempts: UInt64
        let acceptedCount: UInt64
        let rejectedCount: UInt64
        let rateLimitedCount: UInt64
        let failedCount: UInt64
        let queuedCount: Int
        let queuedMinScore: Double?
        let queuedMaxScore: Double?
    }

    private let config: AppConfig
    private let state: SubmissionState
    private let userMinScore: Double
    private let topUniqueUsers: Bool
    private let printLock: NSLock
    private let events: ExploreEventLog?
    private let queue = DispatchQueue(label: "gobx.submit", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let pending = DispatchGroup()
    private let limiter = SubmissionRateLimiter(optimistic: true)
    private let maxRetries = 8
    private let retryBaseSec: TimeInterval = 1.0
    private let retryMaxSec: TimeInterval = 30.0
    private let retryJitter: Double = 0.2
    private let statsLock = NSLock()
    private var submitAttempts: UInt64 = 0
    private var acceptedCount: UInt64 = 0
    private var rejectedCount: UInt64 = 0
    private var rateLimitedCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var queuedCount: Int = 0
    private var queuedMinScore: Double? = nil
    private var queuedMaxScore: Double? = nil
    private var submitSeq: UInt64 = 0
    private var submitQueue: [SubmissionTask] = []
    private var isSubmitting = false
    private var activeTask: SubmissionTask? = nil
    private let journalURL: URL = GobxPaths.submissionQueueURL
    private var journalLoaded = false
    private var journalDeferred = false
    private var journalWritePending = false
    private let journalWriteDelay: TimeInterval = 1.0
    private var backoffScheduled = false
    private let acceptedLock = NSLock()
    private var accepted: [AcceptedSeed] = []
    private var acceptedBest: [AcceptedSeed] = []
    private let acceptedCapacity = 20

    init(
        config: AppConfig,
        state: SubmissionState,
        userMinScore: Double,
        topUniqueUsers: Bool,
        printLock: NSLock,
        events: ExploreEventLog?
    ) {
        self.config = config
        self.state = state
        self.userMinScore = userMinScore
        self.topUniqueUsers = topUniqueUsers
        self.printLock = printLock
        self.events = events
        queue.setSpecific(key: queueKey, value: 1)
        submitQueue.reserveCapacity(64)
        maybeLoadSubmissionJournal()
    }

    private func emit(_ kind: ExploreEventKind, _ message: String) {
        if let events {
            events.append(kind, message)
        } else {
            printLock.withLock { print(message) }
        }
    }

    private func retryDelay(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        let raw = retryBaseSec * pow(2.0, Double(step - 1))
        let delay = min(retryMaxSec, raw)
        let jitter = delay * retryJitter * Double.random(in: -1.0...1.0)
        return max(0.0, delay + jitter)
    }

    func effectiveThreshold() -> Double {
        state.effectiveThreshold(userMinScore: userMinScore)
    }

    func stateSnapshot() -> SubmissionState.Snapshot {
        state.snapshot()
    }

    func acceptedSnapshot(limit: Int) -> [AcceptedSeed] {
        acceptedLock.lock()
        let n = min(max(0, limit), accepted.count)
        let out = n == 0 ? [] : Array(accepted.suffix(n).reversed())
        acceptedLock.unlock()
        return out
    }

    func acceptedBestSnapshot(limit: Int) -> [AcceptedSeed] {
        acceptedLock.lock()
        let n = min(max(0, limit), acceptedBest.count)
        let out = n == 0 ? [] : Array(acceptedBest.prefix(n))
        acceptedLock.unlock()
        return out
    }

    private func updateAcceptedBestLocked(_ entry: AcceptedSeed) {
        func difficulty(_ e: AcceptedSeed) -> Double {
            e.difficultyPercentile ?? -1.0
        }
        acceptedBest.append(entry)
        acceptedBest.sort {
            let da = difficulty($0)
            let db = difficulty($1)
            if da != db { return da > db }
            return $0.score > $1.score
        }
        if acceptedBest.count > 3 {
            acceptedBest.removeLast(acceptedBest.count - 3)
        }
    }

    func statsSnapshot() -> StatsSnapshot {
        statsLock.lock()
        let snap = StatsSnapshot(
            submitAttempts: submitAttempts,
            acceptedCount: acceptedCount,
            rejectedCount: rejectedCount,
            rateLimitedCount: rateLimitedCount,
            failedCount: failedCount,
            queuedCount: queuedCount,
            queuedMinScore: queuedMinScore,
            queuedMaxScore: queuedMaxScore
        )
        statsLock.unlock()
        return snap
    }

    private func updateQueueStatsLocked() {
        let count = submitQueue.count
        let minScore = submitQueue.last?.score
        let maxScore = submitQueue.first?.score
        statsLock.lock()
        queuedCount = max(0, count)
        queuedMinScore = minScore
        queuedMaxScore = maxScore
        statsLock.unlock()
    }

    private func pruneQueueLocked(threshold: Double) {
        guard !submitQueue.isEmpty else { return }
        var removed = 0
        submitQueue.removeAll {
            let drop = $0.score <= threshold || state.isKnown(seed: $0.seed)
            if drop { removed += 1 }
            return drop
        }
        guard removed > 0 else { return }
        for _ in 0..<removed {
            pending.leave()
        }
        updateQueueStatsLocked()
        scheduleJournalWrite()
    }

    private func recordSubmitAttempt() {
        statsLock.lock()
        submitAttempts &+= 1
        statsLock.unlock()
    }

    private func recordAccepted() {
        statsLock.lock()
        acceptedCount &+= 1
        statsLock.unlock()
    }

    private func recordRejected() {
        statsLock.lock()
        rejectedCount &+= 1
        statsLock.unlock()
    }

    private func recordRateLimited() {
        statsLock.lock()
        rateLimitedCount &+= 1
        statsLock.unlock()
    }

    private func recordFailed() {
        statsLock.lock()
        failedCount &+= 1
        statsLock.unlock()
    }

    func enqueueRefreshTop500(limit: Int = 500, reason: String? = nil) {
        queue.async {
            Task {
                guard let top = await fetchTop(limit: limit, config: self.config, uniqueUsers: self.topUniqueUsers) else { return }
                self.state.mergeTop(top)
                self.queue.async {
                    self.maybeLoadSubmissionJournal()
                    let snap = self.state.snapshot()
                    let threshold = max(self.userMinScore, snap.top500Threshold)
                    self.pruneQueueLocked(threshold: threshold)
                }
                let snap = self.state.snapshot()
                let why = reason.map { " (\($0))" } ?? ""
                self.emit(.info, "Refreshed top \(limit) threshold=\(String(format: "%.6f", snap.top500Threshold)) known=\(snap.knownCount)\(why)")
            }
        }
    }

    func maybeEnqueueSubmission(seed: UInt64, score: Double, source: String?) {
        guard score > userMinScore else { return }
        guard state.markAttemptIfEligible(seed: seed, score: score, userMinScore: userMinScore) else { return }
        pending.enter()
        queue.async {
            self.submitSeq &+= 1
            let task = SubmissionTask(seed: seed, score: score, source: source, seq: self.submitSeq)
            self.insertTaskSorted(task)
            self.updateQueueStatsLocked()
            self.scheduleJournalWrite()
            if !self.isSubmitting {
                self.isSubmitting = true
                self.submitNextLocked()
            }
        }
    }

    func waitForPendingSubmissions() {
        pending.wait()
    }

    func flushJournal() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            writeJournalLocked()
        } else {
            queue.sync { self.writeJournalLocked() }
        }
    }

    private func insertTaskSorted(_ task: SubmissionTask) {
        if submitQueue.isEmpty {
            submitQueue.append(task)
            return
        }

        func isBefore(_ lhs: SubmissionTask, _ rhs: SubmissionTask) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.seq < rhs.seq
        }

        var lo = 0
        var hi = submitQueue.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isBefore(task, submitQueue[mid]) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        submitQueue.insert(task, at: lo)
    }

    private func submitNextLocked() {
        guard !submitQueue.isEmpty else {
            isSubmitting = false
            activeTask = nil
            updateQueueStatsLocked()
            scheduleJournalWrite()
            return
        }

        let task = submitQueue.removeFirst()
        activeTask = task
        updateQueueStatsLocked()
        scheduleJournalWrite()
        Task {
            let outcome = await self.process(task)
            self.queue.async {
                switch outcome {
                case .completed:
                    self.pending.leave()
                    if let active = self.activeTask, active.seed == task.seed {
                        self.activeTask = nil
                    }
                    self.scheduleJournalWrite()
                    self.submitNextLocked()
                case .requeue(let delay):
                    if let active = self.activeTask, active.seed == task.seed {
                        self.activeTask = nil
                    }
                    self.insertTaskSorted(task)
                    self.updateQueueStatsLocked()
                    self.scheduleJournalWrite()
                    self.scheduleBackoff(delay)
                }
            }
        }
    }

    private func process(_ task: SubmissionTask) async -> SubmissionOutcome {
        let tag = task.source.map { " (\($0))" } ?? ""
        var attempts = 0
        while true {
            let delay = await limiter.backoffDelay()
            if delay > 0 {
                return .requeue(delay: delay)
            }
            await limiter.acquire()
            recordSubmitAttempt()
            guard let res = await submitScore(seed: task.seed, score: task.score, config: config) else {
                attempts += 1
                if attempts > maxRetries {
                    emit(.error, "Submission failed for \(task.seed)\(tag)")
                    recordFailed()
                    return .completed
                }
                let delay = retryDelay(attempt: attempts)
                emit(.warning, "Submission failed for \(task.seed)\(tag), retrying in \(String(format: "%.1f", delay))s")
                let ns = UInt64((delay * 1_000_000_000).rounded(.up))
                try? await Task.sleep(nanoseconds: ns)
                continue
            }

            if res.accepted {
                await limiter.recordSuccess()
                state.markAccepted(seed: task.seed)
                recordAccepted()
                let percentile = state.difficultyPercentile(score: task.score)
                acceptedLock.withLock {
                    let entry = AcceptedSeed(
                        time: Date(),
                        seed: task.seed,
                        score: task.score,
                        difficultyPercentile: percentile,
                        rank: res.rank,
                        source: task.source
                    )
                    accepted.append(entry)
                    if accepted.count > acceptedCapacity {
                        accepted.removeFirst(accepted.count - acceptedCapacity)
                    }
                    updateAcceptedBestLocked(entry)
                }
                let pctStr = percentile.map { String(format: " p=%.2f%%", $0 * 100.0) } ?? ""
                emit(.accepted, "Accepted seed=\(task.seed) score=\(String(format: "%.6f", task.score)) rank=\(res.rank ?? 0)\(pctStr)\(tag)")
                return .completed
            }

            if res.isRateLimited {
                recordRateLimited()
                let delay = await limiter.recordRateLimit()
                emit(.warning, "Rate limited submitting seed=\(task.seed)\(tag), backing off \(String(format: "%.1f", delay))s")
                return .requeue(delay: delay)
            }

            if res.isRetryableServerError {
                attempts += 1
                if attempts > maxRetries {
                    emit(.error, "Submission failed for \(task.seed)\(tag) (\(res.message ?? "unknown"))")
                    recordFailed()
                    return .completed
                }
                let delay = retryDelay(attempt: attempts)
                emit(.warning, "Submission failed for \(task.seed)\(tag) (\(res.message ?? "unknown")), retrying in \(String(format: "%.1f", delay))s")
                let ns = UInt64((delay * 1_000_000_000).rounded(.up))
                try? await Task.sleep(nanoseconds: ns)
                continue
            }

            await limiter.recordSuccess()
            recordRejected()
            emit(.rejected, "Rejected seed=\(task.seed) score=\(String(format: "%.6f", task.score)) (\(res.message ?? "unknown"))\(tag)")
            return .completed
        }
    }

    private func scheduleBackoff(_ delay: TimeInterval) {
        let wait = max(0.0, delay)
        if wait <= 0.0 {
            submitNextLocked()
            return
        }
        guard !backoffScheduled else { return }
        backoffScheduled = true
        queue.asyncAfter(deadline: .now() + wait) {
            self.backoffScheduled = false
            self.submitNextLocked()
        }
    }

    private func scheduleJournalWrite() {
        guard !journalWritePending else { return }
        journalWritePending = true
        queue.asyncAfter(deadline: .now() + journalWriteDelay) {
            self.writeJournalLocked()
        }
    }

    private func writeJournalLocked() {
        journalWritePending = false
        var entries = submitQueue
        if let activeTask {
            entries.insert(activeTask, at: 0)
        }
        if entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: journalURL)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain != NSCocoaErrorDomain || nsErr.code != CocoaError.fileNoSuchFile.rawValue {
                    emit(.warning, "Warning: failed to remove submission queue journal: \(error)")
                }
            }
            return
        }

        let payload = SubmissionJournal(
            version: 1,
            updatedAt: Date(),
            entries: entries.map {
                SubmissionJournalEntry(seed: $0.seed, score: $0.score, source: $0.source, seq: $0.seq)
            }
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try enc.encode(payload)
            try data.write(to: journalURL, options: .atomic)
        } catch {
            emit(.warning, "Warning: failed to write submission queue journal: \(error)")
        }
    }

    private func maybeLoadSubmissionJournal() {
        guard !journalLoaded else { return }
        let url = journalURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let snap = state.snapshot()
        guard snap.top500Threshold.isFinite else {
            journalDeferred = true
            return
        }
        journalDeferred = false
        journalLoaded = true
        let threshold = max(userMinScore, snap.top500Threshold)
        loadSubmissionJournal(from: url, threshold: threshold)
    }

    private func loadSubmissionJournal(from url: URL, threshold: Double) {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let journal = try? dec.decode(SubmissionJournal.self, from: data) else {
            emit(.warning, "Warning: failed to decode submission queue journal at \(url.path)")
            return
        }
        guard journal.version == 1 else {
            emit(.warning, "Warning: unsupported submission queue journal version=\(journal.version) at \(url.path)")
            return
        }

        var bySeed: [UInt64: SubmissionTask] = [:]
        bySeed.reserveCapacity(journal.entries.count)
        var maxSeq: UInt64 = submitSeq
        for entry in journal.entries {
            guard entry.score.isFinite else { continue }
            let task = SubmissionTask(seed: entry.seed, score: entry.score, source: entry.source, seq: entry.seq)
            if entry.seq > maxSeq { maxSeq = entry.seq }
            if let existing = bySeed[entry.seed] {
                if task.score > existing.score || (task.score == existing.score && task.seq < existing.seq) {
                    bySeed[entry.seed] = task
                }
            } else {
                bySeed[entry.seed] = task
            }
        }

        let tasks = Array(bySeed.values).sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.seq < $1.seq
        }
        submitSeq = maxSeq
        submitQueue.removeAll(keepingCapacity: true)
        for task in tasks {
            guard task.score > threshold else { continue }
            guard state.markAttemptIfEligible(seed: task.seed, score: task.score, userMinScore: userMinScore) else { continue }
            submitQueue.append(task)
            pending.enter()
        }
        updateQueueStatsLocked()
        scheduleJournalWrite()
        queue.async {
            guard !self.submitQueue.isEmpty else { return }
            if !self.isSubmitting {
                self.isSubmitting = true
                self.submitNextLocked()
            }
        }
    }
}

final class AdaptiveScoreShift: @unchecked Sendable {
    struct Update {
        let oldValue: Double
        let newValue: Double
        let target: Double
        let meanDelta: Double
        let sampleCount: Int
    }

    private let lock = NSLock()
    private var shift: Double
    private var samples: [Double] = []
    private var sum: Double = 0.0

    let autoEnabled: Bool
    private let minShift: Double
    private let maxShift: Double
    private let safety: Double
    private let maxSamples: Int
    private let minSamples: Int
    private let decay: Double
    private let minDelta: Double

    init(
        initial: Double,
        autoEnabled: Bool,
        minShift: Double = 0.0,
        maxShift: Double = 0.5,
        safety: Double = 0.0,
        maxSamples: Int = 1024,
        minSamples: Int = 64,
        decay: Double = 0.1,
        minDelta: Double = 0.001
    ) {
        self.shift = min(maxShift, max(minShift, initial))
        self.autoEnabled = autoEnabled
        self.minShift = minShift
        self.maxShift = maxShift
        self.safety = max(0.0, safety)
        self.maxSamples = max(128, maxSamples)
        self.minSamples = max(16, minSamples)
        self.decay = min(1.0, max(0.0, decay))
        self.minDelta = max(0.0, minDelta)
    }

    func current() -> Double {
        lock.lock()
        let v = shift
        lock.unlock()
        return v
    }

    func recordSample(mpsScore: Double, cpuScore: Double) -> Update? {
        guard autoEnabled else { return nil }
        guard mpsScore.isFinite, cpuScore.isFinite else { return nil }

        let delta = cpuScore - mpsScore

        lock.lock()
        samples.append(delta)
        sum += delta
        if samples.count > maxSamples {
            let drop = samples.count - maxSamples
            for _ in 0..<drop {
                if let first = samples.first {
                    sum -= first
                    samples.removeFirst()
                }
            }
        }
        guard samples.count >= minSamples else {
            lock.unlock()
            return nil
        }

        let meanDelta = sum / Double(samples.count)
        var target = -meanDelta + safety
        if target < minShift { target = minShift }
        if target > maxShift { target = maxShift }

        let old = shift
        var next = shift
        if target > shift {
            next = target
        } else if target < shift, decay > 0 {
            next = max(target, shift - (shift - target) * decay)
        }
        if abs(next - old) < minDelta {
            lock.unlock()
            return nil
        }
        shift = next
        lock.unlock()

        return Update(oldValue: old, newValue: next, target: target, meanDelta: meanDelta, sampleCount: samples.count)
    }
}

final class ThrottledAdjustmentLog: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var lastEmit: TimeInterval = 0.0
    private var startValue: Double = 0.0
    private var lastValue: Double = 0.0
    private var lastTarget: Double = 0.0
    private var lastMeta: String = ""
    private var updateCount: Int = 0

    init(interval: TimeInterval) {
        self.interval = max(1.0, interval)
    }

    func record(oldValue: Double, newValue: Double, target: Double, meta: String) -> String? {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        if updateCount == 0 {
            startValue = oldValue
            if lastEmit == 0.0 {
                lastEmit = now
            }
        }
        lastValue = newValue
        lastTarget = target
        lastMeta = meta
        updateCount += 1

        guard now - lastEmit >= interval else {
            lock.unlock()
            return nil
        }

        let net = lastValue - startValue
        let msg = String(
            format: "%.6f -> %.6f (Δ=%+.6f updates=%d target=%.6f %@)",
            startValue, lastValue, net, updateCount, lastTarget, lastMeta
        )
        startValue = lastValue
        updateCount = 0
        lastEmit = now
        lock.unlock()
        return msg
    }
}

private enum VerifyPriority {
    case candidate
    case sample
}

private struct VerifyTask {
    let seed: UInt64
    let source: String
    let mpsScore: Float?
    let mpsScoreRaw: Float?
    let priority: VerifyPriority
}

private final class VerifyQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var high: [VerifyTask] = []
    private var low: [VerifyTask] = []
    private var closed = false
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        high.reserveCapacity(min(64, self.capacity))
        low.reserveCapacity(min(64, self.capacity))
    }

    func push(_ task: VerifyTask) -> (enqueued: Bool, dropped: VerifyTask?) {
        cond.lock()
        defer { cond.unlock() }
        if closed { return (false, nil) }
        let count = high.count + low.count
        if count >= capacity {
            if task.priority == .sample {
                return (false, nil)
            }
            if !low.isEmpty {
                let dropped = low.removeFirst()
                high.append(task)
                cond.signal()
                return (true, dropped)
            }
            return (false, nil)
        }

        switch task.priority {
        case .candidate:
            high.append(task)
        case .sample:
            low.append(task)
        }
        cond.signal()
        return (true, nil)
    }

    func pop() -> VerifyTask? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if !high.isEmpty {
                return high.removeFirst()
            }
            if !low.isEmpty {
                return low.removeFirst()
            }
            if closed { return nil }
            cond.wait()
        }
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }
}

final class CandidateVerifier: @unchecked Sendable {
    private let best: BestTracker
    private let submission: SubmissionManager?
    private let printLock: NSLock
    private let events: ExploreEventLog?
    private let stats: ExploreStats
    private let margin: AdaptiveMargin?
    private let scoreShift: AdaptiveScoreShift?
    private let marginLog = ThrottledAdjustmentLog(interval: 60.0)
    private let shiftLog = ThrottledAdjustmentLog(interval: 60.0)
    private let taskQueue: VerifyQueue
    private let workerGroup = DispatchGroup()
    private let workerCount: Int
    private let pending = DispatchGroup()
    private let seenLock = NSLock()
    private var seenSeeds = Set<UInt64>()
    private let maxPending: Int
    private let scorer: Scorer

    init(
        best: BestTracker,
        submission: SubmissionManager?,
        printLock: NSLock,
        events: ExploreEventLog?,
        stats: ExploreStats,
        margin: AdaptiveMargin? = nil,
        scoreShift: AdaptiveScoreShift? = nil,
        maxPending: Int = 512,
        workerCount: Int = 1
    ) {
        self.best = best
        self.submission = submission
        self.printLock = printLock
        self.events = events
        self.stats = stats
        self.margin = margin
        self.scoreShift = scoreShift
        self.maxPending = max(1, maxPending)
        self.taskQueue = VerifyQueue(capacity: self.maxPending)
        self.workerCount = max(1, workerCount)
        self.scorer = Scorer(size: 128)

        for _ in 0..<self.workerCount {
            workerGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { self.workerGroup.leave() }
                while let task = self.taskQueue.pop() {
                    self.process(task)
                }
            }
        }
    }

    func enqueue(seed: UInt64, source: String, mpsScore: Float? = nil, mpsScoreRaw: Float? = nil) {
        seenLock.lock()
        if seenSeeds.contains(seed) {
            seenLock.unlock()
            return
        }
        seenSeeds.insert(seed)
        seenLock.unlock()

        let priority: VerifyPriority = (source == "mps-sample") ? .sample : .candidate
        let task = VerifyTask(seed: seed, source: source, mpsScore: mpsScore, mpsScoreRaw: mpsScoreRaw, priority: priority)

        pending.enter()
        let result = taskQueue.push(task)
        if !result.enqueued {
            pending.leave()
            seenLock.lock()
            seenSeeds.remove(seed)
            seenLock.unlock()
            return
        }
        if let dropped = result.dropped {
            pending.leave()
            seenLock.lock()
            seenSeeds.remove(dropped.seed)
            seenLock.unlock()
        }
    }

    func wait() {
        taskQueue.close()
        pending.wait()
        workerGroup.wait()
    }

    private func process(_ task: VerifyTask) {
        defer { pending.leave() }

        let exact = scorer.score(seed: task.seed).totalScore
        stats.addCPUVerify(count: 1, scoreSum: exact, scoreSumSq: exact * exact)

        if best.updateIfBetter(seed: task.seed, score: exact, source: task.source) {
            let tag = " (\(task.source))"
            let msg = "New best score: \(String(format: "%.6f", exact)) seed: \(task.seed)\(tag)"
            if let events = events {
                events.append(.best, msg)
            } else {
                printLock.withLock { print(msg) }
            }
        }

        if let margin, let mpsScore = task.mpsScore {
            if let update = margin.recordSample(mpsScore: Double(mpsScore), cpuScore: exact) {
                let meta = String(format: "q=%.3f n=%d", update.quantile, update.sampleCount)
                if let summary = marginLog.record(oldValue: update.oldValue, newValue: update.newValue, target: update.target, meta: meta) {
                    let msg = "Adaptive mps-margin: \(summary)"
                    if let events {
                        events.append(.info, msg)
                    } else {
                        printLock.withLock { print(msg) }
                    }
                }
            }
        }
        if let scoreShift, let mpsScoreRaw = task.mpsScoreRaw {
            if let update = scoreShift.recordSample(mpsScore: Double(mpsScoreRaw), cpuScore: exact) {
                let meta = String(format: "meanΔ=%.6f n=%d", update.meanDelta, update.sampleCount)
                if let summary = shiftLog.record(oldValue: update.oldValue, newValue: update.newValue, target: update.target, meta: meta) {
                    let msg = "Adaptive mps-shift: \(summary)"
                    if let events {
                        events.append(.info, msg)
                    } else {
                        printLock.withLock { print(msg) }
                    }
                }
            }
        }

        submission?.maybeEnqueueSubmission(seed: task.seed, score: exact, source: task.source)
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
