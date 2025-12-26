import Foundation
import Metal

struct GPUTuningHint {
    let batch: Int
    let inflight: Int
    let batchMin: Int
    let batchMax: Int
    let inflightMin: Int
    let inflightMax: Int
    let source: String
}

private struct GPUTuningKey: Codable, Equatable {
    let schemaVersion: Int
    let gpuBackend: String
    let gpuScorerVersion: Int
    let hwModel: String?
    let gpuName: String
    let gpuRegistryID: UInt64
}

private struct GPUTuningRecord: Codable {
    let key: GPUTuningKey
    let updatedAt: Date
    let batch: Int
    let inflight: Int
}

private struct GPUTuningStore: Codable {
    let schemaVersion: Int
    let entries: [GPUTuningRecord]
}

enum GPUTuning {
    private static let schemaVersion = 1

    static func hint(gpuBackend: GPUBackend) -> GPUTuningHint? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        if let record = loadRecord(gpuBackend: gpuBackend, device: device) {
            return makeHint(
                batch: record.batch,
                inflight: record.inflight,
                source: "cached",
                batchRange: (0.85, 1.15),
                inflightSpan: 1
            )
        }
        if let fallback = defaultFallback(for: device.name) {
            return makeHint(
                batch: fallback.batch,
                inflight: fallback.inflight,
                source: "fallback",
                batchRange: (0.6, 1.6),
                inflightSpan: 2
            )
        }
        return nil
    }

    static func save(batch: Int, inflight: Int, gpuBackend: GPUBackend) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        guard batch > 0, inflight > 0 else { return }
        guard let key = currentKey(gpuBackend: gpuBackend, device: device) else { return }

        let url = GobxPaths.gpuTuningURL
        let existing = CalibrationSupport.loadJSON(GPUTuningStore.self, from: url)
        var entries = existing?.entries ?? []

        let record = GPUTuningRecord(
            key: key,
            updatedAt: Date(),
            batch: batch,
            inflight: inflight
        )

        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries[idx] = record
        } else {
            entries.append(record)
        }

        let store = GPUTuningStore(schemaVersion: schemaVersion, entries: entries)
        try? CalibrationSupport.saveJSON(store, to: url)
    }

    private static func loadRecord(gpuBackend: GPUBackend, device: MTLDevice) -> GPUTuningRecord? {
        guard let key = currentKey(gpuBackend: gpuBackend, device: device) else { return nil }
        guard let store = CalibrationSupport.loadJSON(GPUTuningStore.self, from: GobxPaths.gpuTuningURL) else {
            return nil
        }
        return store.entries.first(where: { $0.key == key })
    }

    private static func currentKey(gpuBackend: GPUBackend, device: MTLDevice) -> GPUTuningKey? {
        let hwModel = CalibrationSupport.sysctlString("hw.model")
        let scorerVersion: Int = {
            switch gpuBackend {
            case .metal:
                return MetalPyramidScorer.scorerVersion
            case .mps:
                return MPSScorer.scorerVersion
            }
        }()
        return GPUTuningKey(
            schemaVersion: schemaVersion,
            gpuBackend: gpuBackend.rawValue,
            gpuScorerVersion: scorerVersion,
            hwModel: hwModel,
            gpuName: device.name,
            gpuRegistryID: device.registryID
        )
    }

    private static func defaultFallback(for deviceName: String) -> (batch: Int, inflight: Int)? {
        let name = deviceName.uppercased()
        if name.contains("M5") { return (batch: 320, inflight: 2) }
        if name.contains("M4") { return (batch: 320, inflight: 2) }
        if name.contains("M3") { return (batch: 320, inflight: 2) }
        if name.contains("M2") { return (batch: 256, inflight: 2) }
        if name.contains("M1") { return (batch: 256, inflight: 2) }
        return nil
    }

    private static func makeHint(
        batch: Int,
        inflight: Int,
        source: String,
        batchRange: (Double, Double),
        inflightSpan: Int
    ) -> GPUTuningHint {
        let clampedBatch = max(1, batch)
        let low = max(1, Int(Double(clampedBatch) * batchRange.0))
        let high = max(low, Int(Double(clampedBatch) * batchRange.1))
        let batchMin = max(1, min(4096, low))
        let batchMax = max(batchMin, min(4096, high))
        let inflightMin = max(1, inflight - max(0, inflightSpan))
        let inflightMax = max(inflightMin, inflight + max(0, inflightSpan))
        return GPUTuningHint(
            batch: clampedBatch,
            inflight: max(1, inflight),
            batchMin: batchMin,
            batchMax: batchMax,
            inflightMin: inflightMin,
            inflightMax: inflightMax,
            source: source
        )
    }
}
