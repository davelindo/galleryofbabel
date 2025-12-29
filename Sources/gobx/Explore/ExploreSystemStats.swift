import Dispatch
import Foundation
import Metal

public final class ExploreSystemStats: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let processResidentBytes: UInt64?
        public let processFootprintBytes: UInt64?
        public let gpuAllocatedBytes: UInt64?
        public let gpuWorkingSetBytes: UInt64?
        public let gpuUtilPercent: Double?
        public let gpuPowerWatts: Double?
        public let gpuUtilAvailable: Bool

        public init(
            processResidentBytes: UInt64?,
            processFootprintBytes: UInt64?,
            gpuAllocatedBytes: UInt64?,
            gpuWorkingSetBytes: UInt64?,
            gpuUtilPercent: Double?,
            gpuPowerWatts: Double?,
            gpuUtilAvailable: Bool
        ) {
            self.processResidentBytes = processResidentBytes
            self.processFootprintBytes = processFootprintBytes
            self.gpuAllocatedBytes = gpuAllocatedBytes
            self.gpuWorkingSetBytes = gpuWorkingSetBytes
            self.gpuUtilPercent = gpuUtilPercent
            self.gpuPowerWatts = gpuPowerWatts
            self.gpuUtilAvailable = gpuUtilAvailable
        }
    }

    private let gpuDevice: MTLDevice?
    private let gpuUtilMonitor: GPUUtilMonitor?
    private var started = false

    public init(enableGpuUtil: Bool = true) {
        let device = MTLCreateSystemDefaultDevice()
        self.gpuDevice = device
        if enableGpuUtil {
            let monitor = GPUUtilMonitor()
            self.gpuUtilMonitor = monitor.isAvailable ? monitor : nil
        } else {
            self.gpuUtilMonitor = nil
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        gpuUtilMonitor?.start()
    }

    public func stop() {
        started = false
        gpuUtilMonitor?.stop()
    }

    public func snapshot() -> Snapshot {
        let mem = ProcessMemory.snapshot()
        let gpuAllocated = gpuDevice?.currentAllocatedSize
        let gpuWorkingSet = gpuDevice?.recommendedMaxWorkingSetSize
        let gpuAllocatedBytes = gpuAllocated.map { UInt64($0) }
        let gpuWorkingSetBytes = gpuWorkingSet.map { UInt64($0) }
        let gpuUtil = gpuUtilMonitor?.snapshot()
        return Snapshot(
            processResidentBytes: mem?.residentBytes,
            processFootprintBytes: mem?.physFootprintBytes,
            gpuAllocatedBytes: gpuAllocatedBytes,
            gpuWorkingSetBytes: gpuWorkingSetBytes,
            gpuUtilPercent: gpuUtil?.value,
            gpuPowerWatts: gpuUtil?.powerWatts,
            gpuUtilAvailable: gpuUtil?.available ?? false
        )
    }
}

private final class GPUUtilMonitor: @unchecked Sendable {
    struct Snapshot {
        let value: Double?
        let powerWatts: Double?
        let available: Bool
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "gobx.gpuutil", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var latestValue: Double? = nil
    private var latestPowerWatts: Double? = nil
    private var available: Bool
    private var isSampling = false

    private let intervalSec: Double
    private let sampleDurationSec: Double
    private let sampleIntervalMs: Int

    init(intervalSec: Double = 5.0, sampleDurationSec: Double = 1.0, sampleIntervalMs: Int = 250) {
        self.intervalSec = max(1.0, intervalSec)
        self.sampleDurationSec = max(0.2, sampleDurationSec)
        self.sampleIntervalMs = max(100, sampleIntervalMs)
        let exe = "/usr/bin/powermetrics"
        self.available = FileManager.default.isExecutableFile(atPath: exe)
    }

    var isAvailable: Bool {
        lock.withLock { available }
    }

    func start() {
        guard isAvailable else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: intervalSec, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.sampleOnce()
        }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(value: latestValue, powerWatts: latestPowerWatts, available: available)
        }
    }

    private func sampleOnce() {
        lock.lock()
        if isSampling || !available {
            lock.unlock()
            return
        }
        isSampling = true
        lock.unlock()

        let stats = Self.sampleGPUStats(durationSec: sampleDurationSec, intervalMs: sampleIntervalMs)

        lock.lock()
        if let value = stats.utilPercent {
            latestValue = value
        }
        if let watts = stats.powerWatts {
            latestPowerWatts = watts
        }
        if stats.utilPercent == nil && stats.powerWatts == nil {
            available = false
            latestValue = nil
            latestPowerWatts = nil
            timer?.cancel()
            timer = nil
        }
        isSampling = false
        lock.unlock()
    }

    private static func sampleGPUStats(durationSec: Double, intervalMs: Int) -> (utilPercent: Double?, powerWatts: Double?) {
        let exe = "/usr/bin/powermetrics"
        guard FileManager.default.isExecutableFile(atPath: exe) else { return (nil, nil) }

        let sampleCount = max(1, Int(ceil(durationSec * 1000.0 / Double(intervalMs))))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["--samplers", "gpu_power", "-i", String(intervalMs), "-n", String(sampleCount)]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return (nil, nil)
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let output = outStr + "\n" + errStr

        let samples = parseActiveResidency(from: output)
        let powerSamples = parsePowerWatts(from: output)
        let utilAvg = samples.isEmpty ? nil : samples.reduce(0.0, +) / Double(samples.count)
        let powerAvg = powerSamples.isEmpty ? nil : powerSamples.reduce(0.0, +) / Double(powerSamples.count)
        return (utilAvg, powerAvg)
    }

    private static func parseActiveResidency(from output: String) -> [Double] {
        var values: [Double] = []
        let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#, options: [])
        var idleValues: [Double] = []
        for lineSub in output.split(separator: "\n") {
            let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            guard lower.contains("gpu") else { continue }
            let isActive = lower.contains("active residency") || lower.contains("gpu active") || lower.contains("gpu busy") || lower.contains("utilization")
            let isIdle = lower.contains("idle residency") || lower.contains("gpu idle")
            guard isActive || isIdle else { continue }
            if let regex {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, options: [], range: range),
                   let numRange = Range(match.range(at: 1), in: line),
                   let v = Double(line[numRange]) {
                    if isActive {
                        values.append(v)
                    } else {
                        idleValues.append(v)
                    }
                    continue
                }
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for part in parts {
                guard part.contains("%") else { continue }
                let token = part.trimmingCharacters(in: CharacterSet(charactersIn: "%,;:()[]"))
                if let v = Double(token) {
                    if isActive {
                        values.append(v)
                    } else {
                        idleValues.append(v)
                    }
                    break
                }
            }
        }
        if !values.isEmpty { return values }
        if !idleValues.isEmpty {
            return idleValues.map { max(0.0, min(100.0, 100.0 - $0)) }
        }
        return []
    }

    private static func parsePowerWatts(from output: String) -> [Double] {
        var values: [Double] = []
        let regex = try? NSRegularExpression(
            pattern: #"gpu power[^0-9]*([0-9]+(?:\.[0-9]+)?)\s*([mµu]?w)"#,
            options: [.caseInsensitive]
        )
        for lineSub in output.split(separator: "\n") {
            let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            guard lower.contains("gpu") && lower.contains("power") else { continue }
            if let regex {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, options: [], range: range),
                   let numRange = Range(match.range(at: 1), in: line),
                   let unitRange = Range(match.range(at: 2), in: line),
                   let v = Double(line[numRange]) {
                    let unit = line[unitRange].lowercased()
                    let watts: Double
                    if unit.hasPrefix("m") {
                        watts = v / 1000.0
                    } else if unit.hasPrefix("u") || unit.hasPrefix("µ") {
                        watts = v / 1_000_000.0
                    } else {
                        watts = v
                    }
                    values.append(watts)
                }
            }
        }
        return values
    }
}
