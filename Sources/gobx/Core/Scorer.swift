import Accelerate
import Darwin
import Foundation

final class Scorer {
    static let scorerVersion: Int = 1

    let size: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    private var real: [Float]
    private var imag: [Float]

    private let rBin: [Int]
    private let rCounts: [Int]
    private var rSums: [Double]
    private var meanPower: [Double]
    private let logR: [Double]

    private let ringMask: [UInt8]
    private var ringValues: [Float]

    init(size: Int = 128) {
        precondition(size > 0 && (size & (size - 1)) == 0, "size must be power-of-two")
        self.size = size
        self.half = size / 2
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup

        let n = size * size
        self.real = [Float](repeating: 0, count: n)
        self.imag = [Float](repeating: 0, count: n)
        let cy = Double(size - 1) / 2.0
        let cx = Double(size - 1) / 2.0
        let maxR = Int(floor(sqrt(cx * cx + cy * cy))) + 1

        var rBin = [Int](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: maxR)
        for y in 0..<size {
            for x in 0..<size {
                let r = Int(floor(sqrt(pow(Double(y) - cy, 2) + pow(Double(x) - cx, 2))))
                let idx = y * size + x
                rBin[idx] = r
                if r < maxR { counts[r] += 1 }
            }
        }

        let rMax = sqrt(cx * cx + cy * cy)
        let ringRMin = ScoringConstants.peakinessRMinFrac * rMax
        let ringRMax = ScoringConstants.peakinessRMaxFrac * rMax

        var ringMask = [UInt8](repeating: 0, count: n)
        var ringCount = 0
        for y in 0..<size {
            for x in 0..<size {
                let r = sqrt(pow(Double(y) - cy, 2) + pow(Double(x) - cx, 2))
                if r >= ringRMin && r <= ringRMax {
                    ringMask[y * size + x] = 1
                    ringCount += 1
                }
            }
        }

        self.rBin = rBin
        self.rCounts = counts
        self.rSums = [Double](repeating: 0, count: maxR)
        self.meanPower = [Double](repeating: 0, count: maxR)

        self.logR = (0..<maxR).map { log(Double($0) + ScoringConstants.eps) }

        self.ringMask = ringMask
        self.ringValues = [Float](repeating: 0, count: ringCount)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func score(seed: UInt64) -> ScoreResult {
        let n = size * size

        // 1) Generate deterministic noise and normalize.
        var rng = Mulberry32(seed: seed)
        var sum: Double = 0
        real.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                let v = Double(rng.nextFloat01()) * 255.0
                buf[i] = Float(v)
                sum += v
            }
        }
        let mean = sum / Double(n)
        let meanF = Float(mean)
        let inv255 = Float(1.0 / 255.0)
        real.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                buf[i] = (buf[i] - meanF) * inv255
            }
        }
        imag.withUnsafeMutableBufferPointer { buf in
            vDSP_vclr(buf.baseAddress!, 1, vDSP_Length(n))
        }

        // 2) Neighbor correlation (on normalized image).
        let neighCorr = neighborCorrelation()
        let neighCorrPenalty: Double
        if neighCorr < ScoringConstants.neighborCorrMin {
            neighCorrPenalty = -ScoringConstants.neighborCorrWeight * (ScoringConstants.neighborCorrMin - neighCorr)
        } else {
            neighCorrPenalty = 0
        }

        for i in 0..<rSums.count { rSums[i] = 0 }

        // 3) 2D FFT + shifted power spectrum (fused with radial + ring stats).
        var mx: Float = -Float.infinity
        var ringCount = 0
        var flatCount = 0
        var flatSum: Double = 0
        var flatLogSum: Double = 0

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft2d_zip(fftSetup, &split, 1, 0, log2n, log2n, FFTDirection(FFT_FORWARD))

                ringValues.withUnsafeMutableBufferPointer { vBuf in
                    for y in 0..<size {
                        let srcY = (y + half) & (size - 1)
                        let dstRow = y * size
                        let srcRowBase = srcY * size
                        for x in 0..<size {
                            let srcX = (x + half) & (size - 1)
                            let srcIdx = srcRowBase + srcX
                            let dstIdx = dstRow + x
                            let re = split.realp[srcIdx]
                            let im = split.imagp[srcIdx]
                            let p = re * re + im * im

                            rSums[rBin[dstIdx]] += Double(p)

                            if ringMask[dstIdx] != 0 {
                                if !p.isFinite { continue }
                                vBuf[ringCount] = p
                                ringCount += 1
                                if p > mx { mx = p }

                                let vd = Double(p)
                                flatCount += 1
                                flatSum += vd
                                flatLogSum += log(vd + ScoringConstants.eps)
                            }
                        }
                    }
                }
            }
        }

        // 4) Radial profile mean (shifted power).
        for r in 0..<meanPower.count {
            let c = rCounts[r]
            meanPower[r] = c > 0 ? (rSums[r] / Double(c)) : 0
        }

        // 5) Alpha estimation (linear regression in log-log space).
        let rMaxIndex = meanPower.count - 1
        let fitRMax = max(ScoringConstants.alphaFitRMin + 2, Int(floor(Double(rMaxIndex) * ScoringConstants.alphaFitRMaxFrac)))
        var regN = 0
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        if fitRMax >= ScoringConstants.alphaFitRMin {
            for r in ScoringConstants.alphaFitRMin...min(fitRMax, rMaxIndex) {
                let p = meanPower[r]
                if p.isFinite && p > 0 {
                    let x = logR[r]
                    let y = log(p + ScoringConstants.eps)
                    regN += 1
                    sumX += x
                    sumY += y
                    sumXY += x * y
                    sumX2 += x * x
                }
            }
        }

        let alphaEst: Double
        if regN < 6 {
            alphaEst = .nan
        } else {
            let nD = Double(regN)
            let denom = (nD * sumX2 - sumX * sumX)
            if denom == 0 {
                alphaEst = .nan
            } else {
                let slope = (nD * sumXY - sumX * sumY) / denom
                alphaEst = -slope
            }
        }
        let alphaScore = alphaEst.isFinite ? -abs(alphaEst - ScoringConstants.targetAlpha) : -10.0

        // 6) Peakiness + flatness over the mid-frequency ring.
        let peakiness: Double
        if ringCount < 64 {
            peakiness = 0
        } else {
            let mid = ringCount / 2
            let m2 = quickselect(&ringValues, k: mid, count: ringCount)
            let med: Float
            if ringCount % 2 == 0 {
                let m1 = quickselect(&ringValues, k: mid - 1, count: ringCount)
                med = 0.5 * (m1 + m2)
            } else {
                med = m2
            }

            let medEps = Double(med) + ScoringConstants.eps
            let mxEps = Double(mx) + ScoringConstants.eps
            peakiness = log10(mxEps / medEps + ScoringConstants.eps)
        }
        let peakinessPenalty = -ScoringConstants.lambdaPeakiness * peakiness

        let flatness: Double
        if flatCount < 64 {
            flatness = 0
        } else {
            let c = Double(flatCount)
            let gm = exp(flatLogSum / c)
            let am = (flatSum / c) + ScoringConstants.eps
            flatness = gm / am
        }
        let flatnessPenalty: Double
        if flatness > ScoringConstants.flatnessMax {
            flatnessPenalty = -ScoringConstants.flatnessWeight * (flatness - ScoringConstants.flatnessMax)
        } else {
            flatnessPenalty = 0
        }

        let totalScore = alphaScore + peakinessPenalty + flatnessPenalty + neighCorrPenalty

        return ScoreResult(
            seed: seed,
            alphaEst: alphaEst,
            alphaScore: alphaScore,
            peakiness: peakiness,
            peakinessPenalty: peakinessPenalty,
            flatness: flatness,
            flatnessPenalty: flatnessPenalty,
            neighborCorr: neighCorr,
            neighborCorrPenalty: neighCorrPenalty,
            totalScore: totalScore
        )
    }

    private func neighborCorrelation() -> Double {
        let w = size
        let h = size

        return real.withUnsafeBufferPointer { buf in
            func corr(sumA: Double, sumB: Double, sumA2: Double, sumB2: Double, sumAB: Double, n: Int) -> Double {
                if n <= 1 { return 0 }
                let invN = 1.0 / Double(n)
                let meanA = sumA * invN
                let meanB = sumB * invN
                let cov = (sumAB * invN) - (meanA * meanB)
                let varA = (sumA2 * invN) - (meanA * meanA)
                let varB = (sumB2 * invN) - (meanB * meanB)
                if varA <= 1e-18 || varB <= 1e-18 { return 0 }
                return cov / (sqrt(varA * varB) + ScoringConstants.eps)
            }

            var sumAx: Double = 0
            var sumBx: Double = 0
            var sumAx2: Double = 0
            var sumBx2: Double = 0
            var sumABx: Double = 0
            var nx = 0

            for y in 0..<h {
                let row = y * w
                for x in 0..<(w - 1) {
                    let a = Double(buf[row + x])
                    let b = Double(buf[row + x + 1])
                    sumAx += a
                    sumBx += b
                    sumAx2 += a * a
                    sumBx2 += b * b
                    sumABx += a * b
                    nx += 1
                }
            }

            var sumAy: Double = 0
            var sumBy: Double = 0
            var sumAy2: Double = 0
            var sumBy2: Double = 0
            var sumABy: Double = 0
            var ny = 0

            for y in 0..<(h - 1) {
                let row = y * w
                let rowDown = (y + 1) * w
                for x in 0..<w {
                    let a = Double(buf[row + x])
                    let b = Double(buf[rowDown + x])
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
            return 0.5 * (corrX + corrY)
        }
    }
}

@inline(__always)
private func quickselect(_ arr: inout [Float], k: Int, count: Int) -> Float {
    func partition(_ left: Int, _ right: Int, _ pivotIndex: Int) -> Int {
        let pivotValue = arr[pivotIndex]
        arr.swapAt(pivotIndex, right)
        var storeIndex = left
        if left < right {
            for i in left..<right {
                if arr[i] < pivotValue {
                    arr.swapAt(storeIndex, i)
                    storeIndex += 1
                }
            }
        }
        arr.swapAt(right, storeIndex)
        return storeIndex
    }

    var left = 0
    var right = max(0, count - 1)
    while true {
        if left == right { return arr[left] }
        let pivotIndex = (left + right) >> 1
        let pivotNewIndex = partition(left, right, pivotIndex)
        if k == pivotNewIndex { return arr[k] }
        if k < pivotNewIndex {
            right = pivotNewIndex - 1
        } else {
            left = pivotNewIndex + 1
        }
    }
}
