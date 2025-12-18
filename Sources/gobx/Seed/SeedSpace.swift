import Foundation

enum V2SeedSpace {
    static let min: UInt64 = 0x100000000 // 2^32
    static let maxExclusive: UInt64 = 0x20000000000000 // 2^53
    static let size: UInt64 = maxExclusive &- min
}

func makeSelftestSeeds(count: Int) -> [UInt64] {
    let n = max(1, count)
    var seeds = [UInt64]()
    seeds.reserveCapacity(n)

    if n >= 1 { seeds.append(V2SeedSpace.min) }
    if n >= 2 { seeds.append(V2SeedSpace.min &+ 1) }
    if n >= 3 { seeds.append(V2SeedSpace.maxExclusive &- 1) }

    var x: UInt64 = 0xD1B54A32D192ED03
    let step: UInt64 = 0x9E3779B97F4A7C15
    while seeds.count < n {
        x &+= step
        seeds.append(V2SeedSpace.min &+ (x % V2SeedSpace.size))
    }
    return seeds
}

func normalizeV2Seed(_ seed: UInt64) -> UInt64 {
    if seed < V2SeedSpace.min { return V2SeedSpace.min }
    if seed >= V2SeedSpace.maxExclusive { return V2SeedSpace.min }
    return seed
}

func nextV2Seed(_ seed: UInt64, by step: UInt64 = 1) -> UInt64 {
    let next = seed &+ step
    if next >= V2SeedSpace.maxExclusive { return V2SeedSpace.min }
    if next < V2SeedSpace.min { return V2SeedSpace.min }
    return next
}

@inline(__always)
func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    var x = a
    var y = b
    while y != 0 {
        let r = x % y
        x = y
        y = r
    }
    return x
}

@inline(__always)
private func mulMod(_ a: UInt64, _ b: UInt64, mod: UInt64) -> UInt64 {
    let full = a.multipliedFullWidth(by: b)
    let qr = mod.dividingFullWidth(full)
    return qr.remainder
}

func chooseCoprimeStep(spaceSize: UInt64) -> UInt64 {
    precondition(spaceSize > 0)
    var s = UInt64(0x9E3779B97F4A7C15) % spaceSize
    if s == 0 { s = 1 }
    if (s & 1) == 0 { s &+= 1 }
    while gcd(s, spaceSize) != 1 {
        s &+= 2
        if s >= spaceSize { s = 1 }
    }
    return s
}

enum SeedMode: String {
    case stride
    case state
}

struct SeedExploreState: Codable {
    var version: Int = 1
    var startOffset: UInt64
    var step: UInt64
    var nextIndex: UInt64
    var updatedAt: Date
}

func defaultSeedStateURL() -> URL {
    GobxPaths.seedStateURL
}

func loadSeedState(from url: URL) -> SeedExploreState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SeedExploreState.self, from: data)
}

func saveSeedState(_ state: SeedExploreState, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(state)
    try data.write(to: url, options: [.atomic])
}

final class SeedRangeAllocator: @unchecked Sendable {
    struct Claim {
        let offset: UInt64
        let count: Int
    }

    private let lock = NSLock()
    private let spaceSize: UInt64
    private let startOffset: UInt64
    private let step: UInt64
    private var nextIndex: UInt64
    private var lastSavedNextIndex: UInt64
    private var remainingTotal: Int?

    init(state: SeedExploreState, totalTarget: Int?) {
        self.spaceSize = V2SeedSpace.size
        self.startOffset = state.startOffset % V2SeedSpace.size
        self.step = state.step % V2SeedSpace.size
        self.nextIndex = state.nextIndex % V2SeedSpace.size
        self.lastSavedNextIndex = self.nextIndex
        self.remainingTotal = totalTarget
    }

    var stepValue: UInt64 { step }
    var spaceSizeValue: UInt64 { spaceSize }

    func claim(maxCount: Int) -> Claim? {
        guard maxCount > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let rem = remainingTotal, rem <= 0 { return nil }
        let n = remainingTotal.map { min($0, maxCount) } ?? maxCount
        if n <= 0 { return nil }

        let indexStart = nextIndex
        nextIndex &+= UInt64(n)
        if nextIndex >= spaceSize { nextIndex %= spaceSize }
        if let rem = remainingTotal { remainingTotal = rem - n }

        let mul = mulMod(indexStart, step, mod: spaceSize)
        var offset = startOffset + mul
        if offset >= spaceSize { offset -= spaceSize }
        return Claim(offset: offset, count: n)
    }

    func snapshotForSave() -> SeedExploreState? {
        lock.lock()
        let idx = nextIndex
        let should = idx != lastSavedNextIndex
        lock.unlock()
        guard should else { return nil }
        return SeedExploreState(startOffset: startOffset, step: step, nextIndex: idx, updatedAt: Date())
    }

    func markSaved(nextIndex: UInt64) {
        lock.lock()
        if nextIndex == self.nextIndex || nextIndex > lastSavedNextIndex {
            lastSavedNextIndex = nextIndex
        } else {
            lastSavedNextIndex = self.nextIndex
        }
        lock.unlock()
    }
}
