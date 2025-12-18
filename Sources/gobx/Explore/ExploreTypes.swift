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
    private let cond = NSCondition()
    private var buf: [UInt64] = []
    private var head: Int = 0
    private var closed = false

    func pushMany(_ seeds: [UInt64]) {
        guard !seeds.isEmpty else { return }
        cond.lock()
        if closed {
            cond.unlock()
            return
        }
        buf.append(contentsOf: seeds)
        cond.broadcast()
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    // Returns:
    // - nil when closed and empty (done)
    // - [] on timeout (no data yet)
    // - [seeds] with 1..max items
    func popBatch(max: Int, timeout: DispatchTime) -> [UInt64]? {
        precondition(max > 0)
        cond.lock()
        while true {
            let availableCount = buf.count - head
            if availableCount > 0 {
                let take = min(max, availableCount)
                let out = Array(buf[head..<(head + take)])
                head += take
                if head >= 4096 && head * 2 >= buf.count {
                    buf.removeFirst(head)
                    head = 0
                }
                cond.unlock()
                return out
            }

            if closed {
                cond.unlock()
                return nil
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let deadlineNs = timeout.uptimeNanoseconds
            if deadlineNs <= nowNs {
                cond.unlock()
                return []
            }
            let dt = Double(deadlineNs - nowNs) / 1e9
            let deadline = Date(timeIntervalSinceNow: dt)
            if !cond.wait(until: deadline) {
                cond.unlock()
                return []
            }
        }
    }
}
