import Foundation

public struct ExploreUIContext {
    public let backend: Backend
    public let endless: Bool
    public let totalTarget: Int?
    public let mpsVerifyMargin: AdaptiveMargin
    public let mpsScoreShift: AdaptiveScoreShift
    public let minScore: Double
    public let gpuThroughput: GPUThroughputLimiter
}

public final class ExploreUIBridge: @unchecked Sendable {
    public let stats: ExploreStats
    public let best: BestTracker
    public let bestApprox: ApproxBestTracker
    public let events: ExploreEventLog
    private var stopValue: StopFlag
    public let pause: PauseFlag

    private let lock = NSLock()
    private var contextValue: ExploreUIContext? = nil
    private var submissionValue: SubmissionManager? = nil

    public init(eventCapacity: Int = 2000) {
        self.stats = ExploreStats()
        self.best = BestTracker()
        self.bestApprox = ApproxBestTracker()
        self.events = ExploreEventLog(capacity: eventCapacity)
        self.stopValue = StopFlag()
        self.pause = PauseFlag()
    }

    public var stop: StopFlag {
        lock.withLock { stopValue }
    }

    public func resetStop() {
        lock.withLock {
            stopValue = StopFlag()
        }
    }

    func setContext(_ context: ExploreUIContext) {
        lock.withLock { contextValue = context }
    }

    public func context() -> ExploreUIContext? {
        lock.withLock { contextValue }
    }

    func setSubmission(_ submission: SubmissionManager?) {
        lock.withLock { submissionValue = submission }
    }

    public func submission() -> SubmissionManager? {
        lock.withLock { submissionValue }
    }
}
