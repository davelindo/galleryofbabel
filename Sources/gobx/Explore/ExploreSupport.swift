import Dispatch
import Foundation

public final class ExploreStats: @unchecked Sendable {
    public struct Snapshot {
        public let cpuCount: UInt64
        public let cpuScoreSum: Double
        public let cpuScoreSumSq: Double
        public let cpuVerifyCount: UInt64
        public let cpuVerifyScoreSum: Double
        public let cpuVerifyScoreSumSq: Double
        public let mpsCount: UInt64
        public let mpsScoreSum: Double
        public let mpsScoreSumSq: Double
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

    public func snapshot() -> Snapshot {
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

public final class BestTracker: @unchecked Sendable {
    public struct Snapshot {
        public let seed: UInt64
        public let score: Double
        public let source: String?
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

    public func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(seed: bestSeed, score: bestScore, source: bestSource)
        lock.unlock()
        return s
    }
}

public final class AdaptiveMargin: @unchecked Sendable {
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
    private var trend: Int = 0

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

    public func current() -> Double {
        lock.lock()
        let v = margin
        lock.unlock()
        return v
    }

    public func trendSymbol() -> String {
        lock.lock()
        let t = trend
        lock.unlock()
        if t > 0 { return "^" }
        if t < 0 { return "v" }
        return "-"
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
        let shiftDelta = next - old
        if shiftDelta > 0 { trend = 1 }
        else if shiftDelta < 0 { trend = -1 }
        else { trend = 0 }
        margin = next
        let update = Update(oldValue: old, newValue: next, target: target, sampleCount: samples.count, quantile: quantile)
        lock.unlock()
        return update
    }
}

public final class ApproxBestTracker: @unchecked Sendable {
    public struct Snapshot {
        public let seed: UInt64
        public let score: Float
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

    public func snapshot() -> Snapshot {
        lock.lock()
        let s = Snapshot(seed: bestSeed, score: bestScore)
        lock.unlock()
        return s
    }
}

public final class SubmissionState: @unchecked Sendable {
    public struct Snapshot {
        public let top500Threshold: Double
        public let top500UniqueThreshold: Double
        public let top500AllThreshold: Double
        public let lastRefresh: Date
        public let lastRefreshAll: Date
        public let knownCount: Int
        public let topBestScore: Double?
        public let topBestSeed: UInt64?
        public let topBestAllScore: Double?
        public let topBestAllSeed: UInt64?
        public let personalBestScore: Double?
        public let personalBestSeed: UInt64?
        public let personalBestRank: Int?
    }

    private let lock = NSLock()
    private let profileId: String?
    private var topSeeds = Set<UInt64>()
    private var acceptedSeeds = Set<UInt64>()
    private var acceptedOrder: [UInt64] = []
    private let acceptedCap: Int = 4096
    private var topScores: [Double] = []
    private var top500Threshold: Double = -Double.infinity
    private var top500UniqueThreshold: Double = -Double.infinity
    private var top500AllThreshold: Double = -Double.infinity
    private var lastRefresh: Date = .distantPast
    private var lastRefreshAll: Date = .distantPast
    private var topBestScore: Double? = nil
    private var topBestSeed: UInt64? = nil
    private var topBestAllScore: Double? = nil
    private var topBestAllSeed: UInt64? = nil
    private var personalBestScore: Double? = nil
    private var personalBestSeed: UInt64? = nil
    private var personalBestRank: Int? = nil

    init(profileId: String? = nil) {
        self.profileId = profileId
    }

    func mergeTop(_ top: TopResponse, uniqueUsers: Bool, isPrimary: Bool) {
        let scores = top.images.map { $0.score }
        let sortedScores = scores.sorted(by: >)
        let threshold = sortedScores.last ?? -Double.infinity
        let best = top.images.max(by: { $0.score < $1.score })
        let now = Date()

        lock.lock()
        if uniqueUsers {
            top500UniqueThreshold = threshold
        } else {
            top500AllThreshold = threshold
            topBestAllScore = best?.score
            topBestAllSeed = best?.seed
            lastRefreshAll = now
        }

        if isPrimary {
            topScores = sortedScores
            topSeeds.removeAll(keepingCapacity: true)
            topSeeds.reserveCapacity(top.images.count)
            for img in top.images { topSeeds.insert(img.seed) }
            topBestScore = best?.score
            topBestSeed = best?.seed
            if let profileId, !profileId.isEmpty {
                if let personal = top.images.filter({ $0.discovererId == profileId }).max(by: { $0.score < $1.score }) {
                    personalBestScore = personal.score
                    personalBestSeed = personal.seed
                    if let rank = personal.rank {
                        personalBestRank = rank
                    } else {
                        let sorted = top.images.sorted {
                            if $0.score == $1.score {
                                return ($0.rank ?? Int.max) < ($1.rank ?? Int.max)
                            }
                            return $0.score > $1.score
                        }
                        if let idx = sorted.firstIndex(where: { $0.seed == personal.seed }) {
                            personalBestRank = idx + 1
                        } else {
                            personalBestRank = nil
                        }
                    }
                } else {
                    personalBestScore = nil
                    personalBestSeed = nil
                    personalBestRank = nil
                }
            } else {
                personalBestScore = nil
                personalBestSeed = nil
                personalBestRank = nil
            }
            if let last = topScores.last {
                top500Threshold = last
            }
            lastRefresh = now
        }
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
        if topSeeds.contains(seed) || acceptedSeeds.contains(seed) { return false }
        return true
    }

    func isKnown(seed: UInt64) -> Bool {
        lock.lock()
        let known = topSeeds.contains(seed) || acceptedSeeds.contains(seed)
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
        if !acceptedSeeds.contains(seed) {
            acceptedSeeds.insert(seed)
            acceptedOrder.append(seed)
            if acceptedOrder.count > acceptedCap {
                let dropCount = acceptedOrder.count - acceptedCap
                for i in 0..<dropCount {
                    acceptedSeeds.remove(acceptedOrder[i])
                }
                acceptedOrder.removeFirst(dropCount)
            }
        }
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        var knownCount = topSeeds.count
        if !acceptedSeeds.isEmpty {
            for seed in acceptedSeeds where !topSeeds.contains(seed) {
                knownCount += 1
            }
        }
        let s = Snapshot(
            top500Threshold: top500Threshold,
            top500UniqueThreshold: top500UniqueThreshold,
            top500AllThreshold: top500AllThreshold,
            lastRefresh: lastRefresh,
            lastRefreshAll: lastRefreshAll,
            knownCount: knownCount,
            topBestScore: topBestScore,
            topBestSeed: topBestSeed,
            topBestAllScore: topBestAllScore,
            topBestAllSeed: topBestAllSeed,
            personalBestScore: personalBestScore,
            personalBestSeed: personalBestSeed,
            personalBestRank: personalBestRank
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

public enum SubmissionLogKind: String, Sendable {
    case accepted
    case rejected
    case rateLimited
    case failed
}

public struct SubmissionLogEntry: Sendable {
    public let time: Date
    public let kind: SubmissionLogKind
    public let seed: UInt64
    public let score: Double
    public let rank: Int?
    public let difficultyPercentile: Double?
    public let message: String?
    public let source: String?
}

final class SubmissionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SubmissionLogEntry] = []
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = max(100, capacity)
        entries.reserveCapacity(min(self.capacity, 4096))
    }

    func append(_ entry: SubmissionLogEntry) {
        lock.withLock {
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    func count() -> Int {
        lock.withLock { entries.count }
    }

    func snapshot(from start: Int, limit: Int) -> [SubmissionLogEntry] {
        lock.withLock {
            let clampedStart = max(0, min(start, entries.count))
            let clampedEnd = min(entries.count, clampedStart + max(0, limit))
            guard clampedStart < clampedEnd else { return [] }
            return Array(entries[clampedStart..<clampedEnd])
        }
    }
}

public final class SubmissionManager: @unchecked Sendable {
    public struct AcceptedSeed: Sendable {
        public let time: Date
        public let seed: UInt64
        public let score: Double
        public let difficultyPercentile: Double?
        public let rank: Int?
        public let source: String?
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

    public struct StatsSnapshot: Sendable {
        public let submitAttempts: UInt64
        public let acceptedCount: UInt64
        public let rejectedCount: UInt64
        public let rateLimitedCount: UInt64
        public let failedCount: UInt64
        public let queuedCount: Int
        public let queuedMinScore: Double?
        public let queuedMaxScore: Double?
    }

    private let config: AppConfig
    private let state: SubmissionState
    private let userMinScore: Double
    private let topUniqueUsers: Bool
    private let printLock: NSLock
    private let logTimestamps: Bool
    private let events: ExploreEventLog?
    private let queue = DispatchQueue(label: "gobx.submit", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let pending = DispatchGroup()
    private let limiter = SubmissionRateLimiter(optimistic: true)
    private let maxRetries = 8
    private let retryBaseSec: TimeInterval = 1.0
    private let retryMaxSec: TimeInterval = 30.0
    private let retryJitter: Double = 0.2
    private let refreshBaseSec: TimeInterval = 5.0
    private let refreshMaxSec: TimeInterval = 300.0
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
    private let submissionLog = SubmissionLog(capacity: 2000)
    private var lastRateLimitSeed: UInt64? = nil
    private var lastRateLimitMessage: String? = nil
    private var refreshInFlight = false
    private var refreshFailures = 0
    private var refreshBackoffUntil: TimeInterval = 0.0
    private var refreshAltInFlight = false
    private var refreshAltFailures = 0
    private var refreshAltBackoffUntil: TimeInterval = 0.0

    init(
        config: AppConfig,
        state: SubmissionState,
        userMinScore: Double,
        topUniqueUsers: Bool,
        printLock: NSLock,
        logTimestamps: Bool,
        events: ExploreEventLog?
    ) {
        self.config = config
        self.state = state
        self.userMinScore = userMinScore
        self.topUniqueUsers = topUniqueUsers
        self.printLock = printLock
        self.logTimestamps = logTimestamps
        self.events = events
        queue.setSpecific(key: queueKey, value: 1)
        submitQueue.reserveCapacity(64)
        maybeLoadSubmissionJournal()
    }

    private func emit(_ kind: ExploreEventKind, _ message: String) {
        if let events {
            events.append(kind, message)
        } else {
            printLock.withLock { print(formatLogLine(message, includeTimestamp: logTimestamps)) }
        }
    }

    private func emitRateLimit(seed: UInt64, tag: String, delay: TimeInterval) {
        let delayStr = String(format: "%.1f", delay)
        let message = "Rate limited submitting seed=\(seed)\(tag), backing off \(delayStr)s"
        if let events {
            if lastRateLimitSeed == seed, let lastMessage = lastRateLimitMessage {
                let updated = "\(lastMessage), \(delayStr)s"
                if events.updateLast(kind: .warning, from: lastMessage, to: updated) {
                    lastRateLimitMessage = updated
                    return
                }
            }
            events.append(.warning, message)
            lastRateLimitSeed = seed
            lastRateLimitMessage = message
        } else {
            emit(.warning, message)
            lastRateLimitSeed = seed
            lastRateLimitMessage = nil
        }
    }

    private func recordSubmissionLog(
        kind: SubmissionLogKind,
        seed: UInt64,
        score: Double,
        rank: Int?,
        percentile: Double?,
        message: String?,
        source: String?
    ) {
        let entry = SubmissionLogEntry(
            time: Date(),
            kind: kind,
            seed: seed,
            score: score,
            rank: rank,
            difficultyPercentile: percentile,
            message: message,
            source: source
        )
        submissionLog.append(entry)
    }

    private func retryDelay(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        let raw = retryBaseSec * pow(2.0, Double(step - 1))
        let delay = min(retryMaxSec, raw)
        let jitter = delay * retryJitter * Double.random(in: -1.0...1.0)
        return max(0.0, delay + jitter)
    }

    private func refreshDelay(attempt: Int) -> TimeInterval {
        let step = max(1, attempt)
        let raw = refreshBaseSec * pow(2.0, Double(step - 1))
        return min(refreshMaxSec, raw)
    }

    public func effectiveThreshold() -> Double {
        state.effectiveThreshold(userMinScore: userMinScore)
    }

    public func stateSnapshot() -> SubmissionState.Snapshot {
        state.snapshot()
    }

    func acceptedSnapshot(limit: Int) -> [AcceptedSeed] {
        acceptedLock.lock()
        let n = min(max(0, limit), accepted.count)
        let out = n == 0 ? [] : Array(accepted.suffix(n).reversed())
        acceptedLock.unlock()
        return out
    }

    public func acceptedBestSnapshot(limit: Int) -> [AcceptedSeed] {
        acceptedLock.lock()
        let n = min(max(0, limit), acceptedBest.count)
        let out = n == 0 ? [] : Array(acceptedBest.prefix(n))
        acceptedLock.unlock()
        return out
    }

    public func submissionLogCount() -> Int {
        submissionLog.count()
    }

    public func submissionLogSnapshot(from start: Int, limit: Int) -> [SubmissionLogEntry] {
        submissionLog.snapshot(from: start, limit: limit)
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

    public func statsSnapshot() -> StatsSnapshot {
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
            let now = Date().timeIntervalSinceReferenceDate
            guard !self.refreshInFlight else { return }
            guard self.refreshBackoffUntil <= now else { return }
            self.refreshInFlight = true
            let reasonNote = reason.map { " (\($0))" } ?? ""
            let primaryUnique = self.topUniqueUsers
            Task {
                let top = await fetchTop(limit: limit, config: self.config, uniqueUsers: primaryUnique)
                self.queue.async {
                    self.refreshInFlight = false
                    if let top {
                        self.refreshFailures = 0
                        self.refreshBackoffUntil = 0.0
                        self.state.mergeTop(top, uniqueUsers: primaryUnique, isPrimary: true)
                        self.maybeLoadSubmissionJournal()
                        let snap = self.state.snapshot()
                        let threshold = max(self.userMinScore, snap.top500Threshold)
                        self.pruneQueueLocked(threshold: threshold)
                        self.emit(.info, "Refreshed top \(limit) threshold=\(String(format: "%.6f", snap.top500Threshold)) known=\(snap.knownCount)\(reasonNote)")
                    } else {
                        self.refreshFailures += 1
                        let delay = self.refreshDelay(attempt: self.refreshFailures)
                        let delayStr = String(format: "%.1f", delay)
                        self.refreshBackoffUntil = Date().timeIntervalSinceReferenceDate + delay
                        self.emit(.warning, "Warning: failed to refresh top \(limit)\(reasonNote); retrying in \(delayStr)s")
                    }
                }
            }

            let altNow = Date().timeIntervalSinceReferenceDate
            guard !self.refreshAltInFlight else { return }
            guard self.refreshAltBackoffUntil <= altNow else { return }
            self.refreshAltInFlight = true
            let altUnique = !primaryUnique
            let altLabel = altUnique ? "unique" : "all"
            Task {
                let top = await fetchTop(limit: limit, config: self.config, uniqueUsers: altUnique)
                self.queue.async {
                    self.refreshAltInFlight = false
                    if let top {
                        self.refreshAltFailures = 0
                        self.refreshAltBackoffUntil = 0.0
                        self.state.mergeTop(top, uniqueUsers: altUnique, isPrimary: false)
                    } else {
                        self.refreshAltFailures += 1
                        let delay = self.refreshDelay(attempt: self.refreshAltFailures)
                        let delayStr = String(format: "%.1f", delay)
                        self.refreshAltBackoffUntil = Date().timeIntervalSinceReferenceDate + delay
                        self.emit(.warning, "Warning: failed to refresh top \(limit) (\(altLabel))\(reasonNote); retrying in \(delayStr)s")
                    }
                }
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

    func waitForPendingSubmissions(stop: StopFlag? = nil, timeoutSec: Double? = nil) -> Bool {
        let interval: TimeInterval = 0.25
        let deadline = timeoutSec.map { Date().addingTimeInterval(max(0.0, $0)) }
        while true {
            if let stop, stop.isStopRequested() {
                return false
            }
            let result = pending.wait(timeout: .now() + interval)
            if result == .success {
                return true
            }
            if let deadline, Date() >= deadline {
                return false
            }
        }
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
                    recordSubmissionLog(kind: .failed, seed: task.seed, score: task.score, rank: nil, percentile: nil, message: "max retries", source: task.source)
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
                if events == nil {
                    let pctStr = percentile.map { String(format: " p=%.2f%%", $0 * 100.0) } ?? ""
                    let msg = "Accepted seed=\(task.seed) score=\(String(format: "%.6f", task.score)) rank=\(res.rank ?? 0)\(pctStr)\(tag)"
                    printLock.withLock { print(formatLogLine(msg, includeTimestamp: logTimestamps)) }
                }
                recordSubmissionLog(kind: .accepted, seed: task.seed, score: task.score, rank: res.rank, percentile: percentile, message: nil, source: task.source)
                return .completed
            }

            if res.isRateLimited {
                recordRateLimited()
                let delay = await limiter.recordRateLimit()
                emitRateLimit(seed: task.seed, tag: tag, delay: delay)
                let delayStr = String(format: "%.1f", delay)
                recordSubmissionLog(kind: .rateLimited, seed: task.seed, score: task.score, rank: nil, percentile: nil, message: "backoff \(delayStr)s", source: task.source)
                return .requeue(delay: delay)
            }

            if res.isRetryableServerError {
                attempts += 1
                if attempts > maxRetries {
                    emit(.error, "Submission failed for \(task.seed)\(tag) (\(res.message ?? "unknown"))")
                    recordFailed()
                    recordSubmissionLog(kind: .failed, seed: task.seed, score: task.score, rank: nil, percentile: nil, message: res.message ?? "unknown", source: task.source)
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
            recordSubmissionLog(kind: .rejected, seed: task.seed, score: task.score, rank: res.rank, percentile: nil, message: res.message ?? "unknown", source: task.source)
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

public final class AdaptiveScoreShift: @unchecked Sendable {
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
    private var trend: Int = 0

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

    public func current() -> Double {
        lock.lock()
        let v = shift
        lock.unlock()
        return v
    }

    public func trendSymbol() -> String {
        lock.lock()
        let t = trend
        lock.unlock()
        if t > 0 { return "^" }
        if t < 0 { return "v" }
        return "-"
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
        let shiftDelta = next - old
        if shiftDelta > 0 { trend = 1 }
        else if shiftDelta < 0 { trend = -1 }
        else { trend = 0 }
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
        let trend: String
        if net > 0 {
            trend = "^"
        } else if net < 0 {
            trend = "v"
        } else {
            trend = "-"
        }
        let msg = String(format: "%@ %.6f", trend, lastValue)
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
    private let logTimestamps: Bool
    private let events: ExploreEventLog?
    private let stats: ExploreStats
    private let margin: AdaptiveMargin?
    private let scoreShift: AdaptiveScoreShift?
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
        logTimestamps: Bool,
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
        self.logTimestamps = logTimestamps
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

    func wait(stop: StopFlag? = nil, timeoutSec: Double? = nil) -> Bool {
        taskQueue.close()
        let interval: TimeInterval = 0.25
        let deadline = timeoutSec.map { Date().addingTimeInterval(max(0.0, $0)) }
        while true {
            if let stop, stop.isStopRequested() {
                return false
            }
            let result = pending.wait(timeout: .now() + interval)
            if result == .success {
                break
            }
            if let deadline, Date() >= deadline {
                return false
            }
        }
        while true {
            if let stop, stop.isStopRequested() {
                return false
            }
            let result = workerGroup.wait(timeout: .now() + interval)
            if result == .success {
                return true
            }
            if let deadline, Date() >= deadline {
                return false
            }
        }
    }

    private func process(_ task: VerifyTask) {
        defer {
            pending.leave()
            _ = seenLock.withLock { seenSeeds.remove(task.seed) }
        }

        let exact = scorer.score(seed: task.seed).totalScore
        stats.addCPUVerify(count: 1, scoreSum: exact, scoreSumSq: exact * exact)

        if best.updateIfBetter(seed: task.seed, score: exact, source: task.source) {
            let tag = " (\(task.source))"
            let msg = "New best score: \(String(format: "%.6f", exact)) seed: \(task.seed)\(tag)"
            if let events = events {
                events.append(.best, msg)
            } else {
                printLock.withLock { print(formatLogLine(msg, includeTimestamp: logTimestamps)) }
            }
        }

        if let margin, let mpsScore = task.mpsScore {
            _ = margin.recordSample(mpsScore: Double(mpsScore), cpuScore: exact)
        }
        if let scoreShift, let mpsScoreRaw = task.mpsScoreRaw {
            _ = scoreShift.recordSample(mpsScore: Double(mpsScoreRaw), cpuScore: exact)
        }

        submission?.maybeEnqueueSubmission(seed: task.seed, score: exact, source: task.source)
    }
}

public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false

    public func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        stopRequested = false
        lock.unlock()
    }

    public func isStopRequested() -> Bool {
        lock.lock()
        let v = stopRequested
        lock.unlock()
        return v
    }
}

public final class PauseFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false

    public init() {}

    public func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        if !paused {
            condition.broadcast()
        }
        condition.unlock()
    }

    public func isPaused() -> Bool {
        condition.lock()
        let v = paused
        condition.unlock()
        return v
    }

    public func waitIfPaused(stop: StopFlag? = nil) -> Bool {
        condition.lock()
        while paused {
            if let stop, stop.isStopRequested() {
                condition.unlock()
                return false
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        condition.unlock()
        return true
    }
}
