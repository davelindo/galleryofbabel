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

    static var mpsStage1CalibrationURL: URL {
        configDir.appendingPathComponent("gobx-mps-stage1-calibration.json")
    }

    static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func resolveURL(_ path: String) -> URL {
        URL(fileURLWithPath: expandPath(path))
    }
}

