import Darwin
import Dispatch
import Foundation
import Metal
import MetalPerformanceShadersGraph

enum MPSScorerError: Error, CustomStringConvertible {
    case noMetalDevice
    case noCommandQueue
    case invalidBatchSize(Int)
    case invalidImageSize(Int)
    case invalidInflight(Int)
    case bufferAllocationFailed(name: String, length: Int)
    case outputProbeFailed
    case unexpectedOutputType(MPSDataType)
    case unexpectedOutputShape([NSNumber])

    var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device available"
        case .noCommandQueue:
            return "Failed to create Metal command queue"
        case .invalidBatchSize(let n):
            return "Invalid batch size: \(n)"
        case .invalidImageSize(let n):
            return "Invalid image size: \(n)"
        case .invalidInflight(let n):
            return "Invalid inflight: \(n)"
        case .bufferAllocationFailed(let name, let length):
            return "Failed to allocate Metal buffer '\(name)' (\(length) bytes)"
        case .outputProbeFailed:
            return "Failed to probe MPSGraph output shape"
        case .unexpectedOutputType(let t):
            return "Unexpected MPSGraph output type: \(t)"
        case .unexpectedOutputShape(let s):
            return "Unexpected MPSGraph output shape: \(s)"
        }
    }
}

final class MPSScorer {
    static let scorerVersion: Int = 1

    static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    struct Job {
        let slotIndex: Int
        let count: Int
    }

    let batchSize: Int
    let imageSize: Int
    let inflight: Int

    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let graphDevice: MPSGraphDevice
    private let executable: MPSGraphExecutable

    private let seedPlaceholder: MPSGraphTensor
    private let scoreTensor: MPSGraphTensor
    private let outputElementCount: Int
    private var scoreBuffer: [Float]

    private final class Slot {
        let inputBuffer: MTLBuffer
        let inputTensorData: MPSGraphTensorData
        let outputBuffer: MTLBuffer
        let outputTensorData: MPSGraphTensorData
        let executionDescriptor: MPSGraphExecutableExecutionDescriptor
        let done: DispatchSemaphore
        private let lock = NSLock()
        private var lastError: Error? = nil

        init(inputBuffer: MTLBuffer, inputTensorData: MPSGraphTensorData, outputBuffer: MTLBuffer, outputTensorData: MPSGraphTensorData) {
            self.inputBuffer = inputBuffer
            self.inputTensorData = inputTensorData
            self.outputBuffer = outputBuffer
            self.outputTensorData = outputTensorData
            self.done = DispatchSemaphore(value: 0)

            let desc = MPSGraphExecutableExecutionDescriptor()
            desc.waitUntilCompleted = false
            self.executionDescriptor = desc

            desc.completionHandler = { [weak self] _, error in
                guard let self else { return }
                self.lock.lock()
                self.lastError = error
                self.lock.unlock()
                self.done.signal()
            }
        }

        func resetError() {
            lock.lock()
            lastError = nil
            lock.unlock()
        }

        func takeError() -> Error? {
            lock.lock()
            let e = lastError
            lastError = nil
            lock.unlock()
            return e
        }
    }

    private let slots: [Slot]
    private var enqueueCursor: Int = 0

    init(batchSize: Int, imageSize: Int = 128, inflight: Int = 1, optimizationLevel: MPSGraphOptimization = .level1) throws {
        guard batchSize > 0 else { throw MPSScorerError.invalidBatchSize(batchSize) }
        self.batchSize = batchSize
        guard imageSize > 0, (imageSize & (imageSize - 1)) == 0 else { throw MPSScorerError.invalidImageSize(imageSize) }
        self.imageSize = imageSize
        guard inflight > 0 else { throw MPSScorerError.invalidInflight(inflight) }
        self.inflight = inflight

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MPSScorerError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MPSScorerError.noCommandQueue
        }
        self.metalDevice = device
        self.commandQueue = queue
        self.graphDevice = MPSGraphDevice(mtlDevice: device)

        let (graph, seedPh, scoreT) = MPSScorer.buildGraph(batchSize: batchSize, imageSize: imageSize)
        self.seedPlaceholder = seedPh
        self.scoreTensor = scoreT

        let shaped = MPSGraphShapedType(shape: [NSNumber(value: batchSize)], dataType: .uInt64)
        let compDesc = MPSGraphCompilationDescriptor()
        compDesc.optimizationLevel = optimizationLevel
        compDesc.waitForCompilationCompletion = true
        self.executable = graph.compile(
            with: self.graphDevice,
            feeds: [seedPh: shaped],
            targetTensors: [scoreT],
            targetOperations: nil,
            compilationDescriptor: compDesc
        )

        let outputShape = [NSNumber(value: batchSize)]
        self.outputElementCount = batchSize

        let inLen = batchSize * MemoryLayout<UInt64>.stride
        let outLen = batchSize * MemoryLayout<Float>.stride

        var slots: [Slot] = []
        slots.reserveCapacity(inflight)
        for idx in 0..<inflight {
            guard let inBuf = device.makeBuffer(length: inLen, options: .storageModeShared) else {
                throw MPSScorerError.bufferAllocationFailed(name: "input[\(idx)]", length: inLen)
            }
            let inTD = MPSGraphTensorData(inBuf, shape: [NSNumber(value: batchSize)], dataType: .uInt64)

            guard let outBuf = device.makeBuffer(length: outLen, options: .storageModeShared) else {
                throw MPSScorerError.bufferAllocationFailed(name: "output[\(idx)]", length: outLen)
            }
            let outTD = MPSGraphTensorData(outBuf, shape: outputShape, dataType: .float32)

            slots.append(Slot(inputBuffer: inBuf, inputTensorData: inTD, outputBuffer: outBuf, outputTensorData: outTD))
        }
        self.slots = slots

        if ProcessInfo.processInfo.environment["GOBX_MPS_PROBE_OUTPUT"] == "1" {
            let probeDesc = MPSGraphExecutableExecutionDescriptor()
            probeDesc.waitUntilCompleted = true
            let probeOuts: [MPSGraphTensorData] = executable.run(
                with: commandQueue,
                inputs: [slots[0].inputTensorData],
                results: nil,
                executionDescriptor: probeDesc
            )
            guard let probe = probeOuts.first else { throw MPSScorerError.outputProbeFailed }
            guard probe.dataType == .float32 else { throw MPSScorerError.unexpectedOutputType(probe.dataType) }
            guard probe.shape == outputShape else { throw MPSScorerError.unexpectedOutputShape(probe.shape) }
        }

        self.scoreBuffer = [Float](repeating: 0, count: batchSize)
    }

    func score(seeds: [UInt64]) -> [Float] {
        precondition(seeds.count <= batchSize)
        return autoreleasepool {
            let job = seeds.withUnsafeBufferPointer { buf in
                enqueue(seeds: buf, count: seeds.count)
            }
            do {
                return try withCompletedJob(job) { _, scores in
                    let copyCount = min(scores.count, batchSize)
                    scoreBuffer.withUnsafeMutableBufferPointer { buf in
                        buf.baseAddress!.update(from: scores.baseAddress!, count: copyCount)
                    }
                    if seeds.count == batchSize { return scoreBuffer }
                    return Array(scoreBuffer.prefix(copyCount))
                }
            } catch {
                fatalError("MPSScorer run failed: \(error)")
            }
        }
    }

    func enqueue(seeds: UnsafeBufferPointer<UInt64>, count: Int) -> Job {
        precondition(count >= 0 && count <= batchSize)
        let slotIndex = enqueueCursor
        let slot = slots[slotIndex]
        enqueueCursor = (enqueueCursor + 1) % inflight

        slot.resetError()

        let inPtr = slot.inputBuffer.contents().bindMemory(to: UInt64.self, capacity: batchSize)
        if count > 0 {
            precondition(seeds.baseAddress != nil)
            memcpy(inPtr, seeds.baseAddress!, count * MemoryLayout<UInt64>.stride)
        }
        if count < batchSize {
            memset(inPtr.advanced(by: count), 0, (batchSize - count) * MemoryLayout<UInt64>.stride)
        }

        autoreleasepool {
            _ = executable.run(
                with: commandQueue,
                inputs: [slot.inputTensorData],
                results: [slot.outputTensorData],
                executionDescriptor: slot.executionDescriptor
            )
        }

        return Job(slotIndex: slotIndex, count: count)
    }

    func withCompletedJob<T>(_ job: Job, _ body: (UnsafeBufferPointer<UInt64>, UnsafeBufferPointer<Float>) throws -> T) throws -> T {
        precondition(job.count >= 0 && job.count <= batchSize)
        let slot = slots[job.slotIndex]

        slot.done.wait()
        if let e = slot.takeError() {
            throw e
        }

        let seedsPtr = slot.inputBuffer.contents().bindMemory(to: UInt64.self, capacity: batchSize)
        let outPtr = slot.outputBuffer.contents().bindMemory(to: Float.self, capacity: outputElementCount)
        return try body(
            UnsafeBufferPointer(start: seedsPtr, count: job.count),
            UnsafeBufferPointer(start: outPtr, count: job.count)
        )
    }

    private static func buildGraph(batchSize: Int, imageSize: Int) -> (MPSGraph, MPSGraphTensor, MPSGraphTensor) {
        let g = MPSGraph()

        let H = imageSize
        let W = imageSize
        let N = H * W
        let half = H / 2

        // ---- Precomputed constants (CPU side, embedded as graph constants)
        let offsetsU32: [UInt32] = {
            var out = [UInt32](repeating: 0, count: N)
            var acc: UInt32 = 0
            for i in 0..<N {
                acc &+= 0x6D2B79F5
                out[i] = acc
            }
            return out
        }()

        let (rBinsI32, rCountsF, maxR): ([Int32], [Float], Int) = {
            let cy = Double(H - 1) / 2.0
            let cx = Double(W - 1) / 2.0
            let maxR = Int(floor(sqrt(cx * cx + cy * cy))) + 1
            var counts = [Int](repeating: 0, count: maxR)
            var bins = [Int32](repeating: 0, count: N)
            for y in 0..<H {
                for x in 0..<W {
                    let r = Int(floor(sqrt(pow(Double(y) - cy, 2) + pow(Double(x) - cx, 2))))
                    let idx = y * W + x
                    bins[idx] = Int32(r)
                    counts[r] += 1
                }
            }
            return (bins, counts.map { Float($0) }, maxR)
        }()

        let (ringMaskF, ringCountF): ([Float], Float) = {
            let cy = Double(H - 1) / 2.0
            let cx = Double(W - 1) / 2.0
            let rMax = sqrt(cx * cx + cy * cy)
            let rMin = ScoringConstants.peakinessRMinFrac * rMax
            let rMaxUse = ScoringConstants.peakinessRMaxFrac * rMax
            var mask = [Float](repeating: 0, count: N)
            var count = 0
            for y in 0..<H {
                for x in 0..<W {
                    let r = sqrt(pow(Double(y) - cy, 2) + pow(Double(x) - cx, 2))
                    let idx = y * W + x
                    if r >= rMin && r <= rMaxUse {
                        mask[idx] = 1
                        count += 1
                    }
                }
            }
            return (mask, Float(count))
        }()

        let (alphaMaskF, alphaXVecF, alphaN, alphaSumX, alphaSumX2): ([Float], [Float], Float, Float, Float) = {
            let rMaxIndex = maxR - 1
            let fitRMax = max(ScoringConstants.alphaFitRMin + 2, Int(floor(Float(rMaxIndex) * ScoringConstants.Float32.alphaFitRMaxFrac)))
            var mask = [Float](repeating: 0, count: maxR)
            var xVec = [Float](repeating: 0, count: maxR)
            var n: Float = 0
            var sumX: Double = 0
            var sumX2: Double = 0
            for r in 0..<maxR {
                let x = log(Double(r) + ScoringConstants.eps)
                xVec[r] = Float(x)
                if r >= ScoringConstants.alphaFitRMin && r <= fitRMax {
                    mask[r] = 1
                    n += 1
                    sumX += x
                    sumX2 += x * x
                }
            }
            return (mask, xVec, n, Float(sumX), Float(sumX2))
        }()

        // ---- Seed input
        let seeds = g.placeholder(
            shape: [NSNumber(value: batchSize)],
            dataType: .uInt64,
            name: "seeds"
        )

        let shift32 = g.constant(32.0, dataType: .uInt64)
        let seedHiU64 = g.bitwiseRightShift(seeds, shift32, name: "seedHiU64")
        let seedHi = g.cast(seedHiU64, to: .uInt32, name: "seedHiU32")
        let seedLo = g.cast(seeds, to: .uInt32, name: "seedLoU32")

        let phi = g.constant(Double(UInt32(0x9E3779B9)), dataType: .uInt32)
        let hiMix = g.multiplication(seedHi, phi, name: "hiMix")

        // states = seedLo + offsets, both in uInt32 domain (wrap-around)
        let offsetsData = offsetsU32.withUnsafeBytes { Data($0) }
        let offsets = g.constant(offsetsData, shape: [NSNumber(value: N)], dataType: .uInt32)

        let seedLo2d = g.reshape(seedLo, shape: [NSNumber(value: batchSize), 1], name: "seedLo2d")
        let hiMix2d = g.reshape(hiMix, shape: [NSNumber(value: batchSize), 1], name: "hiMix2d")
        let offsets2d = g.reshape(offsets, shape: [1, NSNumber(value: N)], name: "offsets2d")
        let state = g.addition(seedLo2d, offsets2d, name: "state")

        // Mulberry32 mix (vectorized)
        let t0 = g.bitwiseXOR(state, hiMix2d, name: "t0")

        let c1 = g.constant(1.0, dataType: .uInt32)
        let c61 = g.constant(61.0, dataType: .uInt32)
        let sh15 = g.constant(15.0, dataType: .uInt32)
        let sh7 = g.constant(7.0, dataType: .uInt32)
        let sh14 = g.constant(14.0, dataType: .uInt32)

        let t15 = g.bitwiseRightShift(t0, sh15, name: "t15")
        let a1 = g.bitwiseXOR(t0, t15, name: "a1")
        let b1 = g.bitwiseOR(t0, c1, name: "b1")
        let t1 = g.multiplication(a1, b1, name: "t1")

        let t7 = g.bitwiseRightShift(t1, sh7, name: "t7")
        let a2 = g.bitwiseXOR(t1, t7, name: "a2")
        let b2 = g.bitwiseOR(t1, c61, name: "b2")
        let m2 = g.multiplication(a2, b2, name: "m2")
        let tPlus = g.addition(t1, m2, name: "tPlus")
        let t2 = g.bitwiseXOR(t1, tPlus, name: "t2")

        let t14 = g.bitwiseRightShift(t2, sh14, name: "t14")
        let outU = g.bitwiseXOR(t2, t14, name: "outU")

        // Convert to float noise in [0,255)
        let outF = g.cast(outU, to: .float32, name: "outF")
        let inv2p32 = g.constant(1.0 / 4294967296.0, dataType: .float32)
        let out01 = g.multiplication(outF, inv2p32, name: "out01")
        let scale255 = g.constant(255.0, dataType: .float32)
        let noiseFlat = g.multiplication(out01, scale255, name: "noiseFlat")

        let noise = g.reshape(
            noiseFlat,
            shape: [NSNumber(value: batchSize), NSNumber(value: H), NSNumber(value: W)],
            name: "noise"
        )

        // Normalize (remove DC): (noise - mean)/255
        let mean = g.mean(of: noise, axes: [1, 2] as [NSNumber], name: "mean")
        let mean3 = g.reshape(mean, shape: [NSNumber(value: batchSize), 1, 1], name: "mean3")
        let centered = g.subtraction(noise, mean3, name: "centered")
        let inv255 = g.constant(1.0 / 255.0, dataType: .float32)
        let data = g.multiplication(centered, inv255, name: "data")

        // Neighbor correlation
        let left = g.sliceTensor(data, dimension: 2, start: 0, length: W - 1, name: "left")
        let right = g.sliceTensor(data, dimension: 2, start: 1, length: W - 1, name: "right")
        let up = g.sliceTensor(data, dimension: 1, start: 0, length: H - 1, name: "up")
        let down = g.sliceTensor(data, dimension: 1, start: 1, length: H - 1, name: "down")

        func corr(_ a: MPSGraphTensor, _ b: MPSGraphTensor, nPairs: Float, namePrefix: String) -> MPSGraphTensor {
            let axes = [1, 2] as [NSNumber]
            let sumA = g.reductionSum(with: a, axes: axes, name: "\(namePrefix)_sumA")
            let sumB = g.reductionSum(with: b, axes: axes, name: "\(namePrefix)_sumB")
            let sumA2 = g.reductionSum(with: g.multiplication(a, a, name: nil), axes: axes, name: "\(namePrefix)_sumA2")
            let sumB2 = g.reductionSum(with: g.multiplication(b, b, name: nil), axes: axes, name: "\(namePrefix)_sumB2")
            let sumAB = g.reductionSum(with: g.multiplication(a, b, name: nil), axes: axes, name: "\(namePrefix)_sumAB")

            let invN = g.constant(1.0 / Double(nPairs), dataType: .float32)
            let meanA = g.multiplication(sumA, invN, name: "\(namePrefix)_meanA")
            let meanB = g.multiplication(sumB, invN, name: "\(namePrefix)_meanB")
            let cov = g.subtraction(
                g.multiplication(sumAB, invN, name: nil),
                g.multiplication(meanA, meanB, name: nil),
                name: "\(namePrefix)_cov"
            )
            let varA = g.subtraction(g.multiplication(sumA2, invN, name: nil), g.multiplication(meanA, meanA, name: nil), name: "\(namePrefix)_varA")
            let varB = g.subtraction(g.multiplication(sumB2, invN, name: nil), g.multiplication(meanB, meanB, name: nil), name: "\(namePrefix)_varB")

            let minVar = g.constant(1e-18, dataType: .float32)
            let varAclamped = g.maximum(varA, minVar, name: "\(namePrefix)_varAclamped")
            let varBclamped = g.maximum(varB, minVar, name: "\(namePrefix)_varBclamped")
            let denom = g.addition(
                g.squareRoot(with: g.multiplication(varAclamped, varBclamped, name: nil), name: nil),
                g.constant(ScoringConstants.eps, dataType: .float32),
                name: "\(namePrefix)_denom"
            )
            return g.division(cov, denom, name: "\(namePrefix)_corr")
        }

        let corrX = corr(left, right, nPairs: Float(H * (W - 1)), namePrefix: "corrX")
        let corrY = corr(up, down, nPairs: Float((H - 1) * W), namePrefix: "corrY")
        let neighborCorr = g.multiplication(
            g.addition(corrX, corrY, name: "corrXY"),
            g.constant(0.5, dataType: .float32),
            name: "neighborCorr"
        )

        let neighDelta = g.subtraction(g.constant(ScoringConstants.neighborCorrMin, dataType: .float32), neighborCorr, name: "neighDelta")
        let neighDeltaPos = g.maximum(neighDelta, g.constant(0.0, dataType: .float32), name: "neighDeltaPos")
        let neighborCorrPenalty = g.multiplication(neighDeltaPos, g.constant(-ScoringConstants.neighborCorrWeight, dataType: .float32), name: "neighborCorrPenalty")

        // FFT + power spectrum
        let fftDesc = MPSGraphFFTDescriptor()
        fftDesc.inverse = false
        fftDesc.scalingMode = .none

        let fft = g.fastFourierTransform(data, axes: [1, 2] as [NSNumber], descriptor: fftDesc, name: "fft")
        let re = g.realPartOfTensor(tensor: fft, name: "re")
        let im = g.imaginaryPartOfTensor(tensor: fft, name: "im")
        let re2 = g.multiplication(re, re, name: "re2")
        let im2 = g.multiplication(im, im, name: "im2")
        let power = g.addition(re2, im2, name: "power")

        // fftShift: shift by half in both spatial dims (1,2)
        let pTop = g.sliceTensor(power, dimension: 1, start: half, length: half, name: "pTop")
        let pBot = g.sliceTensor(power, dimension: 1, start: 0, length: half, name: "pBot")
        let pRowShift = g.concatTensors([pTop, pBot], dimension: 1, name: "pRowShift")
        let pRight = g.sliceTensor(pRowShift, dimension: 2, start: half, length: half, name: "pRight")
        let pLeft = g.sliceTensor(pRowShift, dimension: 2, start: 0, length: half, name: "pLeft")
        let pShift = g.concatTensors([pRight, pLeft], dimension: 2, name: "pShift")

        // Ring stats (used for both peakiness + flatness)
        let ringMaskData = ringMaskF.withUnsafeBytes { Data($0) }
        let ringMask = g.constant(ringMaskData, shape: [NSNumber(value: H), NSNumber(value: W)], dataType: .float32)
        let ringMask3 = g.reshape(ringMask, shape: [1, NSNumber(value: H), NSNumber(value: W)], name: "ringMask3")
        let ringVals = g.multiplication(pShift, ringMask3, name: "ringVals")

        let ringSum = g.reductionSum(with: ringVals, axes: [1, 2] as [NSNumber], name: "ringSum")
        let ringMean = g.division(ringSum, g.constant(Double(ringCountF), dataType: .float32), name: "ringMean")

        let ringMax = g.reductionMaximum(with: ringVals, axes: [1, 2] as [NSNumber], name: "ringMax")

        let logInput = g.addition(pShift, g.constant(ScoringConstants.eps, dataType: .float32), name: "logInput")
        let logAll = g.logarithm(with: logInput, name: "logAll")
        let ringLog = g.multiplication(logAll, ringMask3, name: "ringLog")
        let ringLogSum = g.reductionSum(with: ringLog, axes: [1, 2] as [NSNumber], name: "ringLogSum")
        let ringLogMean = g.division(ringLogSum, g.constant(Double(ringCountF), dataType: .float32), name: "ringLogMean")
        let ringGM = g.exponent(with: ringLogMean, name: "ringGM")

        // Approx peakiness: log10(max / gm)
        let peakRatio = g.division(
            g.addition(ringMax, g.constant(ScoringConstants.eps, dataType: .float32), name: nil),
            g.addition(ringGM, g.constant(ScoringConstants.eps, dataType: .float32), name: nil),
            name: "peakRatio"
        )
        let peakiness = g.multiplication(
            g.logarithm(with: g.addition(peakRatio, g.constant(ScoringConstants.eps, dataType: .float32), name: nil), name: nil),
            g.constant(1.0 / log(10.0), dataType: .float32),
            name: "peakiness"
        )
        let peakinessPenalty = g.multiplication(peakiness, g.constant(-ScoringConstants.lambdaPeakiness, dataType: .float32), name: "peakinessPenalty")

        // Flatness
        let flatness = g.division(
            ringGM,
            g.addition(ringMean, g.constant(ScoringConstants.eps, dataType: .float32), name: nil),
            name: "flatness"
        )
        let flatDelta = g.subtraction(flatness, g.constant(ScoringConstants.flatnessMax, dataType: .float32), name: "flatDelta")
        let flatDeltaPos = g.maximum(flatDelta, g.constant(0.0, dataType: .float32), name: "flatDeltaPos")
        let flatnessPenalty = g.multiplication(flatDeltaPos, g.constant(-ScoringConstants.flatnessWeight, dataType: .float32), name: "flatnessPenalty")

        // Radial mean power via scatter-add into radius bins
        let powerFlat2 = g.reshape(pShift, shape: [NSNumber(value: batchSize), NSNumber(value: N)], name: "powerFlat2")
        let rBinsData = rBinsI32.withUnsafeBytes { Data($0) }
        let rBins = g.constant(rBinsData, shape: [NSNumber(value: N)], dataType: .int32)
        let rBins2 = g.reshape(rBins, shape: [1, NSNumber(value: N)], name: "rBins2")
        let rBinsB = g.broadcast(rBins2, shape: [NSNumber(value: batchSize), NSNumber(value: N)], name: "rBinsB")
        let rBinsND = g.reshape(rBinsB, shape: [NSNumber(value: batchSize), NSNumber(value: N), 1], name: "rBinsND")
        let sumsByR = g.scatterND(
            withUpdatesTensor: powerFlat2,
            indicesTensor: rBinsND,
            shape: [NSNumber(value: batchSize), NSNumber(value: maxR)],
            batchDimensions: 1,
            mode: .add,
            name: "sumsByR"
        )
        let rCountsData = rCountsF.withUnsafeBytes { Data($0) }
        let rCounts = g.constant(rCountsData, shape: [NSNumber(value: maxR)], dataType: .float32)
        let rCounts2 = g.reshape(rCounts, shape: [1, NSNumber(value: maxR)], name: "rCounts2")
        let meanPower = g.division(sumsByR, rCounts2, name: "meanPower")

        // Alpha estimation: slope of log(meanPower) vs log(r) in [R_MIN..fitRMax]
        let alphaMaskData = alphaMaskF.withUnsafeBytes { Data($0) }
        let alphaMask = g.constant(alphaMaskData, shape: [NSNumber(value: maxR)], dataType: .float32)
        let alphaMask2 = g.reshape(alphaMask, shape: [1, NSNumber(value: maxR)], name: "alphaMask2")

        let xData = alphaXVecF.withUnsafeBytes { Data($0) }
        let xVec = g.constant(xData, shape: [NSNumber(value: maxR)], dataType: .float32)
        let xVec2 = g.reshape(xVec, shape: [1, NSNumber(value: maxR)], name: "xVec2")

        let yVec = g.logarithm(with: g.addition(meanPower, g.constant(ScoringConstants.eps, dataType: .float32), name: nil), name: "yVec")
        let yMasked = g.multiplication(yVec, alphaMask2, name: "yMasked")
        let sumY = g.reductionSum(with: yMasked, axes: [1] as [NSNumber], name: "sumY")
        let sumXY = g.reductionSum(with: g.multiplication(yMasked, xVec2, name: nil), axes: [1] as [NSNumber], name: "sumXY")

        let nFit = g.constant(Double(alphaN), dataType: .float32)
        let sumXc = g.constant(Double(alphaSumX), dataType: .float32)
        let sumX2c = g.constant(Double(alphaSumX2), dataType: .float32)

        let num = g.subtraction(g.multiplication(nFit, sumXY, name: nil), g.multiplication(sumXc, sumY, name: nil), name: "alphaNum")
        let den = g.subtraction(g.multiplication(nFit, sumX2c, name: nil), g.multiplication(sumXc, sumXc, name: nil), name: "alphaDen")
        let slope = g.division(num, den, name: "slope")
        let alphaEst = g.multiplication(slope, g.constant(-1.0, dataType: .float32), name: "alphaEst")
        let alphaScore = g.multiplication(
            g.absolute(with: g.subtraction(alphaEst, g.constant(ScoringConstants.targetAlpha, dataType: .float32), name: nil), name: nil),
            g.constant(-1.0, dataType: .float32),
            name: "alphaScore"
        )

        // MPSGraph reductions often keep reduced dimensions (size=1). Ensure we return a 1D [batch] tensor.
        let alphaScore1d = g.reshape(alphaScore, shape: [NSNumber(value: batchSize)], name: "alphaScore1d")
        let peakinessPenalty1d = g.reshape(peakinessPenalty, shape: [NSNumber(value: batchSize)], name: "peakinessPenalty1d")
        let flatnessPenalty1d = g.reshape(flatnessPenalty, shape: [NSNumber(value: batchSize)], name: "flatnessPenalty1d")
        let neighborCorrPenalty1d = g.reshape(neighborCorrPenalty, shape: [NSNumber(value: batchSize)], name: "neighborCorrPenalty1d")

        let total = g.addition(
            g.addition(alphaScore1d, peakinessPenalty1d, name: "s1"),
            g.addition(flatnessPenalty1d, neighborCorrPenalty1d, name: "s2"),
            name: "totalScore"
        )

        return (g, seeds, total)
    }
}
