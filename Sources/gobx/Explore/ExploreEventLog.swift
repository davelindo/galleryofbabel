import Foundation

public enum ExploreEventKind: String, Sendable {
    case info
    case warning
    case best
    case accepted
    case rejected
    case error
}

public struct ExploreEvent: Sendable {
    public let time: Date
    public let kind: ExploreEventKind
    public let message: String
}

public final class ExploreEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExploreEvent] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = max(10, capacity)
        events.reserveCapacity(min(self.capacity, 512))
    }

    public func append(_ kind: ExploreEventKind, _ message: String) {
        lock.withLock {
            events.append(ExploreEvent(time: Date(), kind: kind, message: message))
            if events.count > capacity {
                events.removeFirst(events.count - capacity)
            }
        }
    }

    public func updateLast(kind: ExploreEventKind, from oldMessage: String, to newMessage: String) -> Bool {
        lock.withLock {
            guard let last = events.last, last.kind == kind, last.message == oldMessage else { return false }
            events[events.count - 1] = ExploreEvent(time: last.time, kind: kind, message: newMessage)
            return true
        }
    }

    public func snapshot(limit: Int) -> [ExploreEvent] {
        lock.withLock {
            let n = min(Swift.max(0, limit), events.count)
            return n == 0 ? [] : Array(events.suffix(n))
        }
    }

    public func count() -> Int {
        lock.withLock { events.count }
    }

    public func snapshot(from start: Int, limit: Int) -> [ExploreEvent] {
        lock.withLock {
            let clampedStart = max(0, min(start, events.count))
            let clampedEnd = min(events.count, clampedStart + max(0, limit))
            guard clampedStart < clampedEnd else { return [] }
            return Array(events[clampedStart..<clampedEnd])
        }
    }
}
