import Foundation

struct ProxyConfig: Codable, Equatable {
    enum Normalization: String, Codable {
        case meanCentered
        case zeroCentered
    }

    let maxLevels: Int?
    let normalization: Normalization
    let useFloatAccumulation: Bool
    let includeNeighborPenalty: Bool
    let quantizeLowpassToHalf: Bool
    let includeNeighborCorrFeature: Bool

    private enum CodingKeys: String, CodingKey {
        case maxLevels
        case normalization
        case useFloatAccumulation
        case includeNeighborPenalty
        case quantizeLowpassToHalf
        case includeNeighborCorrFeature
    }

    init(
        maxLevels: Int?,
        normalization: Normalization,
        useFloatAccumulation: Bool,
        includeNeighborPenalty: Bool,
        quantizeLowpassToHalf: Bool,
        includeNeighborCorrFeature: Bool
    ) {
        self.maxLevels = maxLevels
        self.normalization = normalization
        self.useFloatAccumulation = useFloatAccumulation
        self.includeNeighborPenalty = includeNeighborPenalty
        self.quantizeLowpassToHalf = quantizeLowpassToHalf
        self.includeNeighborCorrFeature = includeNeighborCorrFeature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxLevels = try container.decodeIfPresent(Int.self, forKey: .maxLevels)
        normalization = try container.decodeIfPresent(Normalization.self, forKey: .normalization) ?? .meanCentered
        useFloatAccumulation = try container.decodeIfPresent(Bool.self, forKey: .useFloatAccumulation) ?? false
        includeNeighborPenalty = try container.decodeIfPresent(Bool.self, forKey: .includeNeighborPenalty) ?? true
        quantizeLowpassToHalf = try container.decodeIfPresent(Bool.self, forKey: .quantizeLowpassToHalf) ?? false
        includeNeighborCorrFeature = try container.decodeIfPresent(Bool.self, forKey: .includeNeighborCorrFeature) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(maxLevels, forKey: .maxLevels)
        try container.encode(normalization, forKey: .normalization)
        try container.encode(useFloatAccumulation, forKey: .useFloatAccumulation)
        try container.encode(includeNeighborPenalty, forKey: .includeNeighborPenalty)
        try container.encode(quantizeLowpassToHalf, forKey: .quantizeLowpassToHalf)
        try container.encode(includeNeighborCorrFeature, forKey: .includeNeighborCorrFeature)
    }

    static func legacyDefault(imageSize: Int) -> ProxyConfig {
        ProxyConfig(
            maxLevels: nil,
            normalization: .meanCentered,
            useFloatAccumulation: false,
            includeNeighborPenalty: true,
            quantizeLowpassToHalf: false,
            includeNeighborCorrFeature: false
        )
    }

    static func mpsDefault(imageSize: Int) -> ProxyConfig {
        legacyDefault(imageSize: imageSize)
    }

    static func metalDefault(imageSize: Int) -> ProxyConfig {
        let full = WaveletProxy.levelCount(for: imageSize)
        let maxLevels = min(full, 5)
        return ProxyConfig(
            maxLevels: maxLevels,
            normalization: .zeroCentered,
            useFloatAccumulation: true,
            includeNeighborPenalty: false,
            quantizeLowpassToHalf: true,
            includeNeighborCorrFeature: true
        )
    }

    static func defaultConfig(for gpuBackend: GPUBackend, imageSize: Int) -> ProxyConfig {
        switch gpuBackend {
        case .metal:
            return metalDefault(imageSize: imageSize)
        case .mps:
            return mpsDefault(imageSize: imageSize)
        }
    }
}

struct WaveletProxy {
    let size: Int
    private var bufferA: [Float]
    private var bufferB: [Float]

    init(size: Int = 128) {
        precondition(size > 0 && (size & (size - 1)) == 0, "size must be power-of-two")
        self.size = size
        let n = size * size
        self.bufferA = [Float](repeating: 0, count: n)
        self.bufferB = [Float](repeating: 0, count: n)
    }

    mutating func featureVector(seed: UInt64) -> [Double] {
        featureVector(seed: seed, config: ProxyConfig.legacyDefault(imageSize: size))
    }

    mutating func featureVector(seed: UInt64, config: ProxyConfig) -> [Double] {
        fillNormalized(seed: seed, normalization: config.normalization)
        return computeFeatureVector(
            maxLevels: config.maxLevels,
            useFloatAccumulation: config.useFloatAccumulation,
            quantizeLowpassToHalf: config.quantizeLowpassToHalf,
            includeNeighborCorr: config.includeNeighborCorrFeature
        )
    }

    static func levelCount(for size: Int) -> Int {
        var s = size
        var levels = 0
        while s >= 2 {
            levels += 1
            s >>= 1
        }
        return levels
    }

    static func levelCount(for size: Int, maxLevels: Int?) -> Int {
        let full = levelCount(for: size)
        guard let maxLevels else { return full }
        return min(full, max(1, maxLevels))
    }

    static func shapeLevelIndices(for size: Int) -> [Int] {
        shapeLevelIndices(levelCount: levelCount(for: size))
    }

    static func shapeLevelIndices(levelCount: Int) -> [Int] {
        if levelCount <= 2 { return Array(0..<levelCount) }
        let mid = (levelCount - 1) / 2
        let first = max(0, mid - 1)
        let second = min(levelCount - 1, mid)
        if first == second { return [first] }
        return [first, second]
    }

    static func featureCount(for size: Int) -> Int {
        featureCount(for: size, config: ProxyConfig.legacyDefault(imageSize: size))
    }

    static func featureCount(for size: Int, config: ProxyConfig) -> Int {
        let levels = levelCount(for: size, maxLevels: config.maxLevels)
        let shapeCount = shapeLevelIndices(levelCount: levels).count
        let neighborCount = config.includeNeighborCorrFeature ? 1 : 0
        return levels + max(0, levels - 1) + shapeCount + shapeCount + neighborCount
    }

    private mutating func fillNormalized(seed: UInt64, normalization: ProxyConfig.Normalization) {
        let n = size * size
        var rng = Mulberry32(seed: seed)
        switch normalization {
        case .meanCentered:
            var sum: Double = 0
            for i in 0..<n {
                let v = Double(rng.nextFloat01()) * 255.0
                bufferA[i] = Float(v)
                sum += v
            }
            let mean = Float(sum / Double(n))
            let inv255: Float = 1.0 / 255.0
            for i in 0..<n {
                bufferA[i] = (bufferA[i] - mean) * inv255
            }
        case .zeroCentered:
            for i in 0..<n {
                bufferA[i] = rng.nextFloat01() - 0.5
            }
        }
    }

    private mutating func computeFeatureVector(
        maxLevels: Int?,
        useFloatAccumulation: Bool,
        quantizeLowpassToHalf: Bool,
        includeNeighborCorr: Bool
    ) -> [Double] {
        let levels = WaveletProxy.levelCount(for: size, maxLevels: maxLevels)
        let shapeLevels = WaveletProxy.shapeLevelIndices(levelCount: levels)
        if useFloatAccumulation {
            return computeFeatureVectorFloat(
                levels: levels,
                shapeLevels: shapeLevels,
                quantizeLowpassToHalf: quantizeLowpassToHalf,
                includeNeighborCorr: includeNeighborCorr
            )
        }
        return computeFeatureVectorDouble(
            levels: levels,
            shapeLevels: shapeLevels,
            quantizeLowpassToHalf: quantizeLowpassToHalf,
            includeNeighborCorr: includeNeighborCorr
        )
    }

    private mutating func computeFeatureVectorDouble(
        levels: Int,
        shapeLevels: [Int],
        quantizeLowpassToHalf: Bool,
        includeNeighborCorr: Bool
    ) -> [Double] {
        let shapeSet = Set(shapeLevels)
        var energies = [Double](repeating: 0, count: levels)
        var maxes = [Double](repeating: 0, count: levels)
        var e2s = [Double](repeating: 0, count: levels)
        var neighborCorr: Double? = nil

        bufferA.withUnsafeMutableBufferPointer { aBuf in
            bufferB.withUnsafeMutableBufferPointer { bBuf in
                guard let aPtr = aBuf.baseAddress, let bPtr = bBuf.baseAddress else { return }
                var srcPtr = aPtr
                var dstPtr = bPtr
                var current = size
                var level = 0

                while current >= 2, level < levels {
                    let next = current / 2
                    var sumVar: Double = 0
                    var sumVar2: Double = 0
                    var maxVar: Double = 0
                    var outIndex = 0
                    let trackShape = shapeSet.contains(level)

                    for y in 0..<next {
                        let row0 = (2 * y) * current
                        let row1 = row0 + current
                        for x in 0..<next {
                            let idx = row0 + (2 * x)
                            let v00 = Double(srcPtr[idx])
                            let v01 = Double(srcPtr[idx + 1])
                            let v10 = Double(srcPtr[row1 + (2 * x)])
                            let v11 = Double(srcPtr[row1 + (2 * x) + 1])

                            let m = 0.25 * (v00 + v01 + v10 + v11)
                            let m2 = 0.25 * (v00 * v00 + v01 * v01 + v10 * v10 + v11 * v11)
                            var varVal = m2 - m * m
                            if varVal < 0 { varVal = 0 }

                            sumVar += varVal
                            if trackShape {
                                sumVar2 += varVal * varVal
                                if varVal > maxVar { maxVar = varVal }
                            }

                            let mFloat = Float(m)
                            dstPtr[outIndex] = quantizeLowpassToHalf ? WaveletProxy.quantizeHalf(mFloat) : mFloat
                            outIndex += 1
                        }
                    }

                    if includeNeighborCorr && level == 0 {
                        neighborCorr = WaveletProxy.neighborCorrelation(ptr: dstPtr, size: next)
                    }

                    let count = Double(next * next)
                    energies[level] = sumVar / count
                    if trackShape {
                        maxes[level] = maxVar
                        e2s[level] = sumVar2 / count
                    }

                    swap(&srcPtr, &dstPtr)
                    current = next
                    level += 1
                }
            }
        }

        return WaveletProxy.composeFeatureVector(
            energies: energies,
            maxes: maxes,
            e2s: e2s,
            shapeLevels: shapeLevels,
            neighborCorr: neighborCorr,
            includeNeighborCorr: includeNeighborCorr
        )
    }

    private mutating func computeFeatureVectorFloat(
        levels: Int,
        shapeLevels: [Int],
        quantizeLowpassToHalf: Bool,
        includeNeighborCorr: Bool
    ) -> [Double] {
        let shapeSet = Set(shapeLevels)
        var energies = [Double](repeating: 0, count: levels)
        var maxes = [Double](repeating: 0, count: levels)
        var e2s = [Double](repeating: 0, count: levels)
        var neighborCorr: Double? = nil

        bufferA.withUnsafeMutableBufferPointer { aBuf in
            bufferB.withUnsafeMutableBufferPointer { bBuf in
                guard let aPtr = aBuf.baseAddress, let bPtr = bBuf.baseAddress else { return }
                var srcPtr = aPtr
                var dstPtr = bPtr
                var current = size
                var level = 0

                while current >= 2, level < levels {
                    let next = current / 2
                    var sumVar: Float = 0
                    var sumVar2: Float = 0
                    var maxVar: Float = 0
                    var outIndex = 0
                    let trackShape = shapeSet.contains(level)

                    for y in 0..<next {
                        let row0 = (2 * y) * current
                        let row1 = row0 + current
                        for x in 0..<next {
                            let idx = row0 + (2 * x)
                            let v00 = srcPtr[idx]
                            let v01 = srcPtr[idx + 1]
                            let v10 = srcPtr[row1 + (2 * x)]
                            let v11 = srcPtr[row1 + (2 * x) + 1]

                            let m = 0.25 * (v00 + v01 + v10 + v11)
                            let m2 = 0.25 * (v00 * v00 + v01 * v01 + v10 * v10 + v11 * v11)
                            var varVal = m2 - m * m
                            if varVal < 0 { varVal = 0 }

                            sumVar += varVal
                            if trackShape {
                                sumVar2 += varVal * varVal
                                if varVal > maxVar { maxVar = varVal }
                            }

                            dstPtr[outIndex] = quantizeLowpassToHalf ? WaveletProxy.quantizeHalf(m) : m
                            outIndex += 1
                        }
                    }

                    if includeNeighborCorr && level == 0 {
                        neighborCorr = WaveletProxy.neighborCorrelation(ptr: dstPtr, size: next)
                    }

                    let count = Float(next * next)
                    energies[level] = Double(sumVar / count)
                    if trackShape {
                        maxes[level] = Double(maxVar)
                        e2s[level] = Double(sumVar2 / count)
                    }

                    swap(&srcPtr, &dstPtr)
                    current = next
                    level += 1
                }
            }
        }

        return WaveletProxy.composeFeatureVector(
            energies: energies,
            maxes: maxes,
            e2s: e2s,
            shapeLevels: shapeLevels,
            neighborCorr: neighborCorr,
            includeNeighborCorr: includeNeighborCorr
        )
    }

    // Feature order: E_k, R_k=E_k/E_{k+1}, peak_k at shape levels, cv2_k at shape levels.
    private static func composeFeatureVector(
        energies: [Double],
        maxes: [Double],
        e2s: [Double],
        shapeLevels: [Int],
        neighborCorr: Double?,
        includeNeighborCorr: Bool
    ) -> [Double] {
        let levels = energies.count
        let eps = ScoringConstants.eps
        let totalCount = levels + max(0, levels - 1) + shapeLevels.count + shapeLevels.count + (includeNeighborCorr ? 1 : 0)
        var features: [Double] = []
        features.reserveCapacity(totalCount)

        for v in energies { features.append(v) }
        if levels > 1 {
            for i in 0..<(levels - 1) {
                features.append(energies[i] / (energies[i + 1] + eps))
            }
        }
        for idx in shapeLevels {
            features.append(maxes[idx] / (energies[idx] + eps))
        }
        for idx in shapeLevels {
            let denom = energies[idx] * energies[idx] + eps
            features.append((e2s[idx] / denom) - 1.0)
        }
        if includeNeighborCorr {
            features.append(neighborCorr ?? 0.0)
        }

        return features
    }

    @inline(__always)
    private static func quantizeHalf(_ value: Float) -> Float {
        Float(Float16(value))
    }

    private static func neighborCorrelation(ptr: UnsafePointer<Float>, size: Int) -> Double {
        if size <= 1 { return 0 }
        let w = size
        let h = size
        let eps = Float(ScoringConstants.eps)

        func corr(sumA: Float, sumB: Float, sumA2: Float, sumB2: Float, sumAB: Float, n: Int) -> Float {
            if n <= 1 { return 0 }
            let invN = 1.0 / Float(n)
            let meanA = sumA * invN
            let meanB = sumB * invN
            let cov = (sumAB * invN) - (meanA * meanB)
            let varA = (sumA2 * invN) - (meanA * meanA)
            let varB = (sumB2 * invN) - (meanB * meanB)
            if varA <= 1e-18 || varB <= 1e-18 { return 0 }
            return cov / (sqrt(varA * varB) + eps)
        }

        var sumAx: Float = 0
        var sumBx: Float = 0
        var sumAx2: Float = 0
        var sumBx2: Float = 0
        var sumABx: Float = 0
        var nx = 0

        for y in 0..<h {
            let row = y * w
            for x in 0..<(w - 1) {
                let a = ptr[row + x]
                let b = ptr[row + x + 1]
                sumAx += a
                sumBx += b
                sumAx2 += a * a
                sumBx2 += b * b
                sumABx += a * b
                nx += 1
            }
        }

        var sumAy: Float = 0
        var sumBy: Float = 0
        var sumAy2: Float = 0
        var sumBy2: Float = 0
        var sumABy: Float = 0
        var ny = 0

        for y in 0..<(h - 1) {
            let row = y * w
            let rowDown = (y + 1) * w
            for x in 0..<w {
                let a = ptr[row + x]
                let b = ptr[rowDown + x]
                sumAy += a
                sumBy += b
                sumAy2 += a * a
                sumBy2 += b * b
                sumABy += a * b
                ny += 1
            }
        }

        let corrX = corr(sumA: sumAx, sumB: sumBx, sumA2: sumAx2, sumB2: sumBx2, sumAB: sumABx, n: nx)
        let corrY = corr(sumA: sumAy, sumB: sumBy, sumA2: sumAy2, sumB2: sumBy2, sumAB: sumABy, n: ny)
        return Double(0.5 * (corrX + corrY))
    }
}

struct ProxyWeights: Codable {
    static let schemaVersion: Int = 1

    let schemaVersion: Int
    let createdAt: Date
    let imageSize: Int
    let featureCount: Int
    let config: ProxyConfig?
    let bias: Double
    let weights: [Double]

    func predict(features: [Double]) -> Double {
        let n = min(features.count, weights.count)
        var out = bias
        if n > 0 {
            for i in 0..<n {
                out += weights[i] * features[i]
            }
        }
        return out
    }

    func asFloatWeights(expectedCount: Int) -> (bias: Float, weights: [Float]) {
        var out = [Float](repeating: 0, count: expectedCount)
        let n = min(expectedCount, weights.count)
        if n > 0 {
            for i in 0..<n {
                out[i] = Float(weights[i])
            }
        }
        return (Float(bias), out)
    }

    static func defaultWeights(imageSize: Int, featureCount: Int, config: ProxyConfig) -> ProxyWeights {
        ProxyWeights(
            schemaVersion: schemaVersion,
            createdAt: Date(),
            imageSize: imageSize,
            featureCount: featureCount,
            config: config,
            bias: 0,
            weights: [Double](repeating: 0, count: featureCount)
        )
    }

    static func loadValid(from url: URL, imageSize: Int, featureCount: Int, expectedConfig: ProxyConfig? = nil) -> ProxyWeights? {
        guard let w = CalibrationSupport.loadJSON(ProxyWeights.self, from: url) else { return nil }
        guard w.schemaVersion == schemaVersion else { return nil }
        guard w.imageSize == imageSize else { return nil }
        guard w.featureCount == featureCount else { return nil }
        guard w.weights.count == featureCount else { return nil }
        if let expectedConfig {
            let resolved = w.config ?? ProxyConfig.legacyDefault(imageSize: imageSize)
            guard resolved == expectedConfig else { return nil }
        }
        return w
    }

    static func loadOrDefault(from url: URL, imageSize: Int, featureCount: Int, expectedConfig: ProxyConfig) -> (weights: ProxyWeights, usedDefault: Bool) {
        if let w = loadValid(from: url, imageSize: imageSize, featureCount: featureCount, expectedConfig: expectedConfig) {
            return (w, false)
        }
        return (defaultWeights(imageSize: imageSize, featureCount: featureCount, config: expectedConfig), true)
    }

    static func save(_ weights: ProxyWeights, to url: URL) throws {
        try CalibrationSupport.saveJSON(weights, to: url)
    }
}
