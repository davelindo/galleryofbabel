import Foundation
import Metal

enum StatsCollector {
    static let schemaVersion = 1
    static let defaultURL = "https://gobx-stats.davelindon.me/ingest"
    private static let uploader = StatsUploadQueue()

    struct Payload: Codable {
        let schemaVersion: Int
        let runId: String
        let deviceId: String
        let hwModel: String?
        let gpuName: String?
        let gpuBackend: String?
        let backend: String
        let osVersion: String
        let appVersion: String
        let batch: Int?
        let inflight: Int?
        let batchMin: Int?
        let batchMax: Int?
        let inflightMin: Int?
        let inflightMax: Int?
        let autoBatch: Bool
        let autoInflight: Bool
        let elapsedSec: Double
        let totalCount: UInt64
        let totalRate: Double
        let cpuRate: Double
        let gpuRate: Double
        let cpuAvg: Double
        let gpuAvg: Double
    }

    struct Metrics {
        let backend: Backend
        let gpuBackend: GPUBackend
        let batch: Int?
        let inflight: Int?
        let batchMin: Int?
        let batchMax: Int?
        let inflightMin: Int?
        let inflightMax: Int?
        let autoBatch: Bool
        let autoInflight: Bool
        let elapsedSec: Double
        let totalCount: UInt64
        let totalRate: Double
        let cpuRate: Double
        let gpuRate: Double
        let cpuAvg: Double
        let gpuAvg: Double
    }

    static func makePayload(metrics: Metrics, runId: String? = nil) -> Payload? {
        guard let device = deviceInfo() else { return nil }
        let resolvedRunId = runId ?? UUID().uuidString
        return Payload(
            schemaVersion: schemaVersion,
            runId: resolvedRunId,
            deviceId: device.deviceId,
            hwModel: device.hwModel,
            gpuName: device.gpuName,
            gpuBackend: metrics.backend == .cpu ? nil : metrics.gpuBackend.rawValue,
            backend: metrics.backend.rawValue,
            osVersion: device.osVersion,
            appVersion: BuildInfo.versionHash,
            batch: metrics.batch,
            inflight: metrics.inflight,
            batchMin: metrics.batchMin,
            batchMax: metrics.batchMax,
            inflightMin: metrics.inflightMin,
            inflightMax: metrics.inflightMax,
            autoBatch: metrics.autoBatch,
            autoInflight: metrics.autoInflight,
            elapsedSec: metrics.elapsedSec,
            totalCount: metrics.totalCount,
            totalRate: metrics.totalRate,
            cpuRate: metrics.cpuRate,
            gpuRate: metrics.gpuRate,
            cpuAvg: metrics.cpuAvg,
            gpuAvg: metrics.gpuAvg
        )
    }

    static func send(payload: Payload, url rawURL: String, timeoutSec: TimeInterval = 5.0) async -> Bool {
        guard let url = normalizeURL(rawURL) else { return false }
        guard let body = try? JSONEncoder().encode(payload) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1.0, timeoutSec)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(BuildInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = max(1.0, timeoutSec)
        config.timeoutIntervalForResource = max(1.0, timeoutSec)

        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static func enqueue(payload: Payload, url: String) {
        Task.detached(priority: .utility) {
            await uploader.enqueue(payload: payload, url: url)
        }
    }

    private actor StatsUploadQueue {
        struct Item {
            let payload: Payload
            let url: String
            var attempts: Int
        }

        private var queue: [Item] = []
        private var isSending = false
        private let maxQueueDepth = 4
        private let maxAttempts = 3
        private let retryDelaysNs: [UInt64] = [
            2_000_000_000,
            5_000_000_000,
            10_000_000_000,
        ]

        func enqueue(payload: Payload, url: String) async {
            if queue.count >= maxQueueDepth {
                queue.removeFirst(queue.count - maxQueueDepth + 1)
            }
            queue.append(Item(payload: payload, url: url, attempts: 0))

            guard !isSending else { return }
            isSending = true
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.processQueue()
            }
        }

        private func processQueue() async {
            while true {
                guard var item = queue.first else {
                    isSending = false
                    return
                }
                queue.removeFirst()

                var sent = false
                while item.attempts < maxAttempts {
                    item.attempts += 1
                    let ok = await StatsCollector.send(payload: item.payload, url: item.url, timeoutSec: 2.5)
                    if ok {
                        sent = true
                        break
                    }
                    let delayIdx = min(item.attempts - 1, retryDelaysNs.count - 1)
                    try? await Task.sleep(nanoseconds: retryDelaysNs[delayIdx])
                }

                if !sent {
                    // drop on repeated failure
                }
            }
        }
    }

    private struct DeviceInfo {
        let deviceId: String
        let hwModel: String?
        let gpuName: String?
        let osVersion: String
    }

    private struct DeviceKey: Codable {
        let schemaVersion: Int
        let hwModel: String?
        let gpuName: String?
        let gpuRegistryID: UInt64
        let arch: String
    }

    private static func deviceInfo() -> DeviceInfo? {
        let hwModel = CalibrationSupport.sysctlString("hw.model")
        let arch = CalibrationSupport.archString()
        let device = MTLCreateSystemDefaultDevice()
        let gpuName = device?.name
        let gpuRegistryID = device?.registryID ?? 0
        let key = DeviceKey(
            schemaVersion: schemaVersion,
            hwModel: hwModel,
            gpuName: gpuName,
            gpuRegistryID: gpuRegistryID,
            arch: arch
        )
        guard let deviceId = try? CalibrationSupport.hardwareHash(for: key) else { return nil }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return DeviceInfo(
            deviceId: deviceId,
            hwModel: hwModel,
            gpuName: gpuName,
            osVersion: osVersion
        )
    }

    private static func normalizeURL(_ raw: String) -> URL? {
        let candidate: String = {
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return raw
            }
            return "https://\(raw)"
        }()
        guard let url = URL(string: candidate) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.appendingPathComponent("ingest")
        }
        return url
    }
}
