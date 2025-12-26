import Darwin
import Foundation

enum LogTimestamp {
    static func prefix() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

func configureNoUILogging() {
    struct StdoutUnbuffered {
        static let once: Void = {
            setvbuf(stdout, nil, _IONBF, 0)
        }()
    }
    _ = StdoutUnbuffered.once
}

func formatLogLine(_ message: String, includeTimestamp: Bool) -> String {
    guard includeTimestamp else { return message }
    return "[\(LogTimestamp.prefix())] \(message)"
}
