import Foundation
@preconcurrency import Darwin
@preconcurrency import IOKit

public struct SystemPowerSnapshot: Sendable {
    public let available: Bool
    public let systemInWatts: Double?
    public let systemLoadWatts: Double?
    public let batteryPowerWatts: Double?
    public let adapterPowerWatts: Double?
    public let efficiencyLossWatts: Double?
    public let screenPowerWatts: Double?
    public let heatpipePowerWatts: Double?
    public let adapterWatts: Double?
    public let adapterVoltage: Double?
    public let adapterAmperage: Double?
    public let batteryLevelPercent: Int?
    public let isCharging: Bool?
    public let temperatureC: Double?

    public static let empty = SystemPowerSnapshot(
        available: false,
        systemInWatts: nil,
        systemLoadWatts: nil,
        batteryPowerWatts: nil,
        adapterPowerWatts: nil,
        efficiencyLossWatts: nil,
        screenPowerWatts: nil,
        heatpipePowerWatts: nil,
        adapterWatts: nil,
        adapterVoltage: nil,
        adapterAmperage: nil,
        batteryLevelPercent: nil,
        isCharging: nil,
        temperatureC: nil
    )
}

final class SystemPowerReader: @unchecked Sendable {
    private let ioReader = IORegistryReader()
    private let smcReader = SMCReader()
    private let lock = NSLock()
    private var lastTempC: Double?
    private var lastTempStamp: TimeInterval = 0
    private let tempHoldSeconds: TimeInterval = 30
    private let minTempC: Double = 20
    private let maxTempC: Double = 110

    func snapshot() -> SystemPowerSnapshot {
        lock.withLock {
            let batteryInfo = ioReader.readBatteryInfo()
            let smcResult = smcReader.readPowerData()
            let smc = smcResult.data
            let smcPowerAvailable = smcResult.powerAvailable
            let telemetry = batteryInfo?.powerTelemetry
            let efficiencyLoss = telemetry.map { Double($0.adapterEfficiencyLoss) / 1000.0 }

            let telemetrySystemIn = telemetry.map { Double($0.systemPowerIn) / 1000.0 }
            let telemetrySystemLoad = telemetry.map { Double($0.systemLoad) / 1000.0 }
            let telemetryBattery = telemetry.map { Double($0.batteryPower) / 1000.0 }

            let systemIn = smcResult.didReadDelivery ? smc.deliveryRate : telemetrySystemIn
            let systemLoad = smcResult.didReadSystemTotal ? smc.systemTotal : telemetrySystemLoad
            let batteryPower: Double? = {
                if smcResult.didReadBatteryRate {
                    if smcResult.didReadDelivery && smcResult.didReadSystemTotal {
                        return max(smc.batteryRate, smc.deliveryRate - smc.systemTotal)
                    }
                    return smc.batteryRate
                }
                return telemetryBattery
            }()

            let adapterPower = systemIn.map { $0 + (efficiencyLoss ?? 0.0) }

            let tempC = stabilizeTemperature(smcResult.tempAvailable ? smc.temperature : nil)
            let available = smcPowerAvailable || tempC != nil || batteryInfo != nil

            return SystemPowerSnapshot(
                available: available,
                systemInWatts: systemIn,
                systemLoadWatts: systemLoad,
                batteryPowerWatts: batteryPower,
                adapterPowerWatts: adapterPower,
                efficiencyLossWatts: efficiencyLoss,
                screenPowerWatts: smc.brightness,
                heatpipePowerWatts: smc.heatpipe,
                adapterWatts: batteryInfo?.adapterWatts,
                adapterVoltage: batteryInfo?.adapterVoltage,
                adapterAmperage: batteryInfo?.adapterAmperage,
                batteryLevelPercent: batteryInfo?.currentCapacity,
                isCharging: batteryInfo?.isCharging,
                temperatureC: tempC
            )
        }
    }

    private func stabilizeTemperature(_ value: Double?) -> Double? {
        let now = Date().timeIntervalSinceReferenceDate
        if let value {
            let clamped = min(max(value, minTempC), maxTempC)
            lastTempC = clamped
            lastTempStamp = now
            return clamped
        }
        if let lastTempC, now - lastTempStamp <= tempHoldSeconds {
            return lastTempC
        }
        return nil
    }
}

private struct PowerTelemetry: Equatable {
    var adapterEfficiencyLoss: Int
    var batteryPower: Int
    var systemCurrentIn: Int
    var systemEnergyConsumed: Int
    var systemLoad: Int
    var systemPowerIn: Int
    var systemVoltageIn: Int
}

private struct BatteryInfo: Equatable {
    var currentCapacity: Int
    var isCharging: Bool
    var timeRemainingMinutes: Int?
    var adapterWatts: Double
    var adapterVoltage: Double
    var adapterAmperage: Double
    var powerTelemetry: PowerTelemetry?
}

private final class IORegistryReader {
    func readBatteryInfo() -> BatteryInfo? {
        guard let dict = readSmartBattery() else { return nil }

        let currentCapacity = intValue(dict, key: "CurrentCapacity") ?? 0
        let isCharging = boolValue(dict, key: "IsCharging") ?? false
        let timeRemaining = intValue(dict, key: "TimeRemaining")

        let adapterDetails = dict["AdapterDetails"] as? NSDictionary
        let adapterWatts = intValue(adapterDetails, key: "Watts").map(Double.init) ?? 0
        let adapterVoltage = intValue(adapterDetails, key: "AdapterVoltage").map { Double($0) / 1000.0 } ?? 0
        let adapterAmperage = intValue(adapterDetails, key: "Current").map { Double($0) / 1000.0 } ?? 0

        let telemetry = readPowerTelemetry(from: dict)

        return BatteryInfo(
            currentCapacity: currentCapacity,
            isCharging: isCharging,
            timeRemainingMinutes: timeRemaining,
            adapterWatts: adapterWatts,
            adapterVoltage: adapterVoltage,
            adapterAmperage: adapterAmperage,
            powerTelemetry: telemetry
        )
    }

    private func readSmartBattery() -> NSDictionary? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as NSDictionary? else {
            return nil
        }
        return dict
    }

    private func intValue(_ dict: NSDictionary?, key: String) -> Int? {
        dict?[key] as? Int
    }

    private func boolValue(_ dict: NSDictionary?, key: String) -> Bool? {
        dict?[key] as? Bool
    }

    private func readPowerTelemetry(from dict: NSDictionary) -> PowerTelemetry? {
        guard let telemetry = dict["PowerTelemetryData"] as? NSDictionary else {
            return nil
        }
        let adapterEfficiencyLoss = intValue(telemetry, key: "AdapterEfficiencyLoss") ?? 0
        let batteryPower = intValue(telemetry, key: "BatteryPower") ?? 0
        let systemCurrentIn = intValue(telemetry, key: "SystemCurrentIn") ?? 0
        let systemEnergyConsumed = intValue(telemetry, key: "SystemEnergyConsumed") ?? 0
        let systemLoad = intValue(telemetry, key: "SystemLoad") ?? 0
        let systemPowerIn = intValue(telemetry, key: "SystemPowerIn") ?? 0
        let systemVoltageIn = intValue(telemetry, key: "SystemVoltageIn") ?? 0

        return PowerTelemetry(
            adapterEfficiencyLoss: adapterEfficiencyLoss,
            batteryPower: batteryPower,
            systemCurrentIn: systemCurrentIn,
            systemEnergyConsumed: systemEnergyConsumed,
            systemLoad: systemLoad,
            systemPowerIn: systemPowerIn,
            systemVoltageIn: systemVoltageIn
        )
    }
}

private struct SMCPowerData: Equatable {
    var batteryRate: Double
    var deliveryRate: Double
    var systemTotal: Double
    var heatpipe: Double?
    var brightness: Double?
    var fullChargeCapacity: Double
    var currentCapacity: Double
    var chargingStatus: Double
    var timeToEmpty: Double
    var timeToFull: Double
    var temperature: Double?
}

fileprivate struct SMCReadResult {
    let data: SMCPowerData
    let didReadDelivery: Bool
    let didReadSystemTotal: Bool
    let didReadBatteryRate: Bool
    let tempAvailable: Bool

    var powerAvailable: Bool {
        didReadDelivery || didReadSystemTotal || didReadBatteryRate
    }
}

private final class SMCReader {

    private let powerKeys = [
        "PPBR", "PDTR", "PSTR", "PHPC", "PDBR",
        "B0FC", "SBAR", "CHCC", "B0TE", "B0TF",
    ]
    private let tempKeys = [
        "TC0D", "TC0P", "TC0E", "TC0F",
        "Tp0p", "Tp01", "Tp05", "Tp09", "Tp0T", "Tp0H",
        "TG0D", "TG0P", "TG0E", "TG0F",
        "TCXC"
    ]
    private let minTempC = 20.0
    private let maxTempC = 110.0

    private var connection: SMCConnection?

    func readPowerData() -> SMCReadResult {
        guard let connection = getConnection() else {
            return SMCReadResult(
                data: .empty,
                didReadDelivery: false,
                didReadSystemTotal: false,
                didReadBatteryRate: false,
                tempAvailable: false
            )
        }
        var data = SMCPowerData.empty
        var didReadDelivery = false
        var didReadSystemTotal = false
        var didReadBatteryRate = false

        for key in powerKeys {
            guard let value = connection.readKey(key)?.floatValue() else { continue }
            switch key {
            case "PPBR":
                data.batteryRate = value
                didReadBatteryRate = true
            case "PDTR":
                data.deliveryRate = value
                didReadDelivery = true
            case "PSTR":
                data.systemTotal = value
                didReadSystemTotal = true
            case "PHPC":
                data.heatpipe = value
            case "PDBR":
                data.brightness = value
            case "B0FC":
                data.fullChargeCapacity = value
            case "SBAR":
                data.currentCapacity = value
            case "CHCC":
                data.chargingStatus = value
            case "B0TE":
                data.timeToEmpty = value
            case "B0TF":
                data.timeToFull = value
            default:
                break
            }
        }

        var temps: [Double] = []
        temps.reserveCapacity(tempKeys.count)
        for key in tempKeys {
            guard let value = connection.readKey(key)?.floatValue() else { continue }
            temps.append(value)
        }
        let tempAvailable = !temps.isEmpty
        data.temperature = selectTemperature(from: temps)

        return SMCReadResult(
            data: data,
            didReadDelivery: didReadDelivery,
            didReadSystemTotal: didReadSystemTotal,
            didReadBatteryRate: didReadBatteryRate,
            tempAvailable: tempAvailable
        )
    }

    private func selectTemperature(from values: [Double]) -> Double? {
        let plausible = values.filter { $0 >= minTempC && $0 <= maxTempC }
        guard !plausible.isEmpty else { return nil }
        let sorted = plausible.sorted()
        let trimCount = max(0, sorted.count / 5)
        let trimmed = sorted.dropFirst(trimCount).dropLast(trimCount)
        let sample = trimmed.isEmpty ? sorted : Array(trimmed)
        let sum = sample.reduce(0, +)
        return sum / Double(sample.count)
    }

    private func getConnection() -> SMCConnection? {
        if let connection = connection {
            return connection
        }
        let newConnection = SMCConnection()
        connection = newConnection
        return newConnection
    }
}

private extension SMCPowerData {
    static let empty = SMCPowerData(
        batteryRate: 0,
        deliveryRate: 0,
        systemTotal: 0,
        heatpipe: nil,
        brightness: nil,
        fullChargeCapacity: 0,
        currentCapacity: 0,
        chargingStatus: 0,
        timeToEmpty: 0,
        timeToFull: 0,
        temperature: nil
    )
}

private let kSMCServiceName = "AppleSMC"
private let kSMCUserClient = UInt32(0)
private let kSMCIndex = UInt32(2)
private let kSMCCmdReadKeyInfo = UInt8(9)
private let kSMCCmdReadBytes = UInt8(5)

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private func makeBytes32() -> SMCBytes32 {
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func bytesArray(from tuple: SMCBytes32) -> [UInt8] {
    withUnsafeBytes(of: tuple) { Array($0) }
}

private func keyToUInt32(_ key: String) -> UInt32 {
    var value: UInt32 = 0
    for byte in key.utf8.prefix(4) {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

private func u32ToTypeString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        .lowercased() ?? ""
}

private struct SMCDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCDataVers = SMCDataVers()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = makeBytes32()
}

private struct SMCValue {
    var key: String
    var dataSize: Int
    var dataType: String
    var bytes: [UInt8]

    func floatValue() -> Double? {
        switch dataType {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(Float32(bitPattern: raw))
        case "ui8":
            guard let value = bytes.first else { return nil }
            return Double(value)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw)
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(raw)
        default:
            if dataType.hasPrefix("fp") || dataType.hasPrefix("sp") {
                return fixedPointValue(type: dataType)
            }
            return nil
        }
    }

    private func fixedPointValue(type: String) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let mapping: [String: (Double, Bool)] = [
            "fp1f": (32768.0, false),
            "fp2e": (16384.0, false),
            "fp3d": (8192.0, false),
            "fp4c": (4096.0, false),
            "fp5b": (2048.0, false),
            "fp6a": (1024.0, false),
            "fp79": (512.0, false),
            "fp88": (256.0, false),
            "fpa6": (64.0, false),
            "fpc4": (16.0, false),
            "fpe2": (4.0, false),
            "sp1e": (16384.0, true),
            "sp2d": (8192.0, true),
            "sp3c": (4096.0, true),
            "sp4b": (2048.0, true),
            "sp5a": (1024.0, true),
            "sp69": (512.0, true),
            "sp78": (256.0, true),
            "sp87": (128.0, true),
            "sp96": (64.0, true),
            "spa5": (32.0, true),
            "spb4": (16.0, true),
            "spf0": (1.0, true),
        ]

        guard let (divisor, signed) = mapping[type] else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        if signed {
            let signedValue = Int16(bitPattern: raw)
            return Double(signedValue) / divisor
        }
        return Double(raw) / divisor
    }
}

private final class SMCConnection {
    private let connection: io_connect_t
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kSMCServiceName)
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, kSMCUserClient, &connect)
        guard result == KERN_SUCCESS else { return nil }
        connection = connect
    }

    deinit {
        IOServiceClose(connection)
    }

    func readKey(_ key: String) -> SMCValue? {
        let keyInt = keyToUInt32(key)
        guard let keyInfo = getKeyInfo(keyInt) else { return nil }

        var input = SMCKeyData()
        input.key = keyInt
        input.data8 = kSMCCmdReadBytes
        input.keyInfo = keyInfo

        guard let output = call(input: input) else { return nil }

        let bytes = bytesArray(from: output.bytes)
        let dataType = u32ToTypeString(keyInfo.dataType)
        return SMCValue(
            key: key,
            dataSize: Int(keyInfo.dataSize),
            dataType: dataType,
            bytes: bytes
        )
    }

    private func getKeyInfo(_ key: UInt32) -> SMCKeyInfo? {
        if let cached = keyInfoCache[key] {
            return cached
        }

        var input = SMCKeyData()
        input.key = key
        input.data8 = kSMCCmdReadKeyInfo

        guard let output = call(input: input) else { return nil }
        let info = output.keyInfo
        keyInfoCache[key] = info
        return info
    }

    private func call(input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = withUnsafePointer(to: &input) { inputPtr -> kern_return_t in
            withUnsafeMutablePointer(to: &output) { outputPtr -> kern_return_t in
                IOConnectCallStructMethod(
                    connection,
                    kSMCIndex,
                    inputPtr,
                    MemoryLayout<SMCKeyData>.size,
                    outputPtr,
                    &outputSize
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return output
    }
}
