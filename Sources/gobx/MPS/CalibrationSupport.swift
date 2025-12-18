import CryptoKit
import Darwin
import Foundation
import Metal

enum CalibrationSupport {
    static func metalDevice() throws -> MTLDevice {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw MPSScorerError.noMetalDevice
        }
        return dev
    }

    static func sysctlString(_ name: String) -> String? {
        var len: size_t = 0
        if sysctlbyname(name, nil, &len, nil, 0) != 0 { return nil }
        var buf = [UInt8](repeating: 0, count: max(1, Int(len)))
        if sysctlbyname(name, &buf, &len, nil, 0) != 0 { return nil }
        if let nul = buf.firstIndex(of: 0) { buf = Array(buf[..<nul]) }
        return String(bytes: buf, encoding: .utf8)
    }

    static func archString() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hardwareHash<Key: Encodable>(for key: Key) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(key)
        return sha256Hex(data)
    }

    static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func quantile(_ valuesSortedAscending: [Double], q: Double) -> Double {
        guard !valuesSortedAscending.isEmpty else { return 0 }
        let x = min(1.0, max(0.0, q))
        let idx = Int(floor(x * Double(valuesSortedAscending.count - 1)))
        return valuesSortedAscending[max(0, min(valuesSortedAscending.count - 1, idx))]
    }
}

