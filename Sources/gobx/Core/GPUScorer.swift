import Foundation

struct GPUJob {
    let slotIndex: Int
    let count: Int
}

protocol GPUScorer: AnyObject {
    var batchSize: Int { get }
    func enqueue(seeds: UnsafeBufferPointer<UInt64>, count: Int) -> GPUJob
    func withCompletedJob<T>(_ job: GPUJob, _ body: (UnsafeBufferPointer<UInt64>, UnsafeBufferPointer<Float>) throws -> T) throws -> T
}
