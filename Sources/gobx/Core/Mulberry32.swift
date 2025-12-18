import Foundation

struct Mulberry32 {
    private var state: UInt32
    private let hiMix: UInt32

    init(seed: UInt64) {
        let seedLo = UInt32(truncatingIfNeeded: seed)
        let seedHi = UInt32(truncatingIfNeeded: seed >> 32)
        self.hiMix = seedHi &* 0x9E3779B9
        self.state = seedLo
    }

    mutating func nextFloat01() -> Float {
        state &+= 0x6D2B79F5
        var t = state ^ hiMix
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        let out = t ^ (t >> 14)
        return Float(out) * (1.0 / 4294967296.0)
    }
}

