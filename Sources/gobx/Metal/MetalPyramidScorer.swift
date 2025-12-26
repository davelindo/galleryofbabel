import Dispatch
import Foundation
import Metal

enum MetalPyramidScorerError: Error, CustomStringConvertible {
    case noMetalDevice
    case noCommandQueue
    case invalidBatchSize(Int)
    case invalidImageSize(Int)
    case invalidInflight(Int)
    case invalidThreadgroupSize(Int)
    case pipelineNotFound
    case sourceLoadFailed
    case libraryCompileFailed(String)
    case pipelineInitFailed
    case threadgroupSizeUnsupported(Int)
    case bufferAllocationFailed(name: String, length: Int)

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
        case .invalidThreadgroupSize(let n):
            return "Invalid threadgroup size: \(n)"
        case .pipelineNotFound:
            return "Failed to load pyramid_proxy Metal function"
        case .sourceLoadFailed:
            return "Failed to load PyramidProxy.metal source"
        case .libraryCompileFailed(let message):
            return "Failed to compile PyramidProxy.metal: \(message)"
        case .pipelineInitFailed:
            return "Failed to create Metal compute pipeline"
        case .threadgroupSizeUnsupported(let n):
            return "Unsupported threadgroup size: \(n)"
        case .bufferAllocationFailed(let name, let length):
            return "Failed to allocate Metal buffer '\(name)' (\(length) bytes)"
        }
    }
}

final class MetalPyramidScorer: GPUScorer {
    static let scorerVersion: Int = 4
    static let defaultThreadgroupSize: Int = 192
    static let simdWidth: Int = 32
    static let maxSimdGroups: Int = 8
    static let maxThreadgroupSize: Int = simdWidth * maxSimdGroups

    static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    typealias Job = GPUJob

    let batchSize: Int
    let imageSize: Int
    let inflight: Int
    let threadgroupSize: Int

    var captureCommandQueue: MTLCommandQueue { commandQueue }

    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let commandBufferDescriptor: MTLCommandBufferDescriptor
    private let pipeline: MTLComputePipelineState
    private let weightsBuffer: MTLBuffer
    private let weightCount: Int
    private let levelCount: Int
    private let bias: Float
    private let eps: Float
    private let includeNeighborCorr: Bool
    private let dispatchesPerCommandBuffer: Int

    private var scoreBuffer: [Float]
    private let batchLock = NSLock()
    private var pendingBatch: CommandBatch? = nil

    private struct ProxyParams {
        var count: UInt32
        var levelCount: UInt32
        var weightCount: UInt32
        var includeNeighborCorr: UInt32
        var bias: Float
        var eps: Float
    }

    private final class Slot: @unchecked Sendable {
        let inputBuffer: MTLBuffer
        let inputPtr: UnsafeMutablePointer<UInt64>
        let outputBuffer: MTLBuffer
        let outputPtr: UnsafeMutablePointer<Float>
        let paramsBuffer: MTLBuffer
        let paramsPtr: UnsafeMutablePointer<ProxyParams>
        let done: DispatchSemaphore
        private let lock = NSLock()
        private var lastError: Error? = nil

        init(inputBuffer: MTLBuffer, outputBuffer: MTLBuffer, paramsBuffer: MTLBuffer, batchSize: Int) {
            self.inputBuffer = inputBuffer
            self.inputPtr = inputBuffer.contents().bindMemory(to: UInt64.self, capacity: batchSize)
            self.outputBuffer = outputBuffer
            self.outputPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: batchSize)
            self.paramsBuffer = paramsBuffer
            self.paramsPtr = paramsBuffer.contents().bindMemory(to: ProxyParams.self, capacity: 1)
            self.done = DispatchSemaphore(value: 0)
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

        func setError(_ error: Error?) {
            lock.lock()
            lastError = error
            lock.unlock()
        }
    }

    private let slots: [Slot]
    private var enqueueCursor: Int = 0

    private final class CommandBatch {
        let commandBuffer: MTLCommandBuffer
        let encoder: MTLComputeCommandEncoder
        var slots: [Int]
        var count: Int = 0

        init(commandBuffer: MTLCommandBuffer, encoder: MTLComputeCommandEncoder, capacity: Int) {
            self.commandBuffer = commandBuffer
            self.encoder = encoder
            self.slots = []
            self.slots.reserveCapacity(capacity)
        }
    }

    init(
        batchSize: Int,
        imageSize: Int = 128,
        inflight: Int = 1,
        threadgroupSize: Int = MetalPyramidScorer.defaultThreadgroupSize,
        commandBufferDispatches: Int = 0
    ) throws {
        guard batchSize > 0 else { throw MetalPyramidScorerError.invalidBatchSize(batchSize) }
        self.batchSize = batchSize
        guard imageSize == 128 else { throw MetalPyramidScorerError.invalidImageSize(imageSize) }
        self.imageSize = imageSize
        guard inflight > 0 else { throw MetalPyramidScorerError.invalidInflight(inflight) }
        self.inflight = inflight
        guard threadgroupSize > 0,
              threadgroupSize % MetalPyramidScorer.simdWidth == 0,
              threadgroupSize <= MetalPyramidScorer.maxThreadgroupSize else {
            throw MetalPyramidScorerError.invalidThreadgroupSize(threadgroupSize)
        }
        self.threadgroupSize = threadgroupSize
        let dispatches = commandBufferDispatches > 0 ? commandBufferDispatches : 1
        self.dispatchesPerCommandBuffer = max(1, min(dispatches, inflight))

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalPyramidScorerError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalPyramidScorerError.noCommandQueue
        }
        self.metalDevice = device
        self.commandQueue = queue
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.retainedReferences = false
        self.commandBufferDescriptor = descriptor

        guard let url = Bundle.module.url(forResource: "PyramidProxy", withExtension: "metal") else {
            throw MetalPyramidScorerError.sourceLoadFailed
        }
        let source: String
        do {
            source = try String(contentsOf: url)
        } catch {
            throw MetalPyramidScorerError.sourceLoadFailed
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalPyramidScorerError.libraryCompileFailed(String(describing: error))
        }
        let constants = MTLFunctionConstantValues()
        var tgValue = UInt32(threadgroupSize)
        constants.setConstantValue(&tgValue, type: .uint, index: 0)
        let function: MTLFunction
        do {
            function = try library.makeFunction(name: "pyramid_proxy", constantValues: constants)
        } catch {
            throw MetalPyramidScorerError.libraryCompileFailed(String(describing: error))
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalPyramidScorerError.pipelineInitFailed
        }
        guard threadgroupSize <= pipeline.maxTotalThreadsPerThreadgroup else {
            throw MetalPyramidScorerError.threadgroupSizeUnsupported(pipeline.maxTotalThreadsPerThreadgroup)
        }

        let proxyConfig = ProxyConfig.metalDefault(imageSize: imageSize)
        let levels = WaveletProxy.levelCount(for: imageSize, maxLevels: proxyConfig.maxLevels)
        self.levelCount = levels
        self.eps = Float(ScoringConstants.eps)
        precondition(!proxyConfig.includeNeighborPenalty, "Metal proxy does not implement neighbor correlation penalty")
        self.includeNeighborCorr = proxyConfig.includeNeighborCorrFeature

        let featureCount = WaveletProxy.featureCount(for: imageSize, config: proxyConfig)
        let weightsURL = GobxPaths.metalProxyWeightsURL
        let (proxyWeights, _) = ProxyWeights.loadOrDefault(
            from: weightsURL,
            imageSize: imageSize,
            featureCount: featureCount,
            expectedConfig: proxyConfig
        )
        self.weightCount = featureCount
        let (bias, weightsF) = proxyWeights.asFloatWeights(expectedCount: featureCount)
        self.bias = bias

        let weightBytes = weightsF.count * MemoryLayout<Float>.stride
        guard let weightsShared = device.makeBuffer(bytes: weightsF, length: weightBytes, options: .storageModeShared) else {
            throw MetalPyramidScorerError.bufferAllocationFailed(name: "weights", length: weightBytes)
        }
        if let weightsPrivate = device.makeBuffer(length: weightBytes, options: .storageModePrivate),
           let commandBuffer = queue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: weightsShared, sourceOffset: 0, to: weightsPrivate, destinationOffset: 0, size: weightBytes)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.error == nil {
                self.weightsBuffer = weightsPrivate
            } else {
                self.weightsBuffer = weightsShared
            }
        } else {
            self.weightsBuffer = weightsShared
        }

        let inLen = batchSize * MemoryLayout<UInt64>.stride
        let outLen = batchSize * MemoryLayout<Float>.stride
        let paramsLen = MemoryLayout<ProxyParams>.stride
        let inputOptions: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        let outputOptions: MTLResourceOptions = [.storageModeShared]
        let paramsOptions: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]

        var slots: [Slot] = []
        slots.reserveCapacity(inflight)
        for idx in 0..<inflight {
            guard let inBuf = device.makeBuffer(length: inLen, options: inputOptions) else {
                throw MetalPyramidScorerError.bufferAllocationFailed(name: "input[\(idx)]", length: inLen)
            }
            guard let outBuf = device.makeBuffer(length: outLen, options: outputOptions) else {
                throw MetalPyramidScorerError.bufferAllocationFailed(name: "output[\(idx)]", length: outLen)
            }
            guard let paramsBuf = device.makeBuffer(length: paramsLen, options: paramsOptions) else {
                throw MetalPyramidScorerError.bufferAllocationFailed(name: "params[\(idx)]", length: paramsLen)
            }
            slots.append(Slot(inputBuffer: inBuf, outputBuffer: outBuf, paramsBuffer: paramsBuf, batchSize: batchSize))
        }
        self.slots = slots
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
                fatalError("MetalPyramidScorer run failed: \(error)")
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

        let params = ProxyParams(
            count: UInt32(count),
            levelCount: UInt32(levelCount),
            weightCount: UInt32(weightCount),
            includeNeighborCorr: includeNeighborCorr ? 1 : 0,
            bias: bias,
            eps: eps
        )
        slot.paramsPtr.pointee = params

        let job = Job(slotIndex: slotIndex, count: count)
        var batchToFinalize: CommandBatch? = nil
        batchLock.lock()
        if pendingBatch == nil {
            let commandBuffer = commandQueue.makeCommandBuffer(descriptor: commandBufferDescriptor)
                ?? commandQueue.makeCommandBuffer()
            guard let commandBuffer else {
                batchLock.unlock()
                slot.setError(MetalPyramidScorerError.noCommandQueue)
                slot.done.signal()
                return job
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                batchLock.unlock()
                slot.setError(MetalPyramidScorerError.pipelineInitFailed)
                slot.done.signal()
                return job
            }
            encoder.setComputePipelineState(pipeline)
            pendingBatch = CommandBatch(
                commandBuffer: commandBuffer,
                encoder: encoder,
                capacity: dispatchesPerCommandBuffer
            )
        }
        if let batch = pendingBatch {
            batch.encoder.setBuffer(slot.inputBuffer, offset: 0, index: 0)
            batch.encoder.setBuffer(weightsBuffer, offset: 0, index: 1)
            batch.encoder.setBuffer(slot.paramsBuffer, offset: 0, index: 2)
            batch.encoder.setBuffer(slot.outputBuffer, offset: 0, index: 3)

            let tgSize = MTLSize(width: threadgroupSize, height: 1, depth: 1)
            let tgCount = MTLSize(width: batchSize, height: 1, depth: 1)
            batch.encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

            batch.slots.append(slotIndex)
            batch.count += 1
            if batch.count >= dispatchesPerCommandBuffer {
                pendingBatch = nil
                batchToFinalize = batch
            }
        }
        batchLock.unlock()
        if let batchToFinalize {
            finalizeBatch(batchToFinalize)
        }

        return job
    }

    func withCompletedJob<T>(_ job: Job, _ body: (UnsafeBufferPointer<UInt64>, UnsafeBufferPointer<Float>) throws -> T) throws -> T {
        precondition(job.count >= 0 && job.count <= batchSize)
        flushPendingBatch()
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

    private func flushPendingBatch() {
        var batch: CommandBatch? = nil
        batchLock.lock()
        if let pending = pendingBatch {
            pendingBatch = nil
            batch = pending
        }
        batchLock.unlock()
        if let batch {
            finalizeBatch(batch)
        }
    }

    private func finalizeBatch(_ batch: CommandBatch) {
        batch.encoder.endEncoding()
        let slotIndices = batch.slots
        let slots = self.slots
        batch.commandBuffer.addCompletedHandler { buffer in
            for idx in slotIndices {
                let slot = slots[idx]
                slot.setError(buffer.error)
                slot.done.signal()
            }
        }
        batch.commandBuffer.commit()
    }
}
