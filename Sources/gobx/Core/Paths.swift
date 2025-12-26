import Foundation

enum GobxPaths {
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gallery-of-babel")
    }

    static var configURL: URL {
        configDir.appendingPathComponent("config.json")
    }

    static var seedStateURL: URL {
        configDir.appendingPathComponent("gobx-seed-state.json")
    }

    static var mpsCalibrationURL: URL {
        configDir.appendingPathComponent("gobx-mps-calibration.json")
    }

    static var metalCalibrationURL: URL {
        configDir.appendingPathComponent("gobx-metal-calibration.json")
    }

    static var proxyWeightsURL: URL {
        configDir.appendingPathComponent("gobx-proxy-weights.json")
    }

    static var metalProxyWeightsURL: URL {
        configDir.appendingPathComponent("gobx-proxy-weights-metal.json")
    }

    static var submissionQueueURL: URL {
        configDir.appendingPathComponent("gobx-submission-queue.json")
    }

    static var updateStateURL: URL {
        configDir.appendingPathComponent("gobx-update-state.json")
    }

    static var gpuTuningURL: URL {
        configDir.appendingPathComponent("gobx-gpu-tuning.json")
    }

    static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func resolveURL(_ path: String) -> URL {
        URL(fileURLWithPath: expandPath(path))
    }
}
