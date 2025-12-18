import Dispatch
import Foundation

struct TopApproxEntry: Comparable {
    let seed: UInt64
    let score: Float

    static func < (lhs: TopApproxEntry, rhs: TopApproxEntry) -> Bool {
        lhs.score < rhs.score
    }
}

final class TopApproxTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var entries: [TopApproxEntry] = []

    init(limit: Int) {
        self.limit = max(0, limit)
        entries.reserveCapacity(max(0, limit))
    }

    func update(seed: UInt64, score: Float) {
        guard limit > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries.count < limit {
            entries.append(TopApproxEntry(seed: seed, score: score))
            entries.sort(by: >)
            return
        }
        if let worst = entries.last, score > worst.score {
            entries[limit - 1] = TopApproxEntry(seed: seed, score: score)
            entries.sort(by: >)
        }
    }

    func snapshot() -> [TopApproxEntry] {
        lock.lock()
        let out = entries
        lock.unlock()
        return out
    }
}

final class SeedQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [UInt64] = []
    private var head: Int = 0
    private var closed = false
    private let available = DispatchSemaphore(value: 0)

    func pushMany(_ seeds: [UInt64]) {
        guard !seeds.isEmpty else { return }
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        buf.append(contentsOf: seeds)
        lock.unlock()
        for _ in seeds { available.signal() }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        available.signal()
    }

    // Returns:
    // - nil when closed and empty (done)
    // - [] on timeout (no data yet)
    // - [seeds] with 1..max items
    func popBatch(max: Int, timeout: DispatchTime) -> [UInt64]? {
        precondition(max > 0)
        if available.wait(timeout: timeout) == .timedOut {
            return []
        }

        lock.lock()
        let availableCount = buf.count - head
        if availableCount <= 0 {
            let done = closed
            lock.unlock()
            return done ? nil : []
        }
        let take = min(max, availableCount)
        let out = Array(buf[head..<(head + take)])
        head += take
        if head >= 4096 && head * 2 >= buf.count {
            buf.removeFirst(head)
            head = 0
        }
        lock.unlock()

        if take > 1 {
            for _ in 1..<take { _ = available.wait(timeout: .now()) }
        }
        return out
    }
}

