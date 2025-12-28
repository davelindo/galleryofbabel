import Dispatch
import Darwin
import Foundation

final class ExploreLiveUI: @unchecked Sendable {
    struct Context {
        let backend: Backend
        let endless: Bool
        let totalTarget: Int?
        let mpsVerifyMargin: AdaptiveMargin
        let mpsScoreShift: AdaptiveScoreShift
        let minScore: Double
    }

    private let ctx: Context
    private let stats: ExploreStats
    private let best: BestTracker
    private let bestApprox: ApproxBestTracker
    private let submission: SubmissionManager?
    private let events: ExploreEventLog
    private let refreshEverySec: Double

    private let queue = DispatchQueue(label: "gobx.ui", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var started = false
    private var startNs: UInt64 = 0
    private var lastSnap: ExploreStats.Snapshot
    private var lastNs: UInt64 = 0
    private var lastSubmitSnap: SubmissionManager.StatsSnapshot? = nil
    private var totalRateHistory: [Double] = []
    private var cpuRateHistory: [Double] = []
    private var mpsRateHistory: [Double] = []

    init(
        context: Context,
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
    }

    func start() {
        guard !started else { return }
        started = true

        Terminal.writeStdout(ANSI.altScreenOn + ANSI.hideCursor + ANSI.clearScreen + ANSI.home)

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

        let elapsed = Double(now &- startNs) / 1e9
        let size = Terminal.stdoutSize()

        let topSnap = submission?.stateSnapshot()
        let thr = submission?.effectiveThreshold() ?? ctx.minScore
        let top500 = topSnap?.top500Threshold ?? .nan
        let submitSnap = submission?.statsSnapshot()

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

        let cpuMeanStd = meanStd(count: snap.cpuCount, sum: snap.cpuScoreSum, sumSq: snap.cpuScoreSumSq)
        let cpuVerifyMeanStd = meanStd(count: snap.cpuVerifyCount, sum: snap.cpuVerifyScoreSum, sumSq: snap.cpuVerifyScoreSumSq)
        let mpsMeanStd = meanStd(count: snap.mpsCount, sum: snap.mpsScoreSum, sumSq: snap.mpsScoreSumSq)

        let cpuEta = etaString(rate: cpuRate, meanStd: cpuMeanStd, threshold: thr)
        let margin = ctx.mpsVerifyMargin.current()
        let shift = ctx.mpsScoreShift.current()
        let bestTarget: Double = {
            if bestSnap.score.isFinite { return bestSnap.score }
            if approxSnap.score.isFinite { return Double(approxSnap.score) }
            return .nan
        }()
        let mpsEta = etaString(rate: mpsRate, meanStd: mpsMeanStd, threshold: bestTarget)

        var lines: [String] = []
        lines.reserveCapacity(size.rows)

        let backendStr: String = {
            switch ctx.backend {
            case .cpu: return "\(ANSI.green)cpu\(ANSI.reset)"
            case .mps: return "\(ANSI.magenta)mps\(ANSI.reset)"
            case .all: return "\(ANSI.cyan)all\(ANSI.reset)"
            }
        }()

        let title = "\(ANSI.bold)gobx explore\(ANSI.reset)  backend=\(backendStr)  elapsed=\(formatDuration(elapsed))"
        lines.append(truncateANSI(title, cols: size.cols))

        var thrLine = "thr=\(fmt(thr))"
        if top500.isFinite {
            thrLine += "  top500=\(fmt(top500))"
        }
        if (ctx.backend == .mps || ctx.backend == .all) && (margin > 0 || shift > 0) {
            if margin > 0 {
                let trend = ctx.mpsVerifyMargin.trendSymbol()
                thrLine += "  mps-margin=\(fmt(margin))\(trend)"
            }
            if shift > 0 {
                let trend = ctx.mpsScoreShift.trendSymbol()
                thrLine += "  mps-shift=\(fmt(shift))\(trend)"
            }
        }
        lines.append(truncateANSI("\(ANSI.gray)\(thrLine)\(ANSI.reset)", cols: size.cols))

        lines.append(String(repeating: "─", count: min(size.cols, 80)))

        if ctx.backend == .cpu || ctx.backend == .all {
            let meanStr = cpuMeanStd.map { "avg=\(fmt($0.mean)) σ=\(fmt($0.std))" } ?? "avg=?"
            let etaStr = cpuEta.map { "ETA(top500)≈\($0)" } ?? "ETA(top500)=?"
            lines.append(truncateANSI("\(ANSI.green)CPU\(ANSI.reset)  \(fmtCount(snap.cpuCount))  \(fmtRate(cpuRate))/s  \(meanStr)  \(etaStr)", cols: size.cols))
        }

        if ctx.backend == .mps || ctx.backend == .all {
            let meanStr = mpsMeanStd.map { "avg=\(fmt($0.mean)) σ=\(fmt($0.std))" } ?? "avg=?"
            let etaStr = mpsEta.map { "ETA(best)≈\($0)" } ?? "ETA(best)=?"
            lines.append(truncateANSI("\(ANSI.magenta)MPS\(ANSI.reset)  \(fmtCount(snap.mpsCount))  \(fmtRate(mpsRate))/s  \(meanStr)  \(etaStr)", cols: size.cols))
            let meanVerify = cpuVerifyMeanStd.map { "avg=\(fmt($0.mean)) σ=\(fmt($0.std))" } ?? "avg=?"
            lines.append(truncateANSI("\(ANSI.green)CPUv\(ANSI.reset)  \(fmtCount(snap.cpuVerifyCount))  \(fmtRate(cpuVerifyRate))/s  \(meanVerify)", cols: size.cols))
        }

        let progressCount = snap.cpuCount &+ snap.mpsCount
        let totalCount = progressCount &+ snap.cpuVerifyCount
        lines.append(truncateANSI("\(ANSI.cyan)TOTAL\(ANSI.reset) \(fmtCount(totalCount))  \(fmtRate(totalRate))/s  best=\(bestStr)", cols: size.cols))

        let sparkWidth = max(10, min(size.cols - 18, 60))
        let spark = sparkline(values: totalRateHistory, width: sparkWidth)
        let sparkLine = "\(ANSI.gray)rate 60s \(spark)\(ANSI.reset)"
        lines.append(truncateANSI(sparkLine, cols: size.cols))

        if !ctx.endless, let totalTarget = ctx.totalTarget {
            let pct = totalTarget > 0 ? min(1.0, Double(progressCount) / Double(totalTarget)) : 0.0
            lines.append(truncateANSI("\(ANSI.gray)progress \(String(format: "%.1f", pct * 100))%  target=\(fmtCount(UInt64(totalTarget)))\(ANSI.reset)", cols: size.cols))
        }

        lines.append("")

        if let submission {
            func formatAcceptedLine(_ a: SubmissionManager.AcceptedSeed) -> String {
                let rankStr = a.rank.map { "#\($0)" } ?? "-"
                let pctStr = a.difficultyPercentile.map { String(format: " p=%.2f%%", $0 * 100.0) } ?? ""
                return "\(ANSI.green)\(rankStr)\(ANSI.reset) score=\(fmt(a.score)) seed=\(a.seed)\(pctStr)\(a.source.map { " (\($0))" } ?? "")"
            }

            var header = "Accepted (latest)"
            if let submitSnap {
                let prior = lastSubmitSnap
                let submitDelta = prior.map { Double(submitSnap.submitAttempts &- $0.submitAttempts) } ?? 0.0
                let submitRate = dt > 0 ? submitDelta / dt : 0.0
                var stats = "acc=\(fmtCount(submitSnap.acceptedCount)) rej=\(fmtCount(submitSnap.rejectedCount)) rate=\(fmtRate(submitRate))/s"
                if submitSnap.queuedCount > 0 {
                    stats += " queued=\(fmtCount(UInt64(submitSnap.queuedCount)))"
                    if let minScore = submitSnap.queuedMinScore, let maxScore = submitSnap.queuedMaxScore, minScore.isFinite, maxScore.isFinite {
                        stats += " range=\(fmt(maxScore))..\(fmt(minScore))"
                    }
                }
                header += " (\(stats))"
                lastSubmitSnap = submitSnap
            }
            lines.append("\(ANSI.bold)\(header)\(ANSI.reset)")
            let acceptedBest = submission.acceptedBestSnapshot(limit: 3)
            if !acceptedBest.isEmpty {
                lines.append("\(ANSI.gray)best by difficulty\(ANSI.reset)")
                for a in acceptedBest {
                    lines.append(truncateANSI(formatAcceptedLine(a), cols: size.cols))
                }
                lines.append("")
            }
            let accepted = submission.acceptedSnapshot(limit: 5)
            if accepted.isEmpty {
                lines.append("\(ANSI.gray)(none yet)\(ANSI.reset)")
            } else {
                for a in accepted {
                    lines.append(truncateANSI(formatAcceptedLine(a), cols: size.cols))
                }
            }
            lines.append("")
        }

        lines.append("\(ANSI.bold)Events\(ANSI.reset)")
        let remainingRows = max(0, size.rows - lines.count)
        let evs = events.snapshot(limit: remainingRows)
        if evs.isEmpty {
            lines.append("\(ANSI.gray)(no events)\(ANSI.reset)")
        } else {
            for e in evs {
                lines.append(truncateANSI(formatEvent(e), cols: size.cols))
            }
        }

        let out = ANSI.home + ANSI.clearScreen + lines.joined(separator: "\n") + ANSI.clearToEnd
        Terminal.writeStdout(out)
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
