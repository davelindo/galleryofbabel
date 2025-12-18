struct SeedScoreEntry: Comparable {
    let score: Float
    let seed: UInt64

    static func < (lhs: SeedScoreEntry, rhs: SeedScoreEntry) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.seed < rhs.seed
    }
}

struct MinHeap<Element: Comparable> {
    private(set) var items: [Element] = []

    var count: Int { items.count }
    var min: Element? { items.first }

    mutating func reserveCapacity(_ n: Int) {
        items.reserveCapacity(n)
    }

    mutating func push(_ x: Element) {
        items.append(x)
        siftUp(from: items.count - 1)
    }

    mutating func replaceMin(with x: Element) {
        guard !items.isEmpty else { return }
        items[0] = x
        siftDown(from: 0)
    }

    mutating func keepLargest(_ x: Element, limit: Int) {
        guard limit > 0 else { return }
        if items.count < limit {
            push(x)
            return
        }
        guard let m = items.first, x > m else { return }
        replaceMin(with: x)
    }

    mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if items[parent] <= items[child] { break }
            items.swapAt(parent, child)
            child = parent
        }
    }

    mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            if left >= items.count { break }
            let right = left + 1
            var smallest = left
            if right < items.count, items[right] < items[left] {
                smallest = right
            }
            if items[parent] <= items[smallest] { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

