import Darwin
import Foundation

enum FirstRunSetup {
    enum ConfigIssue {
        case missing
        case unreadable
    }

    enum Trigger {
        case auto(ConfigIssue)
        case explicit
    }

    static func run(
        trigger: Trigger,
        backend: Backend,
        gpuBackend: GPUBackend,
        doSubmit: Bool,
        mpsMarginSpecified: Bool,
        emit: (ExploreEventKind, String) -> Void
    ) -> AppConfig? {
        guard Terminal.isInteractiveStdout(), Terminal.isInteractiveStdin() else { return nil }

        let configURL = GobxPaths.configURL
        let configPath = configURL.path
        switch trigger {
        case .auto(let issue):
            let intro: String
            switch issue {
            case .missing:
                intro = "No config found at \(configPath)."
            case .unreadable:
                intro = "Config found at \(configPath) but could not be parsed."
            }
            let shouldRun = promptYesNo("\(intro) Run first-time setup now?", defaultValue: true)
            guard shouldRun else { return nil }
        case .explicit:
            Terminal.writeStdout("Interactive setup for \(configPath)\n")
        }

        let baseUrl = "https://www.echohive.ai"
        let wantsProfile = promptYesNo("Configure submission profile now?", defaultValue: true)

        var profile: AppConfig.Profile? = nil
        if wantsProfile {
            let defaultId = generateUserId()
            let defaultName = generateRandomName()
            let id = promptValue("Profile id", defaultValue: defaultId, maxLength: defaultId.count)
            let name = promptValue("Display name", defaultValue: defaultName, maxLength: defaultName.count)
            let xProfile = normalizeXProfile(promptValue("X handle (optional, without @)", defaultValue: nil))
            if let id, let name {
                profile = AppConfig.Profile(id: id, name: name, xProfile: xProfile)
            } else {
                emit(.warning, "Profile not configured; submissions will use the default author until you update \(configPath).")
            }
        }

        let config = AppConfig(baseUrl: baseUrl, profile: profile)
        guard confirmWrite(to: configURL, emit: emit) else { return nil }
        do {
            try saveConfig(config, to: configURL)
            emit(.info, "Wrote config to \(configPath)")
        } catch {
            emit(.warning, "Failed to write config to \(configPath): \(error)")
            return nil
        }

        maybeRunCalibration(
            backend: backend,
            gpuBackend: gpuBackend,
            doSubmit: doSubmit,
            mpsMarginSpecified: mpsMarginSpecified,
            emit: emit
        )

        return config
    }

    private static func maybeRunCalibration(
        backend: Backend,
        gpuBackend: GPUBackend,
        doSubmit: Bool,
        mpsMarginSpecified: Bool,
        emit: (ExploreEventKind, String) -> Void
    ) {
        guard doSubmit, !mpsMarginSpecified else { return }
        guard backend == .mps || backend == .all else { return }

        let (label, hasCalibration): (String, Bool) = {
            switch gpuBackend {
            case .metal:
                return ("Metal", CalibrateMetal.loadIfValid() != nil)
            case .mps:
                return ("MPS", CalibrateMPS.loadIfValid(optLevel: 1) != nil)
            }
        }()

        guard !hasCalibration else { return }
        let prompt = "No valid \(label) calibration found. Run it now? This can take several minutes."
        guard promptYesNo(prompt, defaultValue: false) else { return }

        emit(.info, "Running \(label) calibration...")
        do {
            switch gpuBackend {
            case .metal:
                try CalibrateMetal.run(args: [])
            case .mps:
                try CalibrateMPS.run(args: [])
            }
        } catch {
            emit(.warning, "\(label) calibration failed: \(error)")
        }
    }

    private static func promptLine(_ prompt: String) -> String? {
        Terminal.writeStdout(prompt)
        fflush(stdout)
        return readLine()
    }

    private static func promptValue(_ prompt: String, defaultValue: String?, maxLength: Int? = nil) -> String? {
        while true {
            let suffix = defaultValue.flatMap { $0.isEmpty ? nil : $0 }.map { " [\($0)]" } ?? ""
            let line = promptLine("\(prompt)\(suffix): ") ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? defaultValue : trimmed
            guard let maxLength else { return value }
            if let value, value.count > maxLength {
                Terminal.writeStdout("Please keep it to \(maxLength) characters or fewer.\n")
                continue
            }
            return value
        }
    }

    private static func promptYesNo(_ prompt: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? " [Y/n] " : " [y/N] "
        while true {
            let line = promptLine(prompt + suffix) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return defaultValue }
            switch trimmed.lowercased() {
            case "y", "yes":
                return true
            case "n", "no":
                return false
            default:
                Terminal.writeStdout("Please enter y or n.\n")
            }
        }
    }

    private static func normalizeXProfile(_ raw: String?) -> String? {
        guard var handle = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return nil
        }
        while handle.hasPrefix("@") { handle.removeFirst() }
        return handle.isEmpty ? nil : handle
    }

    private static func generateRandomName() -> String {
        let adjectives = [
            "Cosmic", "Quantum", "Neural", "Digital", "Electric", "Stellar", "Phantom",
            "Crystal", "Neon", "Shadow", "Crimson", "Azure", "Golden", "Silver",
            "Mystic", "Cyber", "Atomic", "Lunar", "Solar", "Astral", "Ethereal",
            "Wandering", "Silent", "Swift", "Clever", "Bold", "Curious", "Dreaming"
        ]
        let nouns = [
            "Explorer", "Seeker", "Wanderer", "Pioneer", "Voyager", "Hunter", "Finder",
            "Scholar", "Sage", "Oracle", "Phoenix", "Dragon", "Wolf", "Hawk", "Raven",
            "Serpent", "Tiger", "Panther", "Fox", "Bear", "Owl", "Falcon", "Lion",
            "Nomad", "Pilgrim", "Ranger", "Scout", "Sentinel", "Guardian", "Keeper"
        ]

        let adj = adjectives[Int.random(in: 0..<adjectives.count)]
        let noun = nouns[Int.random(in: 0..<nouns.count)]
        let code = base36Upper(Int.random(in: 0..<(36 * 36 * 36 * 36))).leftPadded(to: 4, with: "0")
        return "\(adj)-\(noun)-\(code)"
    }

    private static func generateUserId() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000.0)
        let timePart = base36Lower(ms)
        let randPart = randomBase36(length: 9)
        return "user_\(timePart)_\(randPart)"
    }

    private static func randomBase36(length: Int) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var out = ""
        out.reserveCapacity(max(0, length))
        for _ in 0..<max(0, length) {
            out.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return out
    }

    private static func base36Lower(_ value: Int64) -> String {
        if value == 0 { return "0" }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var n = value
        var chars: [Character] = []
        while n > 0 {
            let idx = Int(n % 36)
            chars.append(alphabet[idx])
            n /= 36
        }
        return String(chars.reversed())
    }

    private static func base36Upper(_ value: Int) -> String {
        let lower = base36Lower(Int64(value))
        return lower.uppercased()
    }

    private static func confirmWrite(to url: URL, emit: (ExploreEventKind, String) -> Void) -> Bool {
        let path = url.path
        let exists = FileManager.default.fileExists(atPath: path)
        if exists {
            let overwrite = promptYesNo("Overwrite existing config at \(path)?", defaultValue: false)
            guard overwrite else {
                emit(.info, "Keeping existing config at \(path)")
                return false
            }
        }
        let write = promptYesNo("Write config to \(path)?", defaultValue: true)
        guard write else {
            emit(.info, "Config not written.")
            return false
        }
        return true
    }
}

private extension String {
    func leftPadded(to length: Int, with pad: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
