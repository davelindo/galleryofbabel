import Foundation
import GobxCore

enum MenuTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case stats = "Stats"
    case events = "Events"
    case submissions = "Submissions"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .stats: return "chart.xyaxis.line"
        case .events: return "bell"
        case .submissions: return "paperplane"
        case .settings: return "gearshape"
        }
    }
}

enum SetupIssue {
    case missing
    case unreadable

    func message(configPath: String) -> String {
        switch self {
        case .missing:
            return "No config found at \(configPath)."
        case .unreadable:
            return "Config found at \(configPath) but could not be parsed."
        }
    }
}

private func makeSuggestedProfile() -> AppConfig.Profile {
    AppConfig.Profile(id: generateUserId(), name: generateRandomName(), xProfile: nil)
}

private func generateRandomName() -> String {
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

private func generateUserId() -> String {
    let ms = Int64(Date().timeIntervalSince1970 * 1000.0)
    let timePart = base36Lower(ms)
    let randPart = randomBase36(length: 9)
    return "user_\(timePart)_\(randPart)"
}

private func randomBase36(length: Int) -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    var out = ""
    out.reserveCapacity(max(0, length))
    for _ in 0..<max(0, length) {
        out.append(alphabet[Int.random(in: 0..<alphabet.count)])
    }
    return out
}

private func base36Lower(_ value: Int64) -> String {
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

private func base36Upper(_ value: Int) -> String {
    base36Lower(Int64(value)).uppercased()
}

private func gobxConfigPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/gallery-of-babel/config.json")
        .path
}

private extension String {
    func leftPadded(to length: Int, with pad: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}

struct MenuSummary {
    let backend: Backend
    let elapsed: Double
    let totalRate: Double
    let cpuRate: Double
    let mpsRate: Double
    let cpuVerifyRate: Double
    let totalCount: UInt64
    let cpuAvg: Double?
    let mpsAvg: Double?
    let cpuVerifyAvg: Double?
    let bestScore: Double?
    let bestSeed: UInt64?
    let bestSource: String?
    let topBestScore: Double?
    let topBestSeed: UInt64?
    let personalBestPreviousScore: Double?
    let personalBestPreviousSeed: UInt64?
    let personalBestPreviousRank: Int?
    let threshold: Double
    let top500: Double?
    let margin: Double
    let shift: Double
    let submitStats: SubmissionManager.StatsSnapshot?
    let submitRate: Double?
    let system: ExploreSystemStats.Snapshot
    let rateScale: Double

    static let empty = MenuSummary(
        backend: .cpu,
        elapsed: 0,
        totalRate: 0,
        cpuRate: 0,
        mpsRate: 0,
        cpuVerifyRate: 0,
        totalCount: 0,
        cpuAvg: nil,
        mpsAvg: nil,
        cpuVerifyAvg: nil,
        bestScore: nil,
        bestSeed: nil,
        bestSource: nil,
        topBestScore: nil,
        topBestSeed: nil,
        personalBestPreviousScore: nil,
        personalBestPreviousSeed: nil,
        personalBestPreviousRank: nil,
        threshold: 0,
        top500: nil,
        margin: 0,
        shift: 0,
        submitStats: nil,
        submitRate: nil,
        system: ExploreSystemStats.Snapshot(
            processResidentBytes: nil,
            processFootprintBytes: nil,
            gpuAllocatedBytes: nil,
            gpuWorkingSetBytes: nil,
            gpuUtilPercent: nil,
            gpuPowerWatts: nil,
            gpuUtilAvailable: false
        ),
        rateScale: 1.0
    )
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let totalRate: Double
    let cpuRate: Double
    let mpsRate: Double
    let cpuVerifyRate: Double
    let cpuAvg: Double?
    let mpsAvg: Double?
    let cpuVerifyAvg: Double?
    let submitRate: Double?
    let rssBytes: UInt64?
    let gpuMemBytes: UInt64?
    let gpuUtilPercent: Double?
    let gpuPowerWatts: Double?
    let socPowerWatts: Double?
    let socTempC: Double?
}

@MainActor
final class ExploreMenuModel: ObservableObject {
    @Published var summary: MenuSummary = .empty
    @Published var events: [ExploreEvent] = []
    @Published var submissions: [SubmissionLogEntry] = []
    @Published var history: [HistoryPoint] = []
    @Published var selectedTab: MenuTab = .dashboard
    @Published var isRunning = false
    @Published var statusMessage: String? = nil
    @Published var throughputProfile: GPUThroughputProfile = .heater
    @Published var preventSleepOnAC = false
    @Published var powerSourceLabel = "unknown"
    @Published var sleepGuardActive = false
    @Published var profileId = ""
    @Published var profileName = ""
    @Published var profileX = ""
    @Published var statsEnabled = false
    @Published var statsUrl = ""
    @Published var configStatusMessage: String? = nil
    @Published var isPaused = false
    @Published var leaderboard: [SubmissionManager.AcceptedSeed] = []
    @Published var showSetupWizard = false
    @Published var setupIssue: SetupIssue? = nil
    @Published var setupWantsProfile = true
    @Published var setupStatusMessage: String? = nil

    private let bridge = ExploreUIBridge(eventCapacity: 2000)
    private let systemStats = ExploreSystemStats()
    private let sleepGuard = SleepGuard()
    private let defaults = UserDefaults.standard
    private let profileDefaultsKey = "gobx.menubar.gpuProfile"
    private let sleepDefaultsKey = "gobx.menubar.preventSleepOnAC"
    private var runTask: Task<Void, Never>? = nil
    private var timer: Timer? = nil
    private var startNs: UInt64 = 0
    private var lastSnap: ExploreStats.Snapshot? = nil
    private var lastNs: UInt64 = 0
    private var lastSubmitSnap: SubmissionManager.StatsSnapshot? = nil
    private var totalRateHistory: [Double] = []
    private var refreshTick: Int = 0
    private var totalCountDisplay: UInt64 = 0

    private let historyCapacity = 600
    private var desiredProfile: GPUThroughputProfile = .heater
    private var runToken: UInt64 = 0

    init() {
        if let raw = defaults.string(forKey: profileDefaultsKey),
           let profile = GPUThroughputProfile.parse(raw) {
            desiredProfile = profile
            throughputProfile = profile
        }
        preventSleepOnAC = defaults.bool(forKey: sleepDefaultsKey)
        loadConfigState()
        updateSleepGuard()
    }

    var configPath: String {
        gobxConfigPath()
    }

    func start(args: [String] = Array(CommandLine.arguments.dropFirst())) {
        guard runTask == nil else { return }
        isPaused = false
        bridge.pause.setPaused(false)
        bridge.resetStop()
        runToken &+= 1
        let activeToken = runToken
        var options: ExploreOptions
        let filteredArgs = filterExploreArgs(args)
        do {
            options = try ExploreOptions.parse(args: filteredArgs)
        } catch {
            statusMessage = "Failed to parse args: \(error)"
            options = ExploreOptions()
        }
        options.uiEnabled = false
        options.reportEverySec = 0
        if options.statsEnabled == nil {
            options.statsEnabled = statsEnabled
        }
        if !filteredArgs.contains("--gpu-profile") {
            if let raw = defaults.string(forKey: profileDefaultsKey),
               let profile = GPUThroughputProfile.parse(raw) {
                options.gpuThroughputProfile = profile
            }
        }
        desiredProfile = options.gpuThroughputProfile
        throughputProfile = desiredProfile
        defaults.set(desiredProfile.rawValue, forKey: profileDefaultsKey)

        startNs = DispatchTime.now().uptimeNanoseconds
        lastNs = startNs
        lastSnap = bridge.stats.snapshot()
        lastSubmitSnap = nil
        totalRateHistory.removeAll(keepingCapacity: true)
        history.removeAll(keepingCapacity: true)
        systemStats.start()
        isRunning = true

        runTask = Task.detached(priority: .userInitiated) { [bridge] in
            do {
                try await ExploreRunner.run(options: options, uiBridge: bridge)
            } catch {
                await MainActor.run {
                    self.statusMessage = "Explore stopped: \(error)"
                }
            }
            await MainActor.run {
                self.endRun(requestStop: false, token: activeToken)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func setThroughputProfile(_ profile: GPUThroughputProfile) {
        desiredProfile = profile
        throughputProfile = profile
        defaults.set(profile.rawValue, forKey: profileDefaultsKey)
        if let limiter = bridge.context()?.gpuThroughput {
            limiter.setProfile(profile)
        }
    }

    func togglePause() {
        setPaused(!isPaused)
    }

    func setPaused(_ value: Bool) {
        guard isRunning else {
            isPaused = false
            bridge.pause.setPaused(false)
            return
        }
        isPaused = value
        bridge.pause.setPaused(value)
    }

    func setPreventSleepOnAC(_ value: Bool) {
        preventSleepOnAC = value
        defaults.set(value, forKey: sleepDefaultsKey)
        updateSleepGuard()
    }

    func saveConfigChanges() {
        let id = profileId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || name.isEmpty {
            configStatusMessage = "Profile id and name are required."
            return
        }
        let xRaw = profileX.trimmingCharacters(in: .whitespacesAndNewlines)
        let x = xRaw.hasPrefix("@") ? String(xRaw.dropFirst()) : xRaw
        let profile = AppConfig.Profile(id: id, name: name, xProfile: x.isEmpty ? nil : x)
        let url = statsUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = AppConfig.StatsConfig(enabled: statsEnabled, url: url.isEmpty ? nil : url)
        let config = AppConfig(profile: profile, stats: stats)
        do {
            try saveConfig(config)
            configStatusMessage = "Saved. Restart explore to apply."
        } catch {
            configStatusMessage = "Save failed: \(error)"
        }
    }

    func dismissSetupWizard() {
        showSetupWizard = false
        setupStatusMessage = nil
    }

    func saveSetupWizard() {
        var profile: AppConfig.Profile? = nil
        if setupWantsProfile {
            let id = profileId.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || name.isEmpty {
                setupStatusMessage = "Profile id and name are required."
                return
            }
            let xRaw = profileX.trimmingCharacters(in: .whitespacesAndNewlines)
            let x = xRaw.hasPrefix("@") ? String(xRaw.dropFirst()) : xRaw
            profile = AppConfig.Profile(id: id, name: name, xProfile: x.isEmpty ? nil : x)
        }
        let url = statsUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = AppConfig.StatsConfig(enabled: statsEnabled, url: url.isEmpty ? nil : url)
        let config = AppConfig(profile: profile, stats: stats)
        do {
            try saveConfig(config)
            setupStatusMessage = "Saved. Restart explore to apply."
            showSetupWizard = false
            loadConfigState()
        } catch {
            setupStatusMessage = "Save failed: \(error)"
        }
    }

    func stop() {
        endRun(requestStop: true, token: runToken)
    }

    func refresh() {
        updateSleepGuard()
        guard let context = bridge.context() else { return }
        if context.gpuThroughput.currentProfile() != desiredProfile {
            context.gpuThroughput.setProfile(desiredProfile)
        }
        throughputProfile = context.gpuThroughput.currentProfile()
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastNs) / 1e9
        let snap = bridge.stats.snapshot()

        let cpuDelta = Double(snap.cpuCount &- (lastSnap?.cpuCount ?? 0))
        let cpuVerifyDelta = Double(snap.cpuVerifyCount &- (lastSnap?.cpuVerifyCount ?? 0))
        let mpsDelta = Double(snap.mpsCount &- (lastSnap?.mpsCount ?? 0))
        let cpuRate = dt > 0 ? cpuDelta / dt : 0
        let cpuVerifyRate = dt > 0 ? cpuVerifyDelta / dt : 0
        let mpsRate = dt > 0 ? mpsDelta / dt : 0
        let totalRate = dt > 0 ? (cpuDelta + cpuVerifyDelta + mpsDelta) / dt : 0

        lastSnap = snap
        lastNs = now

        let totalCount = snap.cpuCount &+ snap.mpsCount &+ snap.cpuVerifyCount
        refreshTick += 1
        if refreshTick == 1 || refreshTick % 5 == 0 {
            totalCountDisplay = totalCount
        }
        let cpuAvg = snap.cpuCount > 0 ? snap.cpuScoreSum / Double(snap.cpuCount) : nil
        let mpsAvg = snap.mpsCount > 0 ? snap.mpsScoreSum / Double(snap.mpsCount) : nil
        let cpuVerifyAvg = snap.cpuVerifyCount > 0 ? snap.cpuVerifyScoreSum / Double(snap.cpuVerifyCount) : nil

        let bestSnap = bridge.best.snapshot()
        let approxSnap = bridge.bestApprox.snapshot()
        let bestScore: Double? = {
            if bestSnap.score.isFinite { return bestSnap.score }
            if approxSnap.score.isFinite { return Double(approxSnap.score) }
            return nil
        }()
        let bestSeed: UInt64? = {
            if bestSnap.score.isFinite { return bestSnap.seed }
            if approxSnap.score.isFinite { return approxSnap.seed }
            return nil
        }()
        let bestSource: String? = bestSnap.source

        let submitSnap = bridge.submission()?.statsSnapshot()
        let submitRate: Double? = {
            guard let submitSnap else { return nil }
            let prior = lastSubmitSnap
            let submitDelta = prior.map { Double(submitSnap.submitAttempts &- $0.submitAttempts) } ?? 0.0
            lastSubmitSnap = submitSnap
            return dt > 0 ? submitDelta / dt : 0.0
        }()

        let topSnap = bridge.submission()?.stateSnapshot()
        let top500 = topSnap?.top500Threshold
        let threshold = bridge.submission()?.effectiveThreshold() ?? context.minScore

        let systemSnap = systemStats.snapshot()

        totalRateHistory.append(max(0.0, totalRate))
        if totalRateHistory.count > 120 {
            totalRateHistory.removeFirst(totalRateHistory.count - 120)
        }
        let rateScale = max(1.0, totalRateHistory.max() ?? 1.0)

        let summary = MenuSummary(
            backend: context.backend,
            elapsed: Double(now &- startNs) / 1e9,
            totalRate: totalRate,
            cpuRate: cpuRate,
            mpsRate: mpsRate,
            cpuVerifyRate: cpuVerifyRate,
            totalCount: totalCountDisplay,
            cpuAvg: cpuAvg,
            mpsAvg: mpsAvg,
            cpuVerifyAvg: cpuVerifyAvg,
            bestScore: bestScore,
            bestSeed: bestSeed,
            bestSource: bestSource,
            topBestScore: topSnap?.topBestScore,
            topBestSeed: topSnap?.topBestSeed,
            personalBestPreviousScore: topSnap?.personalBestScore,
            personalBestPreviousSeed: topSnap?.personalBestSeed,
            personalBestPreviousRank: topSnap?.personalBestRank,
            threshold: threshold,
            top500: top500,
            margin: context.mpsVerifyMargin.current(),
            shift: context.mpsScoreShift.current(),
            submitStats: submitSnap,
            submitRate: submitRate,
            system: systemSnap,
            rateScale: rateScale
        )

        self.summary = summary
        self.events = bridge.events.snapshot(limit: 200)
        if let submission = bridge.submission() {
            let count = submission.submissionLogCount()
            let start = max(0, count - 200)
            self.submissions = submission.submissionLogSnapshot(from: start, limit: 200)
            self.leaderboard = submission.acceptedBestSnapshot(limit: 3)
        } else {
            self.submissions = []
            self.leaderboard = []
        }

        let historyPoint = HistoryPoint(
            time: Date(),
            totalRate: totalRate,
            cpuRate: cpuRate,
            mpsRate: mpsRate,
            cpuVerifyRate: cpuVerifyRate,
            cpuAvg: cpuAvg,
            mpsAvg: mpsAvg,
            cpuVerifyAvg: cpuVerifyAvg,
            submitRate: submitRate,
            rssBytes: systemSnap.processResidentBytes,
            gpuMemBytes: systemSnap.gpuAllocatedBytes,
            gpuUtilPercent: systemSnap.gpuUtilPercent,
            gpuPowerWatts: systemSnap.gpuPowerWatts,
            socPowerWatts: systemSnap.power.systemLoadWatts,
            socTempC: systemSnap.power.temperatureC
        )
        history.append(historyPoint)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
    }

    private func updateSleepGuard() {
        let status = sleepGuard.update(enabled: preventSleepOnAC)
        powerSourceLabel = status.label
        sleepGuardActive = status.active
    }

    private func endRun(requestStop: Bool, token: UInt64? = nil) {
        if let token, token != runToken {
            return
        }
        if requestStop {
            bridge.stop.requestStop()
        }
        runTask?.cancel()
        runTask = nil
        timer?.invalidate()
        timer = nil
        systemStats.stop()
        isRunning = false
        isPaused = false
        bridge.pause.setPaused(false)
        sleepGuard.disable()
        sleepGuardActive = false
    }

    private func filterExploreArgs(_ args: [String]) -> [String] {
        let valueFlags: Set<String> = ["--count", "--start", "--report-every", "--gpu-profile"]
        let boolFlags: Set<String> = ["--endless", "--submit", "--no-submit", "--ui", "--no-ui", "--setup"]
        var filtered: [String] = []
        filtered.reserveCapacity(args.count)
        var i = 0
        while i < args.count {
            let arg = args[i]
            if valueFlags.contains(arg) {
                let next = i + 1
                guard next < args.count else { break }
                filtered.append(arg)
                filtered.append(args[next])
                i += 2
                continue
            }
            if boolFlags.contains(arg) {
                filtered.append(arg)
                i += 1
                continue
            }
            i += 1
        }
        return filtered
    }

    private func loadConfigState() {
        let configPath = gobxConfigPath()
        let configExists = FileManager.default.fileExists(atPath: configPath)
        let config = loadConfig()
        if let config {
            let profile = config.profile ?? AppConfig.Profile.defaultAuthor
            profileId = profile.id
            profileName = profile.name
            profileX = profile.xProfile ?? ""
            statsEnabled = config.stats?.enabled ?? false
            statsUrl = config.stats?.url ?? ""
            setupIssue = nil
            showSetupWizard = false
            setupStatusMessage = nil
        } else {
            let suggested = makeSuggestedProfile()
            profileId = suggested.id
            profileName = suggested.name
            profileX = suggested.xProfile ?? ""
            statsEnabled = false
            statsUrl = ""
            setupIssue = configExists ? .unreadable : .missing
            showSetupWizard = true
            setupWantsProfile = true
            setupStatusMessage = nil
        }
    }
}
