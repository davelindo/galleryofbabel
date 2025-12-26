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

final class MPSScorer: GPUScorer {
    static let scorerVersion: Int = 3

    static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    typealias Job = GPUJob

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
        let inputPtr: UnsafeMutablePointer<UInt64>
        let inputTensorData: MPSGraphTensorData
        let outputBuffer: MTLBuffer
        let outputPtr: UnsafeMutablePointer<Float>
        let outputTensorData: MPSGraphTensorData
        let executionDescriptor: MPSGraphExecutableExecutionDescriptor
        let done: DispatchSemaphore
        private let lock = NSLock()
        private var lastError: Error? = nil

        init(
            inputBuffer: MTLBuffer,
            inputTensorData: MPSGraphTensorData,
            outputBuffer: MTLBuffer,
            outputTensorData: MPSGraphTensorData,
            batchSize: Int
        ) {
            self.inputBuffer = inputBuffer
            self.inputPtr = inputBuffer.contents().bindMemory(to: UInt64.self, capacity: batchSize)
            self.inputTensorData = inputTensorData
            self.outputBuffer = outputBuffer
            self.outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: batchSize)
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

        let proxyConfig = ProxyConfig.mpsDefault(imageSize: imageSize)
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: proxyConfig)
        let weightsURL = GobxPaths.proxyWeightsURL
        let (proxyWeights, _) = ProxyWeights.loadOrDefault(
            from: weightsURL,
            imageSize: imageSize,
            featureCount: featureCount,
            expectedConfig: proxyConfig
        )
        let (proxyBias, proxyWeightsF) = proxyWeights.asFloatWeights(expectedCount: featureCount)
        let (graph, seedPh, scoreT) = MPSScorer.buildGraph(
            batchSize: batchSize,
            imageSize: imageSize,
            proxyWeights: proxyWeightsF,
            proxyBias: proxyBias
        )
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
        let inputOptions: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        let outputOptions: MTLResourceOptions = [.storageModeShared]

        var slots: [Slot] = []
        slots.reserveCapacity(inflight)
        for idx in 0..<inflight {
            guard let inBuf = device.makeBuffer(length: inLen, options: inputOptions) else {
                throw MPSScorerError.bufferAllocationFailed(name: "input[\(idx)]", length: inLen)
            }
            let inTD = MPSGraphTensorData(inBuf, shape: [NSNumber(value: batchSize)], dataType: .uInt64)

            guard let outBuf = device.makeBuffer(length: outLen, options: outputOptions) else {
                throw MPSScorerError.bufferAllocationFailed(name: "output[\(idx)]", length: outLen)
            }
            let outTD = MPSGraphTensorData(outBuf, shape: outputShape, dataType: .float32)

            slots.append(Slot(
                inputBuffer: inBuf,
                inputTensorData: inTD,
                outputBuffer: outBuf,
                outputTensorData: outTD,
                batchSize: batchSize
            ))
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

        let inPtr = slot.inputPtr
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

        let seedsPtr = slot.inputPtr
        let outPtr = slot.outputPtr
        return try body(
            UnsafeBufferPointer(start: seedsPtr, count: job.count),
            UnsafeBufferPointer(start: outPtr, count: job.count)
        )
    }

    private static func buildGraph(
        batchSize: Int,
        imageSize: Int,
        proxyWeights: [Float],
        proxyBias: Float
    ) -> (MPSGraph, MPSGraphTensor, MPSGraphTensor) {
        let g = MPSGraph()

        let H = imageSize
        let W = imageSize
        let N = H * W
        let proxyConfig = ProxyConfig.mpsDefault(imageSize: imageSize)
        precondition(proxyWeights.count == WaveletProxy.featureCount(for: imageSize, config: proxyConfig), "proxyWeights feature count mismatch")
        let levelCount = WaveletProxy.levelCount(for: imageSize)
        let shapeLevels = WaveletProxy.shapeLevelIndices(levelCount: levelCount)
        let shapeLevelSet = Set(shapeLevels)

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

        // 2x2 pyramid variance proxy (Haar-style octave features)
        let poolDesc = MPSGraphPooling2DOpDescriptor()
        poolDesc.kernelWidth = 2
        poolDesc.kernelHeight = 2
        poolDesc.strideInX = 2
        poolDesc.strideInY = 2
        poolDesc.dilationRateInX = 1
        poolDesc.dilationRateInY = 1
        poolDesc.paddingStyle = .explicit
        poolDesc.paddingLeft = 0
        poolDesc.paddingRight = 0
        poolDesc.paddingTop = 0
        poolDesc.paddingBottom = 0
        poolDesc.dataLayout = .NHWC
        poolDesc.includeZeroPadToAverage = false

        let zero = g.constant(0.0, dataType: .float32)
        let eps = g.constant(ScoringConstants.eps, dataType: .float32)
        let one = g.constant(1.0, dataType: .float32)

        func toColumn(_ t: MPSGraphTensor, _ name: String) -> MPSGraphTensor {
            g.reshape(t, shape: [NSNumber(value: batchSize), 1], name: name)
        }

        var current = data
        var currentSize = H
        var level = 0
        var energies: [MPSGraphTensor] = []
        energies.reserveCapacity(levelCount)
        var maxes = [MPSGraphTensor?](repeating: nil, count: levelCount)
        var e2s = [MPSGraphTensor?](repeating: nil, count: levelCount)

        while currentSize >= 2 {
            let x2 = g.multiplication(current, current, name: "x2_l\(level)")
            let shape4 = [NSNumber(value: batchSize), NSNumber(value: currentSize), NSNumber(value: currentSize), 1]
            let shape3 = [NSNumber(value: batchSize), NSNumber(value: currentSize / 2), NSNumber(value: currentSize / 2)]

            let x4 = g.reshape(current, shape: shape4, name: "x4_l\(level)")
            let x2_4 = g.reshape(x2, shape: shape4, name: "x2_4_l\(level)")
            let m4 = g.avgPooling2D(withSourceTensor: x4, descriptor: poolDesc, name: "m4_l\(level)")
            let m2_4 = g.avgPooling2D(withSourceTensor: x2_4, descriptor: poolDesc, name: "m2_4_l\(level)")

            let m = g.reshape(m4, shape: shape3, name: "m_l\(level)")
            let m2 = g.reshape(m2_4, shape: shape3, name: "m2_l\(level)")
            let varRaw = g.subtraction(m2, g.multiplication(m, m, name: nil), name: "var_l\(level)")
            let varClamped = g.maximum(varRaw, zero, name: "varc_l\(level)")

            let ek = g.mean(of: varClamped, axes: [1, 2] as [NSNumber], name: "Ek_l\(level)")
            energies.append(toColumn(ek, "Ek1d_l\(level)"))
            if shapeLevelSet.contains(level) {
                let mk = g.reductionMaximum(with: varClamped, axes: [1, 2] as [NSNumber], name: "Mk_l\(level)")
                let e2k = g.mean(of: g.multiplication(varClamped, varClamped, name: nil), axes: [1, 2] as [NSNumber], name: "E2k_l\(level)")
                maxes[level] = toColumn(mk, "Mk1d_l\(level)")
                e2s[level] = toColumn(e2k, "E2k1d_l\(level)")
            }

            current = m
            currentSize /= 2
            level += 1
        }

        var featureCols: [MPSGraphTensor] = []
        featureCols.append(contentsOf: energies)

        if energies.count > 1 {
            for i in 0..<(energies.count - 1) {
                let denom = g.addition(energies[i + 1], eps, name: "Rden_l\(i)")
                let ratio = g.division(energies[i], denom, name: "R_l\(i)")
                featureCols.append(ratio)
            }
        }

        for idx in shapeLevels {
            let mk = maxes[idx]!
            let denom = g.addition(energies[idx], eps, name: "Pden_l\(idx)")
            let peak = g.division(mk, denom, name: "Peak_l\(idx)")
            featureCols.append(peak)
        }

        for idx in shapeLevels {
            let e2k = e2s[idx]!
            let denom = g.addition(g.multiplication(energies[idx], energies[idx], name: nil), eps, name: "Cvden_l\(idx)")
            let cv2 = g.subtraction(g.division(e2k, denom, name: nil), one, name: "Cv2_l\(idx)")
            featureCols.append(cv2)
        }

        let features = g.concatTensors(featureCols, dimension: 1, name: "features")
        let featureCount = WaveletProxy.featureCount(for: imageSize, config: proxyConfig)
        precondition(featureCols.count == featureCount, "feature column count mismatch")
        let weightsData = proxyWeights.withUnsafeBytes { Data($0) }
        let weights = g.constant(weightsData, shape: [NSNumber(value: featureCount)], dataType: .float32)
        let weights2 = g.reshape(weights, shape: [1, NSNumber(value: featureCount)], name: "weights2")
        let weightsB = g.broadcast(weights2, shape: [NSNumber(value: batchSize), NSNumber(value: featureCount)], name: "weightsB")
        let weighted = g.multiplication(features, weightsB, name: "weighted")
        let proxySum = g.reductionSum(with: weighted, axes: [1] as [NSNumber], name: "proxySum")
        let proxyScore = g.addition(proxySum, g.constant(Double(proxyBias), dataType: .float32), name: "proxyScore")

        let proxyScore1d = g.reshape(proxyScore, shape: [NSNumber(value: batchSize)], name: "proxyScore1d")
        let neighborCorrPenalty1d = g.reshape(neighborCorrPenalty, shape: [NSNumber(value: batchSize)], name: "neighborCorrPenalty1d")

        let total = g.addition(proxyScore1d, neighborCorrPenalty1d, name: "totalScore")

        return (g, seeds, total)
    }
}
