import Foundation

public enum GPUThroughputProfile: String, CaseIterable, Sendable {
    case dabbling
    case interested
    case letsGo
    case heater

    public var factor: Double {
        switch self {
        case .dabbling: return 0.10
        case .interested: return 0.40
        case .letsGo: return 0.60
        case .heater: return 1.0
        }
    }

    public var displayName: String {
        switch self {
        case .dabbling: return "dabbling"
        case .interested: return "interested"
        case .letsGo: return "Let's go"
        case .heater: return "Who needs a heater?"
        }
    }

    public var marketingName: String {
        switch self {
        case .dabbling: return "Dabbling"
        case .interested: return "Interested"
        case .letsGo: return "Let's go"
        case .heater: return "Who needs a heater?"
        }
    }

    public static func parse(_ raw: String) -> GPUThroughputProfile? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "dabbling", "10", "10%":
            return .dabbling
        case "interested", "40", "40%":
            return .interested
        case "lets-go", "let's-go", "letsgo", "60", "60%":
            return .letsGo
        case "heater", "who-needs-a-heater", "who needs a heater", "100", "100%":
            return .heater
        default:
            return nil
        }
    }
}

public final class GPUThroughputLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var profile: GPUThroughputProfile

    public init(profile: GPUThroughputProfile = .heater) {
        self.profile = profile
    }

    public func setProfile(_ profile: GPUThroughputProfile) {
        lock.withLock {
            self.profile = profile
        }
    }

    public func currentProfile() -> GPUThroughputProfile {
        lock.withLock { profile }
    }

    public func factor() -> Double {
        lock.withLock { profile.factor }
    }
}
