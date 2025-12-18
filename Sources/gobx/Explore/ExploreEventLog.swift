import Foundation

enum ExploreEventKind: String, Sendable {
    case info
    case warning
    case best
    case accepted
    case rejected
    case error
}

struct ExploreEvent: Sendable {
    let time: Date
    let kind: ExploreEventKind
    let message: String
}

final class ExploreEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExploreEvent] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = max(10, capacity)
        events.reserveCapacity(min(self.capacity, 512))
    }

    func append(_ kind: ExploreEventKind, _ message: String) {
        lock.withLock {
            events.append(ExploreEvent(time: Date(), kind: kind, message: message))
            if events.count > capacity {
                events.removeFirst(events.count - capacity)
            }
        }
    }

    func snapshot(limit: Int) -> [ExploreEvent] {
        lock.withLock {
            let n = min(Swift.max(0, limit), events.count)
            return n == 0 ? [] : Array(events.suffix(n))
        }
    }
}
