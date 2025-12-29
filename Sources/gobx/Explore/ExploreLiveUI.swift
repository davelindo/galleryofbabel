import Dispatch
import Darwin
import Foundation

final class ExploreLiveUI: @unchecked Sendable {
    private enum Page: Int {
        case dashboard
        case stats
        case events
        case submissions
    }

    private enum UIKey {
        case char(Character)
        case up
        case down
        case left
        case right
        case pageUp
        case pageDown
        case home
        case end
        case tab
        case backtab
        case escape
    }

    private struct HistorySample {
        let elapsed: Double
        let totalRate: Double
        let cpuRate: Double
        let mpsRate: Double
        let cpuVerifyRate: Double
        let totalCount: UInt64
        let cpuCount: UInt64
        let mpsCount: UInt64
        let cpuVerifyCount: UInt64
        let cpuAvg: Double?
        let mpsAvg: Double?
        let cpuVerifyAvg: Double?
        let submitRate: Double?
        let submitAccepted: UInt64?
        let submitRejected: UInt64?
        let submitRateLimited: UInt64?
        let submitFailed: UInt64?
        let queuedCount: Int?
        let bestScore: Double?
        let processResidentBytes: UInt64?
        let processFootprintBytes: UInt64?
        let gpuAllocatedBytes: UInt64?
        let gpuWorkingSetBytes: UInt64?
        let gpuUtilPercent: Double?
    }

    private struct RenderContext {
        let size: TerminalSize
        let elapsed: Double
        let thr: Double
        let top500: Double
        let margin: Double
        let shift: Double
        let progressCount: UInt64
        let totalCount: UInt64
        let cpuRate: Double
        let mpsRate: Double
        let cpuVerifyRate: Double
        let totalRate: Double
        let cpuMeanStd: (mean: Double, std: Double)?
        let mpsMeanStd: (mean: Double, std: Double)?
        let cpuVerifyMeanStd: (mean: Double, std: Double)?
        let cpuEta: String?
        let mpsEta: String?
        let bestStr: String
        let bestScore: Double?
        let submitSnap: SubmissionManager.StatsSnapshot?
        let submitRate: Double?
        let systemSnap: ExploreSystemStats.Snapshot
    }

    private let ctx: ExploreUIContext
    private let stats: ExploreStats
    private let best: BestTracker
    private let bestApprox: ApproxBestTracker
    private let submission: SubmissionManager?
    private let events: ExploreEventLog
    private let refreshEverySec: Double
    private let systemStats = ExploreSystemStats()

    private let queue = DispatchQueue(label: "gobx.ui", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var inputSource: DispatchSourceRead?
    private var rawMode: Terminal.RawModeState?
    private var inputBuffer: [UInt8] = []

    private var page: Page = .dashboard
    private var showHelp = false
    private var eventScrollOffset = 0
    private var submissionScrollOffset = 0
    private var historyOffsetSec: Double = 0
    private let historyWindowSec: Double = 600.0
    private let historyCapacity = 7200
    private var history: [HistorySample] = []
    private var lastHistoryNs: UInt64 = 0
    private let historySampleIntervalNs: UInt64 = 1_000_000_000

    private var started = false
    private var startNs: UInt64 = 0
    private var lastSnap: ExploreStats.Snapshot
    private var lastNs: UInt64 = 0
    private var lastSubmitSnap: SubmissionManager.StatsSnapshot? = nil
    private var totalRateHistory: [Double] = []
    private var cpuRateHistory: [Double] = []
    private var mpsRateHistory: [Double] = []
    private var cpuVerifyRateHistory: [Double] = []

    init(
        context: ExploreUIContext,
        stats: ExploreStats,
        best: BestTracker,
        bestApprox: ApproxBestTracker,
        submission: SubmissionManager?,
        events: ExploreEventLog,
        refreshEverySec: Double
    ) {
        self.ctx = context
        self.stats = stats
        self.best = best
        self.bestApprox = bestApprox
        self.submission = submission
        self.events = events
        self.refreshEverySec = max(0.1, refreshEverySec)

        let snap = stats.snapshot()
        self.lastSnap = snap
        let now = DispatchTime.now().uptimeNanoseconds
        self.lastNs = now
        self.startNs = now
        self.lastHistoryNs = now
    }

    func start() {
        guard !started else { return }
        started = true

        Terminal.writeStdout(ANSI.altScreenOn + ANSI.hideCursor + ANSI.clearScreen + ANSI.home)
        systemStats.start()
        if Terminal.isInteractiveStdin() {
            setupInput()
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: refreshEverySec, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.render()
        }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            inputSource?.cancel()
            inputSource = nil
            if let rawMode {
                Terminal.restoreMode(rawMode)
                self.rawMode = nil
            }
            systemStats.stop()
            if started {
                started = false
                Terminal.writeStdout(ANSI.showCursor + ANSI.altScreenOff)
            }
        }
    }

    private func render() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastNs) / 1e9
        let snap = stats.snapshot()

        let cpuDelta = Double(snap.cpuCount &- lastSnap.cpuCount)
        let cpuVerifyDelta = Double(snap.cpuVerifyCount &- lastSnap.cpuVerifyCount)
        let mpsDelta = Double(snap.mpsCount &- lastSnap.mpsCount)
        let cpuRate = dt > 0 ? cpuDelta / dt : 0
        let cpuVerifyRate = dt > 0 ? cpuVerifyDelta / dt : 0
        let mpsRate = dt > 0 ? mpsDelta / dt : 0
        let progressDelta = cpuDelta + mpsDelta
        let totalDelta = progressDelta + cpuVerifyDelta
        let totalRate = dt > 0 ? totalDelta / dt : 0

        lastSnap = snap
        lastNs = now

        push(&totalRateHistory, totalRate, cap: 60)
        push(&cpuRateHistory, cpuRate, cap: 60)
        push(&mpsRateHistory, mpsRate, cap: 60)
        push(&cpuVerifyRateHistory, cpuVerifyRate, cap: 60)

        let elapsed = Double(now &- startNs) / 1e9
        let size = Terminal.stdoutSize()

        let systemSnap = systemStats.snapshot()

        let topSnap = submission?.stateSnapshot()
        let thr = submission?.effectiveThreshold() ?? ctx.minScore
        let top500 = topSnap?.top500Threshold ?? .nan
        let submitSnap = submission?.statsSnapshot()
        var submitRate: Double? = nil
        if let submitSnap {
            let prior = lastSubmitSnap
            let submitDelta = prior.map { Double(submitSnap.submitAttempts &- $0.submitAttempts) } ?? 0.0
            submitRate = dt > 0 ? submitDelta / dt : 0.0
            lastSubmitSnap = submitSnap
        }

        let bestSnap = best.snapshot()
        let approxSnap = bestApprox.snapshot()
        let bestExactStr: String? = {
            guard bestSnap.score.isFinite else { return nil }
            let tag = bestSnap.source.map { ",\($0)" } ?? ""
            return "\(String(format: "%.6f", bestSnap.score)) (\(bestSnap.seed)\(tag))"
        }()
        let approxTag: String? = {
            switch ctx.backend {
            case .cpu:
                return nil
            case .mps, .all:
                return "mps"
            }
        }()
        let bestApproxStr: String? = {
            guard let tag = approxTag else { return nil }
            guard approxSnap.score.isFinite else { return nil }
            return "≈\(String(format: "%.6f", Double(approxSnap.score))) (\(approxSnap.seed),\(tag))"
        }()
        let bestStr = bestExactStr ?? bestApproxStr ?? "?"
        let bestScore: Double? = {
            if bestSnap.score.isFinite { return bestSnap.score }
            if approxSnap.score.isFinite { return Double(approxSnap.score) }
            return nil
        }()

        let cpuMeanStd = meanStd(count: snap.cpuCount, sum: snap.cpuScoreSum, sumSq: snap.cpuScoreSumSq)
        let cpuVerifyMeanStd = meanStd(count: snap.cpuVerifyCount, sum: snap.cpuVerifyScoreSum, sumSq: snap.cpuVerifyScoreSumSq)
        let mpsMeanStd = meanStd(count: snap.mpsCount, sum: snap.mpsScoreSum, sumSq: snap.mpsScoreSumSq)

        let cpuEta = etaString(rate: cpuRate, meanStd: cpuMeanStd, threshold: thr)
        let margin = ctx.mpsVerifyMargin.current()
        let shift = ctx.mpsScoreShift.current()
        let bestTarget = bestScore ?? .nan
        let mpsEta = etaString(rate: mpsRate, meanStd: mpsMeanStd, threshold: bestTarget)

        let progressCount = snap.cpuCount &+ snap.mpsCount
        let totalCount = progressCount &+ snap.cpuVerifyCount

        if now &- lastHistoryNs >= historySampleIntervalNs {
            lastHistoryNs = now
            let sample = HistorySample(
                elapsed: elapsed,
                totalRate: totalRate,
                cpuRate: cpuRate,
                mpsRate: mpsRate,
                cpuVerifyRate: cpuVerifyRate,
                totalCount: totalCount,
                cpuCount: snap.cpuCount,
                mpsCount: snap.mpsCount,
                cpuVerifyCount: snap.cpuVerifyCount,
                cpuAvg: cpuMeanStd?.mean,
                mpsAvg: mpsMeanStd?.mean,
                cpuVerifyAvg: cpuVerifyMeanStd?.mean,
                submitRate: submitRate,
                submitAccepted: submitSnap?.acceptedCount,
                submitRejected: submitSnap?.rejectedCount,
                submitRateLimited: submitSnap?.rateLimitedCount,
                submitFailed: submitSnap?.failedCount,
                queuedCount: submitSnap?.queuedCount,
                bestScore: bestScore,
                processResidentBytes: systemSnap.processResidentBytes,
                processFootprintBytes: systemSnap.processFootprintBytes,
                gpuAllocatedBytes: systemSnap.gpuAllocatedBytes,
                gpuWorkingSetBytes: systemSnap.gpuWorkingSetBytes,
                gpuUtilPercent: systemSnap.gpuUtilPercent
            )
            appendHistory(sample)
        }

        let renderCtx = RenderContext(
            size: size,
            elapsed: elapsed,
            thr: thr,
            top500: top500,
            margin: margin,
            shift: shift,
            progressCount: progressCount,
            totalCount: totalCount,
            cpuRate: cpuRate,
            mpsRate: mpsRate,
            cpuVerifyRate: cpuVerifyRate,
            totalRate: totalRate,
            cpuMeanStd: cpuMeanStd,
            mpsMeanStd: mpsMeanStd,
            cpuVerifyMeanStd: cpuVerifyMeanStd,
            cpuEta: cpuEta,
            mpsEta: mpsEta,
            bestStr: bestStr,
            bestScore: bestScore,
            submitSnap: submitSnap,
            submitRate: submitRate,
            systemSnap: systemSnap
        )

        var lines: [String]
        switch page {
        case .dashboard:
            lines = renderDashboard(renderCtx)
        case .stats:
            lines = renderStats(renderCtx)
        case .events:
            lines = renderEvents(renderCtx)
        case .submissions:
            lines = renderSubmissions(renderCtx)
        }

        if showHelp {
            lines = appendHelp(lines, size: size)
        }

        let out = ANSI.home + ANSI.clearScreen + lines.joined(separator: "\n") + ANSI.clearToEnd
        Terminal.writeStdout(out)
    }

    private func setupInput() {
        guard inputSource == nil else { return }
        guard let raw = Terminal.enableRawMode() else { return }
        rawMode = raw
        let fd = fileno(stdin)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readInput()
        }
        source.resume()
        inputSource = source
    }

    private func readInput() {
        guard let source = inputSource else { return }
        let available = min(4096, Int(source.data))
        guard available > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: available)
        let count = read(fileno(stdin), &buffer, available)
        guard count > 0 else { return }
        inputBuffer.append(contentsOf: buffer.prefix(count))
        handleInputBuffer()
    }

    private func handleInputBuffer() {
        while true {
            guard let key = parseNextKey() else { break }
            handleKey(key)
        }
    }

    private func parseNextKey() -> UIKey? {
        func consume(_ n: Int) {
            inputBuffer.removeFirst(min(n, inputBuffer.count))
        }

        guard !inputBuffer.isEmpty else { return nil }
        let b0 = inputBuffer[0]
        if b0 == 0x1b {
            if inputBuffer.count == 1 {
                consume(1)
                return .escape
            }
            let b1 = inputBuffer[1]
            if b1 == 0x5b {
                if inputBuffer.count < 3 { return nil }
                let b2 = inputBuffer[2]
                switch b2 {
                case 0x41:
                    consume(3)
                    return .up
                case 0x42:
                    consume(3)
                    return .down
                case 0x43:
                    consume(3)
                    return .right
                case 0x44:
                    consume(3)
                    return .left
                case 0x48:
                    consume(3)
                    return .home
                case 0x46:
                    consume(3)
                    return .end
                case 0x5a:
                    consume(3)
                    return .backtab
                case 0x35, 0x36:
                    if inputBuffer.count < 4 { return nil }
                    if inputBuffer[3] == 0x7e {
                        consume(4)
                        return b2 == 0x35 ? .pageUp : .pageDown
                    }
                default:
                    break
                }
            } else if b1 == 0x4f {
                if inputBuffer.count < 3 { return nil }
                let b2 = inputBuffer[2]
                if b2 == 0x48 {
                    consume(3)
                    return .home
                }
                if b2 == 0x46 {
                    consume(3)
                    return .end
                }
            }
            consume(1)
            return .escape
        }

        if b0 == 0x09 {
            consume(1)
            return .tab
        }
        if b0 == 0x0d || b0 == 0x0a {
            consume(1)
            return nil
        }
        if b0 == 0x7f {
            consume(1)
            return nil
        }
        if let scalar = UnicodeScalar(Int(b0)) {
            consume(1)
            return .char(Character(scalar))
        }
        consume(1)
        return nil
    }

    private func handleKey(_ key: UIKey) {
        switch key {
        case .char("1"):
            page = .dashboard
        case .char("2"):
            page = .stats
        case .char("3"):
            page = .events
        case .char("4"):
            page = .submissions
        case .tab:
            page = nextPage()
        case .backtab:
            page = prevPage()
        case .char("?"):
            showHelp.toggle()
        case .escape:
            showHelp = false
        case .left:
            if page == .stats {
                historyOffsetSec += historyStep()
                clampHistoryOffset()
            }
        case .right:
            if page == .stats {
                historyOffsetSec -= historyStep()
                clampHistoryOffset()
            }
        case .home:
            if page == .stats {
                historyOffsetSec = 0
            } else if page == .events {
                eventScrollOffset = 0
            } else if page == .submissions {
                submissionScrollOffset = 0
            }
        case .end:
            if page == .stats {
                historyOffsetSec = maxHistoryOffsetSec()
            } else if page == .events {
                eventScrollOffset = Int.max
            } else if page == .submissions {
                submissionScrollOffset = Int.max
            }
        case .up:
            if page == .events {
                eventScrollOffset = max(0, saturatingAdd(eventScrollOffset, 1))
            } else if page == .submissions {
                submissionScrollOffset = max(0, saturatingAdd(submissionScrollOffset, 1))
            }
        case .down:
            if page == .events {
                eventScrollOffset = max(0, saturatingAdd(eventScrollOffset, -1))
            } else if page == .submissions {
                submissionScrollOffset = max(0, saturatingAdd(submissionScrollOffset, -1))
            }
        case .pageUp:
            let step = max(1, Terminal.stdoutSize().rows - 6)
            if page == .events {
                eventScrollOffset = max(0, saturatingAdd(eventScrollOffset, step))
            } else if page == .submissions {
                submissionScrollOffset = max(0, saturatingAdd(submissionScrollOffset, step))
            }
        case .pageDown:
            let step = max(1, Terminal.stdoutSize().rows - 6)
            if page == .events {
                eventScrollOffset = max(0, saturatingAdd(eventScrollOffset, -step))
            } else if page == .submissions {
                submissionScrollOffset = max(0, saturatingAdd(submissionScrollOffset, -step))
            }
        case .char:
            break
        }
        render()
    }

    private func nextPage() -> Page {
        let next = (page.rawValue + 1) % 4
        return Page(rawValue: next) ?? .dashboard
    }

    private func prevPage() -> Page {
        let prev = (page.rawValue + 3) % 4
        return Page(rawValue: prev) ?? .dashboard
    }

    private func historyStep() -> Double {
        max(5.0, historyWindowSec / 10.0)
    }

    private func clampHistoryOffset() {
        historyOffsetSec = min(max(0, historyOffsetSec), maxHistoryOffsetSec())
    }

    private func saturatingAdd(_ value: Int, _ delta: Int) -> Int {
        if delta > 0, value > Int.max - delta { return Int.max }
        if delta < 0, value < Int.min - delta { return Int.min }
        return value + delta
    }

    private func appendHistory(_ sample: HistorySample) {
        history.append(sample)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        clampHistoryOffset()
    }

    private func maxHistoryOffsetSec() -> Double {
        guard let last = history.last else { return 0 }
        return max(0.0, last.elapsed - historyWindowSec)
    }

    private func renderDashboard(_ rc: RenderContext) -> [String] {
        var lines = buildHeaderLines(rc)
        lines.append(String(repeating: "-", count: rc.size.cols))

        let gap = rc.size.cols >= 80 ? 2 : 1
        let minRight = max(18, rc.size.cols / 3)
        let leftWidth = max(20, rc.size.cols - minRight - gap)
        let rightWidth = max(10, rc.size.cols - leftWidth - gap)

        var left: [String] = []
        if ctx.backend == .cpu || ctx.backend == .all {
            let scale = max(1.0, cpuRateHistory.max() ?? rc.cpuRate)
            let line = meterLine(label: "CPU", rate: rc.cpuRate, avg: rc.cpuMeanStd?.mean, scale: scale, width: leftWidth, color: ANSI.green)
            left.append(line)
        }
        if ctx.backend == .mps || ctx.backend == .all {
            let scale = max(1.0, mpsRateHistory.max() ?? rc.mpsRate)
            let line = meterLine(label: "MPS", rate: rc.mpsRate, avg: rc.mpsMeanStd?.mean, scale: scale, width: leftWidth, color: ANSI.magenta)
            left.append(line)
            let verifyScale = max(1.0, cpuVerifyRateHistory.max() ?? rc.cpuVerifyRate)
            let verifyLine = meterLine(label: "CPUv", rate: rc.cpuVerifyRate, avg: rc.cpuVerifyMeanStd?.mean, scale: verifyScale, width: leftWidth, color: ANSI.green)
            left.append(verifyLine)
        }
        if ctx.backend == .all {
            let scale = max(1.0, totalRateHistory.max() ?? rc.totalRate)
            let line = meterLine(label: "TOTAL", rate: rc.totalRate, avg: nil, scale: scale, width: leftWidth, color: ANSI.cyan)
            left.append(line)
        }

        if left.isEmpty {
            left.append("No backend active")
        }

        left.append("")
        if ctx.backend == .mps || ctx.backend == .all {
            let submitRateStr = rc.submitRate.map { fmtRate($0) } ?? "?"
            left.append("MPS \(fmtRate(rc.mpsRate))/s -> CPUv \(fmtRate(rc.cpuVerifyRate))/s -> Submit \(submitRateStr)/s")
        } else {
            left.append("TOTAL \(fmtRate(rc.totalRate))/s")
        }

        let sparkWidth = max(10, min(leftWidth - 12, 60))
        let spark = sparkline(values: totalRateHistory, width: sparkWidth)
        left.append("\(ANSI.gray)rate 60s \(spark)\(ANSI.reset)")

        var right: [String] = []
        right.append("\(ANSI.bold)Best\(ANSI.reset) \(rc.bestStr)")

        if let cpuEta = rc.cpuEta {
            right.append("ETA top500 ~ \(cpuEta)")
        } else {
            right.append("ETA top500 ~ ?")
        }
        if (ctx.backend == .mps || ctx.backend == .all), let mpsEta = rc.mpsEta {
            right.append("ETA best ~ \(mpsEta)")
        }

        if !ctx.endless, let totalTarget = ctx.totalTarget {
            let pct = totalTarget > 0 ? min(1.0, Double(rc.progressCount) / Double(totalTarget)) : 0.0
            right.append("progress \(String(format: "%.1f", pct * 100))% target=\(fmtCount(UInt64(totalTarget)))")
        }

        if let submitSnap = rc.submitSnap {
            var stats = "submit acc=\(fmtCount(submitSnap.acceptedCount)) rej=\(fmtCount(submitSnap.rejectedCount))"
            if let rate = rc.submitRate {
                stats += " rate=\(fmtRate(rate))/s"
            }
            if submitSnap.queuedCount > 0 {
                stats += " q=\(fmtCount(UInt64(submitSnap.queuedCount)))"
            }
            right.append(stats)
            if submitSnap.queuedCount > 0, let minScore = submitSnap.queuedMinScore, let maxScore = submitSnap.queuedMaxScore,
               minScore.isFinite, maxScore.isFinite {
                right.append("queue range \(fmt(maxScore))..\(fmt(minScore))")
            }
        } else {
            right.append("submit disabled")
        }

        if let rss = rc.systemSnap.processResidentBytes {
            var memLine = "mem rss=\(fmtBytes(rss))"
            if let fp = rc.systemSnap.processFootprintBytes {
                memLine += " fp=\(fmtBytes(fp))"
            }
            right.append(memLine)
        }

        if let gpuAlloc = rc.systemSnap.gpuAllocatedBytes {
            var gpuLine = "gpu mem=\(fmtBytes(gpuAlloc))"
            if let gpuWS = rc.systemSnap.gpuWorkingSetBytes, gpuWS > 0 {
                gpuLine += "/\(fmtBytes(gpuWS))"
            }
            right.append(gpuLine)
        }

        if rc.systemSnap.gpuUtilAvailable || rc.systemSnap.gpuAllocatedBytes != nil {
            let utilStr = rc.systemSnap.gpuUtilPercent.map { fmtPercent($0) } ?? "NA"
            right.append("gpu util=\(utilStr)")
        }

        if ctx.backend == .mps || ctx.backend == .all {
            let profile = ctx.gpuThroughput.currentProfile()
            let pct = Int((profile.factor * 100.0).rounded())
            right.append("gpu profile=\(profile.displayName) (\(pct)%)")
        }

        lines.append(contentsOf: mergeColumns(left: left, right: right, leftWidth: leftWidth, rightWidth: rightWidth, gap: gap))
        lines.append(String(repeating: "-", count: rc.size.cols))
        lines.append(truncateANSI("\(ANSI.bold)Recent events\(ANSI.reset)  (press 3 for full log)", cols: rc.size.cols))

        let remainingRows = max(0, rc.size.rows - lines.count)
        let evs = events.snapshot(limit: remainingRows)
        if evs.isEmpty {
            lines.append("\(ANSI.gray)(no events)\(ANSI.reset)")
        } else {
            for e in evs {
                lines.append(truncateANSI(formatEvent(e), cols: rc.size.cols))
            }
        }

        return fitLines(lines, maxRows: rc.size.rows)
    }

    private func renderStats(_ rc: RenderContext) -> [String] {
        clampHistoryOffset()
        var lines = buildHeaderLines(rc)
        lines.append(String(repeating: "-", count: rc.size.cols))

        let window = historyWindowSamples()
        guard !window.isEmpty else {
            lines.append("\(ANSI.gray)collecting history...\(ANSI.reset)")
            return fitLines(lines, maxRows: rc.size.rows)
        }

        lines.append("\(ANSI.bold)Rates\(ANSI.reset)")
        lines.append(chartLine(label: "TOTAL", values: window.map { $0.totalRate }, width: rc.size.cols) { fmtRate($0) + "/s" })
        if ctx.backend == .cpu || ctx.backend == .all {
            lines.append(chartLine(label: "CPU", values: window.map { $0.cpuRate }, width: rc.size.cols) { fmtRate($0) + "/s" })
        }
        if ctx.backend == .mps || ctx.backend == .all {
            lines.append(chartLine(label: "MPS", values: window.map { $0.mpsRate }, width: rc.size.cols) { fmtRate($0) + "/s" })
            lines.append(chartLine(label: "CPUv", values: window.map { $0.cpuVerifyRate }, width: rc.size.cols) { fmtRate($0) + "/s" })
        }

        lines.append("")
        lines.append("\(ANSI.bold)Scores\(ANSI.reset)")
        let cpuAvg = window.compactMap { $0.cpuAvg }
        lines.append(chartLine(label: "CPU avg", values: cpuAvg, width: rc.size.cols) { fmt($0) })
        let mpsAvg = window.compactMap { $0.mpsAvg }
        if ctx.backend == .mps || ctx.backend == .all {
            lines.append(chartLine(label: "MPS avg", values: mpsAvg, width: rc.size.cols) { fmt($0) })
        }
        let cpuvAvg = window.compactMap { $0.cpuVerifyAvg }
        if ctx.backend == .mps || ctx.backend == .all {
            lines.append(chartLine(label: "CPUv avg", values: cpuvAvg, width: rc.size.cols) { fmt($0) })
        }
        let bestScores = window.compactMap { $0.bestScore }
        lines.append(chartLine(label: "best", values: bestScores, width: rc.size.cols) { fmt($0) })

        lines.append("")
        lines.append("\(ANSI.bold)Submissions\(ANSI.reset)")
        let submitRates = window.compactMap { $0.submitRate }
        lines.append(chartLine(label: "submit/s", values: submitRates, width: rc.size.cols) { fmtRate($0) + "/s" })
        let accCounts = window.compactMap { $0.submitAccepted }.map { Double($0) }
        lines.append(chartLine(label: "accepted", values: accCounts, width: rc.size.cols) { fmtCount(UInt64($0)) })
        let rejCounts = window.compactMap { $0.submitRejected }.map { Double($0) }
        lines.append(chartLine(label: "rejected", values: rejCounts, width: rc.size.cols) { fmtCount(UInt64($0)) })
        let queuedCounts = window.compactMap { $0.queuedCount }.map { Double($0) }
        lines.append(chartLine(label: "queued", values: queuedCounts, width: rc.size.cols) { fmtCount(UInt64($0)) })

        lines.append("")
        lines.append("\(ANSI.bold)System\(ANSI.reset)")
        let rssValues = window.compactMap { $0.processResidentBytes }.map { Double($0) }
        lines.append(chartLine(label: "rss", values: rssValues, width: rc.size.cols) { fmtBytes(UInt64($0)) })
        let fpValues = window.compactMap { $0.processFootprintBytes }.map { Double($0) }
        lines.append(chartLine(label: "footprint", values: fpValues, width: rc.size.cols) { fmtBytes(UInt64($0)) })
        let gpuMemValues = window.compactMap { $0.gpuAllocatedBytes }.map { Double($0) }
        lines.append(chartLine(label: "gpu mem", values: gpuMemValues, width: rc.size.cols) { fmtBytes(UInt64($0)) })
        let gpuUtilValues = window.compactMap { $0.gpuUtilPercent }
        lines.append(chartLine(label: "gpu util", values: gpuUtilValues, width: rc.size.cols) { fmtPercent($0) })

        return fitLines(lines, maxRows: rc.size.rows)
    }

    private func renderEvents(_ rc: RenderContext) -> [String] {
        var lines = buildHeaderLines(rc)
        lines.append(String(repeating: "-", count: rc.size.cols))

        let total = events.count()
        let footerLines = 1
        let visibleRows = max(0, rc.size.rows - lines.count - footerLines)
        let maxOffset = max(0, total - visibleRows)
        eventScrollOffset = min(max(eventScrollOffset, 0), maxOffset)

        let end = max(0, total - eventScrollOffset)
        let start = max(0, end - visibleRows)
        let slice = events.snapshot(from: start, limit: end - start)

        if slice.isEmpty {
            lines.append("\(ANSI.gray)(no events)\(ANSI.reset)")
        } else {
            for e in slice {
                lines.append(truncateANSI(formatEvent(e), cols: rc.size.cols))
            }
        }

        let rangeStr = total == 0 ? "0-0 of 0" : "\(start + 1)-\(end) of \(total)"
        let footer = "\(ANSI.gray)events \(rangeStr)  offset=\(eventScrollOffset)\(ANSI.reset)"
        lines.append(truncateANSI(footer, cols: rc.size.cols))
        return fitLines(lines, maxRows: rc.size.rows)
    }

    private func renderSubmissions(_ rc: RenderContext) -> [String] {
        var lines = buildHeaderLines(rc)
        lines.append(String(repeating: "-", count: rc.size.cols))

        guard let submission else {
            lines.append("\(ANSI.gray)submissions disabled\(ANSI.reset)")
            return fitLines(lines, maxRows: rc.size.rows)
        }

        let total = submission.submissionLogCount()
        let footerLines = 1
        let visibleRows = max(0, rc.size.rows - lines.count - footerLines)
        let maxOffset = max(0, total - visibleRows)
        submissionScrollOffset = min(max(submissionScrollOffset, 0), maxOffset)

        let end = max(0, total - submissionScrollOffset)
        let start = max(0, end - visibleRows)
        let slice = submission.submissionLogSnapshot(from: start, limit: end - start)

        if slice.isEmpty {
            lines.append("\(ANSI.gray)(no submissions yet)\(ANSI.reset)")
        } else {
            for entry in slice {
                lines.append(truncateANSI(formatSubmissionEntry(entry), cols: rc.size.cols))
            }
        }

        let rangeStr = total == 0 ? "0-0 of 0" : "\(start + 1)-\(end) of \(total)"
        let footer = "\(ANSI.gray)submissions \(rangeStr)  offset=\(submissionScrollOffset)\(ANSI.reset)"
        lines.append(truncateANSI(footer, cols: rc.size.cols))
        return fitLines(lines, maxRows: rc.size.rows)
    }

    private func buildHeaderLines(_ rc: RenderContext) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(3)

        let backendStr: String = {
            switch ctx.backend {
            case .cpu: return "\(ANSI.green)cpu\(ANSI.reset)"
            case .mps: return "\(ANSI.magenta)mps\(ANSI.reset)"
            case .all: return "\(ANSI.cyan)all\(ANSI.reset)"
            }
        }()

        let title = "\(ANSI.bold)gobx explore\(ANSI.reset)  backend=\(backendStr)  elapsed=\(formatDuration(rc.elapsed))  \(navTabs())"
        lines.append(truncateANSI(title, cols: rc.size.cols))

        var thrLine = "thr=\(fmt(rc.thr))"
        if rc.top500.isFinite {
            thrLine += "  top500=\(fmt(rc.top500))"
        }
        if (ctx.backend == .mps || ctx.backend == .all) && (rc.margin > 0 || rc.shift > 0) {
            if rc.margin > 0 {
                let trend = ctx.mpsVerifyMargin.trendSymbol()
                thrLine += "  mps-margin=\(fmt(rc.margin))\(trend)"
            }
            if rc.shift > 0 {
                let trend = ctx.mpsScoreShift.trendSymbol()
                thrLine += "  mps-shift=\(fmt(rc.shift))\(trend)"
            }
        }
        lines.append(truncateANSI("\(ANSI.gray)\(thrLine)\(ANSI.reset)", cols: rc.size.cols))

        if page == .stats {
            let windowStr = formatDuration(historyWindowSec)
            let offsetStr = formatDuration(historyOffsetSec)
            let histLine = "\(ANSI.gray)window=\(windowStr)  offset=\(offsetStr)  (Left/Right to pan)\(ANSI.reset)"
            lines.append(truncateANSI(histLine, cols: rc.size.cols))
        }

        return lines
    }

    private func navTabs() -> String {
        func tab(_ label: String, key: String, page target: Page) -> String {
            let text = "[\(key)]\(label)"
            if page == target {
                return "\(ANSI.bold)\(text)\(ANSI.reset)"
            }
            return text
        }
        return [
            tab("Dash", key: "1", page: .dashboard),
            tab("Stats", key: "2", page: .stats),
            tab("Events", key: "3", page: .events),
            tab("Subm", key: "4", page: .submissions),
        ].joined(separator: " ")
    }

    private func appendHelp(_ lines: [String], size: TerminalSize) -> [String] {
        var out = lines
        let helpLines = [
            "\(ANSI.bold)Keys\(ANSI.reset)  1-4 pages  Tab/Shift-Tab  ? help  Esc close help",
            "Stats: Left/Right pan history  Home newest  End oldest",
            "Logs: Up/Down scroll  PgUp/PgDn page  Home newest  End oldest",
        ]
        let needed = helpLines.count + 1
        if out.count + needed > size.rows {
            let drop = min(out.count, out.count + needed - size.rows)
            if drop > 0 {
                out.removeLast(drop)
            }
        }
        out.append(String(repeating: "-", count: size.cols))
        for line in helpLines {
            out.append(truncateANSI(line, cols: size.cols))
        }
        return out
    }

    private func historyWindowSamples() -> [HistorySample] {
        guard let last = history.last else { return [] }
        let end = max(0.0, last.elapsed - historyOffsetSec)
        let start = max(0.0, end - historyWindowSec)
        return history.filter { $0.elapsed >= start && $0.elapsed <= end }
    }

    private func mergeColumns(left: [String], right: [String], leftWidth: Int, rightWidth: Int, gap: Int) -> [String] {
        let rows = max(left.count, right.count)
        var out: [String] = []
        out.reserveCapacity(rows)
        for i in 0..<rows {
            let l = i < left.count ? left[i] : ""
            let r = i < right.count ? right[i] : ""
            let lTrim = truncateANSI(l, cols: leftWidth)
            let padded = padANSI(lTrim, to: leftWidth)
            let rTrim = truncateANSI(r, cols: rightWidth)
            out.append(padded + String(repeating: " ", count: gap) + rTrim)
        }
        return out
    }

    private func meterLine(label: String, rate: Double, avg: Double?, scale: Double, width: Int, color: String) -> String {
        let rateStr = "\(fmtRate(rate))/s"
        let avgStr = avg.map { "avg=\(fmt($0))" } ?? "avg=?"
        let labelStr = "\(color)\(label)\(ANSI.reset)"
        let suffix = "\(rateStr) \(avgStr)"
        let reserved = visibleLength(labelStr) + 3 + suffix.count
        let barWidth = max(4, width - reserved)
        let bar = meterBar(value: rate, max: scale, width: barWidth)
        return "\(labelStr) [\(bar)] \(suffix)"
    }

    private func meterBar(value: Double, max maxValue: Double, width: Int) -> String {
        guard width > 0 else { return "" }
        let scale = maxValue > 0 ? maxValue : 1.0
        let pct = Swift.max(0.0, min(1.0, value / scale))
        let filled = Int((Double(width) * pct).rounded(.down))
        return String(repeating: "#", count: filled) + String(repeating: "-", count: Swift.max(0, width - filled))
    }

    private func chartLine(label: String, values: [Double], width: Int, valueFormatter: (Double) -> String) -> String {
        let labelWidth = 10
        let labelStr = padANSI(label, to: labelWidth)
        let latest = values.last
        let valueStr = latest.map(valueFormatter) ?? "NA"
        let valueLen = valueStr.count
        let sparkWidth = max(0, width - labelWidth - valueLen - 2)
        if sparkWidth == 0 || values.isEmpty {
            return truncateANSI("\(labelStr) \(valueStr)", cols: width)
        }
        let reduced = downsample(values: values, width: sparkWidth)
        let spark = sparkline(values: reduced, width: sparkWidth)
        let line = "\(labelStr) \(spark) \(valueStr)"
        return truncateANSI(line, cols: width)
    }

    private func downsample(values: [Double], width: Int) -> [Double] {
        guard width > 0 else { return [] }
        guard values.count > width else { return values }
        var out: [Double] = []
        out.reserveCapacity(width)
        let step = Double(values.count) / Double(width)
        var idx = 0.0
        for _ in 0..<width {
            let start = Int(idx)
            let end = Int(min(Double(values.count), idx + step))
            let sliceEnd = max(start + 1, end)
            let slice = values[start..<sliceEnd]
            let avg = slice.reduce(0.0, +) / Double(slice.count)
            out.append(avg)
            idx += step
        }
        return out
    }

    private func fitLines(_ lines: [String], maxRows: Int) -> [String] {
        guard lines.count > maxRows else { return lines }
        return Array(lines.prefix(maxRows))
    }

    private func formatSubmissionEntry(_ e: SubmissionLogEntry) -> String {
        let t = timeHHMMSS(e.time)
        let kindLabel: String = {
            switch e.kind {
            case .accepted: return "\(ANSI.green)ACC\(ANSI.reset)"
            case .rejected: return "\(ANSI.yellow)REJ\(ANSI.reset)"
            case .rateLimited: return "\(ANSI.yellow)RL\(ANSI.reset)"
            case .failed: return "\(ANSI.red)FAIL\(ANSI.reset)"
            }
        }()
        let scoreStr = e.score.isFinite ? fmt(e.score) : "?"
        let rankStr = e.rank.map { "#\($0)" } ?? "-"
        let pctStr = e.difficultyPercentile.map { String(format: " p=%.2f%%", $0 * 100.0) } ?? ""
        let msgStr = e.message.map { " \($0)" } ?? ""
        let sourceStr = e.source.map { " (\($0))" } ?? ""
        return "\(ANSI.gray)[\(t)]\(ANSI.reset) \(kindLabel) seed=\(e.seed) score=\(scoreStr) \(rankStr)\(pctStr)\(msgStr)\(sourceStr)"
    }

    private func formatEvent(_ e: ExploreEvent) -> String {
        let t = timeHHMMSS(e.time)
        let prefix: String = {
            switch e.kind {
            case .info: return "\(ANSI.gray)[\(t)]\(ANSI.reset)"
            case .warning: return "\(ANSI.yellow)[\(t)]\(ANSI.reset)"
            case .best: return "\(ANSI.cyan)[\(t)]\(ANSI.reset)"
            case .accepted: return "\(ANSI.green)[\(t)]\(ANSI.reset)"
            case .rejected: return "\(ANSI.yellow)[\(t)]\(ANSI.reset)"
            case .error: return "\(ANSI.red)[\(t)]\(ANSI.reset)"
            }
        }()
        return "\(prefix) \(e.message)"
    }

    private func timeHHMMSS(_ d: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: .current, from: d)
        let h = c.hour ?? 0
        let m = c.minute ?? 0
        let s = c.second ?? 0
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func push(_ arr: inout [Double], _ v: Double, cap: Int) {
        arr.append(max(0.0, v))
        if arr.count > cap {
            arr.removeFirst(arr.count - cap)
        }
    }

    private func truncateANSI(_ s: String, cols: Int) -> String {
        guard cols > 0 else { return "" }

        var out = ""
        out.reserveCapacity(min(s.count, cols + 16))

        var visible = 0
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\u{1b}" {
                let escStart = idx
                idx = s.index(after: idx)
                if idx < s.endIndex, s[idx] == "[" {
                    idx = s.index(after: idx)
                    while idx < s.endIndex {
                        let u = s[idx].unicodeScalars.first?.value ?? 0
                        idx = s.index(after: idx)
                        if u >= 0x40 && u <= 0x7E { break } // CSI terminator
                    }
                    out.append(contentsOf: s[escStart..<idx])
                    continue
                }
                out.append(ch)
                continue
            }

            if visible >= cols { break }
            out.append(ch)
            visible += 1
            idx = s.index(after: idx)
        }

        if out.count < s.count, out.contains(ANSI.esc) {
            out.append(ANSI.reset)
        }
        return out
    }

    private func visibleLength(_ s: String) -> Int {
        var visible = 0
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\u{1b}" {
                idx = s.index(after: idx)
                if idx < s.endIndex, s[idx] == "[" {
                    idx = s.index(after: idx)
                    while idx < s.endIndex {
                        let u = s[idx].unicodeScalars.first?.value ?? 0
                        idx = s.index(after: idx)
                        if u >= 0x40 && u <= 0x7E { break }
                    }
                    continue
                }
                continue
            }
            visible += 1
            idx = s.index(after: idx)
        }
        return visible
    }

    private func padANSI(_ s: String, to width: Int) -> String {
        let visible = visibleLength(s)
        if visible >= width { return truncateANSI(s, cols: width) }
        return s + String(repeating: " ", count: max(0, width - visible))
    }

    private func fmt(_ x: Double) -> String {
        String(format: "%.6f", x)
    }

    private func fmtRate(_ r: Double) -> String {
        if r >= 1000 {
            return String(format: "%.0f", r)
        }
        return String(format: "%.1f", r)
    }

    private func fmtCount(_ n: UInt64) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func fmtBytes(_ n: UInt64) -> String {
        let kb = Double(n) / 1024.0
        if kb < 1024 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.2fM", mb) }
        let gb = mb / 1024.0
        if gb < 1024 { return String(format: "%.2fG", gb) }
        let tb = gb / 1024.0
        return String(format: "%.2fT", tb)
    }

    private func fmtPercent(_ v: Double) -> String {
        if !v.isFinite { return "NA" }
        return String(format: "%.0f%%", v)
    }

    private func meanStd(count: UInt64, sum: Double, sumSq: Double) -> (mean: Double, std: Double)? {
        guard count >= 2 else { return nil }
        let n = Double(count)
        let mean = sum / n
        var varPop = (sumSq / n) - (mean * mean)
        if varPop < 0 { varPop = 0 }
        let std = sqrt(varPop)
        guard mean.isFinite, std.isFinite else { return nil }
        return (mean, std)
    }

    private func etaString(rate: Double, meanStd: (mean: Double, std: Double)?, threshold: Double) -> String? {
        guard threshold.isFinite else { return nil }
        guard rate.isFinite, rate > 0 else { return nil }
        guard let ms = meanStd, ms.std.isFinite else { return nil }
        guard ms.std > 0 else {
            return ms.mean > threshold ? "now" : nil
        }

        let z = (threshold - ms.mean) / ms.std
        let p = 1.0 - normalCDF(z)
        guard p.isFinite, p > 0 else { return nil }
        let hitsPerSec = rate * p
        guard hitsPerSec.isFinite, hitsPerSec > 0 else { return nil }
        return formatDuration(1.0 / hitsPerSec)
    }

    private func normalCDF(_ z: Double) -> Double {
        0.5 * (1.0 + Darwin.erf(z / sqrt(2.0)))
    }

    private func formatDuration(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds <= 0 { return "0s" }
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let ss = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(ss)s" }
        return "\(ss)s"
    }

    private func sparkline(values: [Double], width: Int) -> String {
        let chars = Array("▁▂▃▄▅▆▇█")
        let w = max(1, width)
        let tail = values.suffix(w)
        guard let maxV = tail.max(), maxV > 0 else {
            return String(repeating: String(chars.first ?? " "), count: tail.count)
        }
        var out = ""
        out.reserveCapacity(tail.count)
        for v in tail {
            let t = max(0.0, min(1.0, v / maxV))
            let idx = Int((t * 7.0).rounded())
            out.append(chars[min(7, max(0, idx))])
        }
        return out
    }
}
