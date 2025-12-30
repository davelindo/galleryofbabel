import AppKit
import SwiftUI
import GobxCore

@MainActor
struct MenuContentView: View {
    @ObservedObject var model: ExploreMenuModel
    @Namespace private var animationNamespace

    var body: some View {
        ZStack {
            AppTheme.popoverBackground
                .ignoresSafeArea()

            VStack(spacing: 6) {
                headerView

                Divider()
                    .opacity(0.5)

                contentContainer
                    .frame(maxHeight: .infinity)

                Divider()
                    .opacity(0.5)

                footerView
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.clear)

            if model.showSetupWizard {
                SetupWizardView(model: model)
            }
        }
        .frame(minWidth: 400, idealWidth: 430, maxWidth: 500)
        .frame(minHeight: 460, idealHeight: 560, maxHeight: 680)
    }

    private var headerView: some View {
        let tabs = MenuTab.allCases
        return HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                TabButton(tab: tab, selected: $model.selectedTab, namespace: animationNamespace)
                if index < tabs.count - 1 {
                    Rectangle()
                        .fill(AppTheme.tabSeparator)
                        .frame(width: 1)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var contentContainer: some View {
        switch model.selectedTab {
        case .dashboard:
            ScrollView(showsIndicators: true) {
                DashboardView(model: model)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
            }
            .scrollIndicatorsVisible()
            .frame(maxHeight: .infinity)
        case .stats:
            ScrollView(showsIndicators: true) {
                StatsView(model: model)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
            }
            .scrollIndicatorsVisible()
            .frame(maxHeight: .infinity)
        case .events:
            EventsListView(events: model.events)
                .frame(maxHeight: .infinity)
        case .submissions:
            SubmissionsListView(submissions: model.submissions)
                .frame(maxHeight: .infinity)
        case .settings:
            SettingsView(model: model)
                .frame(maxHeight: .infinity)
        }
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    Text(formatDuration(model.summary.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Text("Gobx Explore")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Group {
                if model.isRunning {
                    ControlButton(
                        icon: model.isPaused ? "play.fill" : "pause.fill",
                        action: { model.togglePause() },
                        activeColor: model.isPaused ? AppTheme.warn : AppTheme.ok,
                        isActive: true
                    )
                        .help(model.isPaused ? "Resume" : "Pause")

                    ControlButton(icon: "stop.fill", action: { model.stop() })
                        .help("Stop Engine")
                } else {
                    ControlButton(
                        icon: "play.fill",
                        action: { model.start() },
                        activeColor: .secondary,
                        isActive: true
                    )
                        .help("Start Engine")
                }

                Divider().frame(height: 16)

                ControlButton(icon: "power", action: { NSApplication.shared.terminate(nil) })
                    .help("Quit")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let ss = s % 60
        return String(format: "%02d:%02d:%02d", h, m, ss)
    }
}

struct DashboardView: View {
    @ObservedObject var model: ExploreMenuModel

    var body: some View {
        let rankText = model.summary.personalBestPreviousRank.map { "#\($0)" } ?? "--"

        VStack(spacing: 16) {
            GlassCard {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MetricInline(
                            value: fmtRate(model.summary.totalRate),
                            label: "seeds/s",
                            color: AppTheme.accent,
                            animateValue: model.summary.totalRate
                        )

                        Text("•")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        MetricInline(
                            value: fmtCount(model.summary.totalCount),
                            label: "total",
                            color: AppTheme.gpu
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.vertical, 8)

                    HStack(spacing: 0) {
                        if model.summary.backend == .mps || model.summary.backend == .all {
                            CompactMetric(label: "MPS", value: fmtRate(model.summary.mpsRate), icon: "bolt.fill", color: AppTheme.gpu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CompactMetric(label: "CPUv", value: fmtRate(model.summary.cpuVerifyRate), icon: "cpu", color: AppTheme.cpu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            CompactMetric(label: "CPU", value: fmtRate(model.summary.cpuRate), icon: "cpu", color: AppTheme.cpu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        CompactMetric(label: "Rank", value: rankText, icon: "list.number", color: AppTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CompactMetric(label: "Accepted", value: fmtCount(model.summary.submitStats?.acceptedCount ?? 0), icon: "checkmark.circle.fill", color: AppTheme.ok)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                EnergyRibbon(profile: model.throughputProfile)
                    .offset(x: -6, y: 6)
            }

            if model.summary.bestScore != nil || model.summary.topBestScore != nil || model.summary.personalBestPreviousScore != nil {
                GlassCard(
                    title: "Performance",
                    icon: "trophy.fill",
                    headerTrailing: {
                        if let top = model.summary.topBestScore {
                            SeedHoverLabel(seed: model.summary.topBestSeed, source: "Leaderboard") {
                                Text("Current #1: \(String(format: "%.6f", top))")
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        let best = model.summary.bestScore
                        let previous = model.summary.personalBestPreviousScore
                        let cpuvSeries = model.history.map { $0.cpuVerifyRate }
                        let missSeries = model.history.map { $0.submitMisses }

                        if best != nil || previous != nil {
                            HStack(alignment: .top, spacing: 16) {
                                if let best {
                                    SeedHoverLabel(seed: model.summary.bestSeed, source: model.summary.bestSource) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("This run")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.6f", best))
                                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if let previous {
                                    SeedHoverLabel(seed: model.summary.personalBestPreviousSeed, source: "All-time best") {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Personal best (all time)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.6f", previous))
                                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        if !cpuvSeries.isEmpty {
                            RateTrendView(
                                values: cpuvSeries,
                                misses: missSeries,
                                tint: AppTheme.cpu
                            )
                            .frame(height: 34)
                        }
                    }
                    .padding(16)
                }
            }

            GlassCard(title: "Top 3 Accepted", icon: "list.number") {
                VStack(spacing: 0) {
                    if model.leaderboard.isEmpty {
                        Text("No accepted scores yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    } else {
                        let entries = Array(model.leaderboard.prefix(3))
                        ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                            let rankText = entry.rank.map { "#\($0)" } ?? "#--"
                            let seedText = "seed \(entry.seed)"
                            HStack(spacing: 8) {
                                Text(verbatim: rankText)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(minWidth: 64, alignment: .leading)
                                    .lineLimit(1)

                                Text(verbatim: String(format: "%.6f", entry.score))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)

                                Text(verbatim: seedText)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)

                            if idx < entries.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }

}

struct StatsView: View {
    @ObservedObject var model: ExploreMenuModel

    var body: some View {
        let hasSocPower = model.history.contains { $0.socPowerWatts != nil }
        let socPowerSeries = model.history.map { $0.socPowerWatts ?? 0 }
        let hasEfficiency = model.history.contains { ($0.socPowerWatts ?? 0) > 0 }
        let efficiencySeries = model.history.map { point in
            guard let power = point.socPowerWatts, power > 0 else { return 0.0 }
            return point.totalRate / power
        }
        let hasTemp = model.history.contains { $0.socTempC != nil }
        let tempSeries: [Double] = {
            var out: [Double] = []
            out.reserveCapacity(model.history.count)
            var last: Double? = nil
            for point in model.history {
                if let value = point.socTempC {
                    last = value
                }
                out.append(last ?? 0)
            }
            return out
        }()

        VStack(spacing: 16) {
            ChartCard(
                title: "Throughput (Total)",
                value: model.history.map { $0.totalRate },
                color: AppTheme.accent,
                formatter: fmtRate
            )

            if model.summary.backend == .mps || model.summary.backend == .all {
                HStack(spacing: 12) {
                    ChartCard(
                        title: "MPS Rate",
                        value: model.history.map { $0.mpsRate },
                        color: AppTheme.gpu,
                        height: 80,
                        formatter: fmtRate
                    )
                    ChartCard(
                        title: "CPU Rate",
                        value: model.history.map { $0.cpuRate },
                        color: AppTheme.cpu,
                        height: 80,
                        formatter: fmtRate
                    )
                }
            }

            if hasEfficiency {
                ChartCard(
                    title: "Efficiency (seeds/W)",
                    value: efficiencySeries,
                    color: AppTheme.ok,
                    height: 80,
                    formatter: fmtRate,
                    skipZerosForStats: true
                )
            }

            if hasSocPower {
                ChartCard(
                    title: "SoC Power",
                    value: socPowerSeries,
                    color: AppTheme.warn,
                    height: 80,
                    formatter: fmtWatts,
                    skipZerosForStats: true
                )
            }

            if hasTemp {
                ChartCard(
                    title: "SoC Temp",
                    value: tempSeries,
                    color: AppTheme.warn,
                    height: 80,
                    formatter: { String(format: "%.0f C", $0) },
                    skipZerosForStats: true
                )
            }

            GlassCard(title: "System Load", icon: "memorychip") {
                VStack(spacing: 12) {
                    HStack {
                        let gpuUtil = model.summary.system.gpuUtilPercent
                        Gauge(value: gpuUtil ?? 0, in: 0...100) {
                            Text("GPU Util")
                        } currentValueLabel: {
                            Text(gpuUtil.map { "\(Int($0))%" } ?? "NA")
                        }
                        .gaugeStyle(.accessoryCircular)
                        .tint(gpuUtil == nil ? .secondary : AppTheme.gpu)

                        Spacer()

                        VStack(alignment: .trailing) {
                            if model.summary.system.power.available {
                                SysRow(label: "SoC Power", value: fmtWatts(model.summary.system.power.systemLoadWatts))
                                SysRow(label: "SoC Temp", value: fmtTempC(model.summary.system.power.temperatureC))
                            }
                            SysRow(label: "GPU Mem", value: fmtBytes(model.summary.system.gpuAllocatedBytes))
                            if let watts = model.summary.system.gpuPowerWatts {
                                SysRow(label: "GPU Power", value: String(format: "%.1f W", watts))
                            }
                            SysRow(label: "RAM RSS", value: fmtBytes(model.summary.system.processResidentBytes))
                        }
                    }
                }
                .padding(16)
            }

            if let submit = model.summary.submitStats, submit.queuedCount > 0 {
                GlassCard(title: "Queued Submissions", icon: "tray.full") {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Queued")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(submit.queuedCount)")
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 6) {
                            Text("Min / Max")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(fmtScore(submit.queuedMinScore)) / \(fmtScore(submit.queuedMaxScore))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct EventsListView: View {
    let events: [ExploreEvent]

    var body: some View {
        let items = Array(events.reversed())
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    "No events",
                    systemImage: "bell.slash",
                    description: Text("Start Explore to see activity here.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                    LogLineView(
                        time: e.time,
                        message: e.message,
                        color: colorForEvent(e.kind)
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    func colorForEvent(_ kind: ExploreEventKind) -> Color {
        switch kind {
        case .info: return .secondary
        case .warning: return AppTheme.warn
        case .best: return AppTheme.accent
        case .accepted: return AppTheme.ok
        case .rejected: return .secondary
        case .error: return AppTheme.error
        }
    }
}

struct SubmissionsListView: View {
    let submissions: [SubmissionLogEntry]

    var body: some View {
        let items = submissions
            .filter { $0.kind != .rateLimited }
            .sorted {
                let lhsScore = $0.score.isFinite ? $0.score : -Double.infinity
                let rhsScore = $1.score.isFinite ? $1.score : -Double.infinity
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return $0.time > $1.time
            }
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    "No submissions",
                    systemImage: "paperplane",
                    description: Text("Accepted or rejected submissions appear here.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    SubmissionLineView(
                        time: s.time,
                        score: s.score,
                        rank: s.rank,
                        seed: s.seed,
                        color: colorForSub(s.kind)
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    func colorForSub(_ kind: SubmissionLogKind) -> Color {
        switch kind {
        case .accepted: return AppTheme.ok
        case .rejected: return AppTheme.warn
        case .rateLimited: return .secondary
        case .failed: return AppTheme.error
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ExploreMenuModel

    var body: some View {
        Form {
            Section {
                energySection
            } header: {
                Label("Energy", systemImage: "bolt.fill")
            }

            Section {
                TextField("Profile ID", text: $model.profileId)
                    .textFieldStyle(.roundedBorder)
                TextField("Display Name", text: $model.profileName)
                    .textFieldStyle(.roundedBorder)
                TextField("X Handle (optional)", text: $model.profileX)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Save") { model.saveConfigChanges() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .tint(AppTheme.accent)
                }

                if let message = model.configStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Profile", systemImage: "person.crop.circle")
            }

            Section {
                Toggle("Do not sleep on AC power", isOn: Binding(
                    get: { model.preventSleepOnAC },
                    set: { model.setPreventSleepOnAC($0) }
                ))
                LabeledContent("Status") {
                    Text(model.sleepGuardActive ? "Preventing sleep" : "Waiting for AC")
                        .foregroundStyle(model.sleepGuardActive ? AppTheme.ok : .secondary)
                }
            } header: {
                Label("Sleep", systemImage: "moon.zzz")
            }

            Section {
                Toggle("Opt into anonymous performance stats", isOn: $model.statsEnabled)

                if !model.statsUrl.isEmpty {
                    LabeledContent("Endpoint") {
                        Text(model.statsUrl)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Restart explore to apply changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Stats", systemImage: "chart.line.uptrend.xyaxis")
            }

            Section {
                Link(destination: URL(string: "https://github.com/davelindo/galleryofbabel")!) {
                    HStack(spacing: 6) {
                        githubLogoImage()
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                        Text("GitHub")
                    }
                }
                Link(destination: URL(string: "https://www.echohive.ai/gallery-of-babel/")!) {
                    Label("Gallery of Babel", systemImage: "globe")
                }
                Link(destination: URL(string: "https://gobx-stats.davelindon.me/stats")!) {
                    Label("Stats Endpoint", systemImage: "waveform.path.ecg")
                }
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var energySection: some View {
        let profile = model.throughputProfile
        let minFactor = energyProfiles.first?.factor ?? 0.1
        let maxFactor = energyProfiles.last?.factor ?? 1.0
        let sliderPadding: CGFloat = 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(profile.marketingName, systemImage: energyIcon(profile))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(Int(profile.factor * 100))% GPU")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.gpu)
            }

            Slider(value: energyValue, in: minFactor...maxFactor)
                .tint(AppTheme.gpu)
                .padding(.horizontal, sliderPadding)
                .frame(maxWidth: .infinity)

            EnergyScaleView(profiles: energyProfiles, selected: profile, trackInset: sliderPadding)
        }
    }

    private var energyProfiles: [GPUThroughputProfile] {
        GPUThroughputProfile.allCases.sorted { $0.factor < $1.factor }
    }

    private var energyValue: Binding<Double> {
        Binding(
            get: { model.throughputProfile.factor },
            set: { newValue in
                let next = nearestProfile(for: newValue)
                if next != model.throughputProfile {
                    model.setThroughputProfile(next)
                }
            }
        )
    }

    private func nearestProfile(for value: Double) -> GPUThroughputProfile {
        energyProfiles.min(by: { abs($0.factor - value) < abs($1.factor - value) }) ?? model.throughputProfile
    }
}

struct GlassCard<Content: View, HeaderTrailing: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var headerTrailing: HeaderTrailing
    var content: Content

    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) where HeaderTrailing == EmptyView {
        self.title = title
        self.icon = icon
        self.headerTrailing = EmptyView()
        self.content = content()
    }

    init(
        title: String?,
        icon: String? = nil,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        GroupBox(label: headerLabel) {
            content
        }
        .groupBoxStyle(GlassGroupBoxStyle(showLabel: title != nil))
    }

    @ViewBuilder
    private var headerLabel: some View {
        if let title {
            HStack {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                headerTrailing
            }
        }
    }
}

private struct GlassGroupBoxStyle: GroupBoxStyle {
    let showLabel: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: showLabel ? 10 : 0) {
            if showLabel {
                configuration.label
                    .foregroundStyle(.primary)
            }
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

struct ChartCard: View {
    let title: String
    let value: [Double]
    let color: Color
    var height: CGFloat = 100
    var formatter: (Double) -> String = { String(format: "%.2f", $0) }
    var skipZerosForStats: Bool = false

    var body: some View {
        let statsValues = filteredStatsValues()
        let minVal = statsValues.min()
        let maxVal = statsValues.max()
        let latestVal = value.last ?? 0

        GlassCard(title: title, headerTrailing: {
            Text(formatter(latestVal))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }) {
            VStack(spacing: 6) {
                Sparkline(values: value, tint: color)
                    .frame(height: height)

                if let minVal, let maxVal {
                    HStack {
                        Text("min \(formatter(minVal))")
                        Spacer()
                        Text("max \(formatter(maxVal))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private func filteredStatsValues() -> [Double] {
        let filtered = skipZerosForStats ? value.filter { $0 > 0 } : value
        return filtered.isEmpty ? value : filtered
    }
}

struct TabButton: View {
    let tab: MenuTab
    @Binding var selected: MenuTab
    let namespace: Namespace.ID

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { selected = tab }
        } label: {
            ZStack {
                if selected == tab {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.tabSelectedFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(AppTheme.tabSelectedStroke, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "TABBG", in: namespace)
                }
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected == tab ? AppTheme.accent : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let points = downsample(values: values, target: Int(w))
            let maxVal = (points.max() ?? 1.0) * 1.1
            let minVal = 0.0

            ZStack {
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(points.count - 1)
                        let y = h * (1 - CGFloat((v - minVal) / (maxVal - minVal)))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))

                Path { path in
                    guard points.count > 1 else { return }
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(points.count - 1)
                        let y = h * (1 - CGFloat((v - minVal) / (maxVal - minVal)))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    func downsample(values: [Double], target: Int) -> [Double] {
        guard values.count > target, target > 0 else { return values }
        let chunkSize = Int(ceil(Double(values.count) / Double(target)))
        return stride(from: 0, to: values.count, by: chunkSize).map {
            let end = min($0 + chunkSize, values.count)
            return values[$0..<end].reduce(0, +) / Double(end - $0)
        }
    }
}

struct RateTrendView: View {
    let values: [Double]
    let misses: [UInt64]
    let tint: Color

    var body: some View {
        let cleanValues = values.map { $0.isFinite ? max(0.0, $0) : 0.0 }
        let cleanMisses: [UInt64] = {
            guard misses.count == values.count else {
                return Array(repeating: 0, count: values.count)
            }
            return misses
        }()

        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let target = max(2, Int(w))
            let (points, missBins) = downsample(values: cleanValues, misses: cleanMisses, target: target)
            let maxVal = max(points.max() ?? 0.0, 1.0)
            let count = max(points.count, 1)

            ZStack(alignment: .leading) {
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(count - 1)
                        let y = h * (1 - CGFloat(v / maxVal))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard points.count > 1 else { return }
                    for (i, v) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(count - 1)
                        let y = h * (1 - CGFloat(v / maxVal))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(missBins.enumerated()), id: \.offset) { idx, missCount in
                    if missCount > 0 {
                        let x = count > 1 ? (w * CGFloat(idx) / CGFloat(count - 1)) : (w / 2)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                        }
                        .stroke(AppTheme.warn.opacity(0.6), lineWidth: 1)
                    }
                }
            }
        }
        .clipped()
    }

    private func downsample(values: [Double], misses: [UInt64], target: Int) -> ([Double], [UInt64]) {
        guard values.count > target, target > 0 else { return (values, misses) }
        let chunkSize = Int(ceil(Double(values.count) / Double(target)))
        var downValues: [Double] = []
        var downMisses: [UInt64] = []
        downValues.reserveCapacity(target)
        downMisses.reserveCapacity(target)

        var idx = 0
        while idx < values.count {
            let end = min(idx + chunkSize, values.count)
            let slice = values[idx..<end]
            let missSlice = misses[idx..<end]
            let avg = slice.reduce(0.0, +) / Double(slice.count)
            let missTotal = missSlice.reduce(0, +)
            downValues.append(avg)
            downMisses.append(missTotal)
            idx = end
        }
        return (downValues, downMisses)
    }
}

struct LogLineView: View {
    let time: Date
    let message: String
    let color: Color
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeString(time))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .frame(width: 50, alignment: .leading)

            Text(message)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .background(hovering ? AppTheme.rowHoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct SubmissionLineView: View {
    let time: Date
    let score: Double
    let rank: Int?
    let seed: UInt64
    let color: Color
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeString(time))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .frame(width: 50, alignment: .leading)

            Text(formatRank(rank))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)

            Text(formatScore(score))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)

            Text("seed \(seed)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 4)
        .background(hovering ? AppTheme.rowHoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private func formatRank(_ value: Int?) -> String {
        guard let value, value > 0 else { return "--" }
        return "#\(value)"
    }

    private func formatScore(_ value: Double) -> String {
        value.isFinite ? String(format: "%.5f", value) : "NaN"
    }

    private func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct StatusBadge: View {
    enum State { case success, warning, neutral }
    let text: String
    let state: State

    var color: Color {
        switch state {
        case .success: return AppTheme.ok
        case .warning: return AppTheme.warn
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct ControlButton: View {
    let icon: String
    let action: () -> Void
    var activeColor: Color? = nil
    var isActive: Bool = false
    @State private var hovering = false

    var body: some View {
        let accent = activeColor ?? AppTheme.accent
        let baseBg = hovering ? AppTheme.controlHoverFill : AppTheme.controlFill
        let activeBg = hovering ? accent.opacity(0.35) : accent.opacity(0.22)
        let border = isActive ? accent.opacity(0.45) : AppTheme.controlStroke
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(isActive ? accent : .primary)
        }
        .buttonStyle(.plain)
        .background(isActive ? activeBg : baseBg)
        .overlay(
            Circle()
                .stroke(border, lineWidth: 1)
        )
        .clipShape(Circle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? AppTheme.ok : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct SeedHoverView: View {
    let seed: UInt64
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Seed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: String(seed))
            }

            Text(String(seed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))

            if let source, !source.isEmpty {
                Text("Source: \(source)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SeedHoverLabel<Content: View>: View {
    let seed: UInt64?
    let source: String?
    let content: () -> Content
    @State private var showSeed = false
    @State private var closeTask: DispatchWorkItem?

    init(seed: UInt64?, source: String?, @ViewBuilder content: @escaping () -> Content) {
        self.seed = seed
        self.source = source
        self.content = content
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .onHover { hovering in
                guard seed != nil else { return }
                if hovering {
                    cancelClose()
                    showSeed = true
                } else {
                    scheduleClose()
                }
            }
            .popover(isPresented: $showSeed, arrowEdge: .trailing) {
                if let seed {
                    SeedHoverView(seed: seed, source: source)
                        .onHover { hovering in
                            if hovering {
                                cancelClose()
                                showSeed = true
                            } else {
                                scheduleClose()
                            }
                        }
                        .padding(8)
                }
            }
    }

    private func scheduleClose() {
        cancelClose()
        let task = DispatchWorkItem { showSeed = false }
        closeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }
}

struct EnergyRibbon: View {
    let profile: GPUThroughputProfile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: energyIcon(profile))
            Text("\(Int(profile.factor * 100))% GPU")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(AppTheme.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(AppTheme.warn.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

struct EnergyScaleView: View {
    let profiles: [GPUThroughputProfile]
    let selected: GPUThroughputProfile
    let trackInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let minFactor = profiles.first?.factor ?? 0.1
            let maxFactor = profiles.last?.factor ?? 1.0
            let span = max(maxFactor - minFactor, 0.0001)
            let usableWidth = max(proxy.size.width - trackInset * 2, 1)

            ZStack(alignment: .leading) {
                ForEach(profiles, id: \.self) { item in
                    let ratio = max(0, min(1, (item.factor - minFactor) / span))
                    let x = trackInset + usableWidth * CGFloat(ratio)
                    Text("\(Int(item.factor * 100))%")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(item == selected ? AppTheme.gpu : .secondary)
                        .position(x: x, y: 7)
                }
            }
        }
        .frame(height: 14)
    }
}

struct MetricInline: View {
    let value: String
    let label: String
    let color: Color
    var animateValue: Double? = nil

    var body: some View {
        let transitionValue = animateValue ?? (Double(value) ?? 0)
        ViewThatFits(in: .horizontal) {
            metricRow(valueSize: 32, labelSize: 13, transitionValue: transitionValue)
            metricRow(valueSize: 28, labelSize: 12, transitionValue: transitionValue)
            metricRow(valueSize: 24, labelSize: 11, transitionValue: transitionValue)
        }
    }

    private func metricRow(valueSize: CGFloat, labelSize: CGFloat, transitionValue: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: valueSize, weight: .medium, design: .monospaced))
                .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .contentTransition(.numericText(value: transitionValue))
                .animation(animateValue == nil ? .default : .snappy, value: transitionValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
            Text(label)
                .font(.system(size: labelSize, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        }
    }
}

struct CompactMetric: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }
    }
}

struct SetupWizardView: View {
    @ObservedObject var model: ExploreMenuModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()

            GlassCard(title: "First-time setup", icon: "wand.and.stars") {
                VStack(alignment: .leading, spacing: 12) {
                    if let issue = model.setupIssue {
                        Text(issue.message(configPath: model.configPath))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Configure submission profile", isOn: $model.setupWantsProfile)
                        .toggleStyle(.switch)

                    ProfileFields(
                        isEnabled: model.setupWantsProfile,
                        profileId: $model.profileId,
                        profileName: $model.profileName,
                        profileX: $model.profileX
                    )

                    if !model.setupWantsProfile {
                        Text("Submissions will use the default author until you update settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Share anonymous performance stats", isOn: $model.statsEnabled)
                        .toggleStyle(.switch)

                    Text("Stats endpoint: https://gobx-stats.davelindon.me/stats")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let status = model.setupStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("Saved") ? AppTheme.ok : AppTheme.warn)
                    }

                    HStack {
                        Button("Not now") {
                            model.dismissSetupWizard()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("Save Setup") {
                            model.saveSetupWizard()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: 360)
        }
        .transition(.opacity)
    }
}

struct ProfileFields: View {
    let isEnabled: Bool
    @Binding var profileId: String
    @Binding var profileName: String
    @Binding var profileX: String

    var body: some View {
        VStack(spacing: 12) {
            ProfileField(label: "Profile ID", placeholder: "Profile ID", text: $profileId)
            ProfileField(label: "Display Name", placeholder: "Display Name", text: $profileName)
            ProfileField(label: "X Handle (optional)", placeholder: "X Handle (optional)", text: $profileX)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

struct ProfileField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct SysRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
        }
    }
}

private func energyIcon(_ profile: GPUThroughputProfile) -> String {
    switch profile {
    case .dabbling: return "leaf"
    case .interested: return "bolt.badge.a"
    case .letsGo: return "bolt.circle"
    case .heater: return "flame"
    }
}

private extension View {
    @ViewBuilder
    func scrollIndicatorsVisible() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollIndicators(.visible)
        } else {
            self
        }
    }
}

private func fmtScore(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "--" }
    return String(format: "%.5f", v)
}

private func fmtRate(_ v: Double) -> String {
    if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
    if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
    if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
    return String(format: "%.0f", v)
}

private func fmtCount(_ v: UInt64) -> String {
    fmtRate(Double(v))
}

private func fmtBytes(_ v: UInt64?) -> String {
    guard let v else { return "-" }
    let gb = Double(v) / 1024 / 1024 / 1024
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(v) / 1024 / 1024)
}

private func fmtWatts(_ v: Double?) -> String {
    guard let v else { return "-" }
    return String(format: "%.1f W", v)
}

private func fmtTempC(_ v: Double?) -> String {
    guard let v else { return "-" }
    return String(format: "%.0f C", v)
}

private func githubLogoImage() -> Image {
    if let url = Bundle.module.url(forResource: "github-mark", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        return Image(nsImage: image)
    }
    return Image(systemName: "chevron.left.slash.chevron.right")
}

struct AppTheme {
    static var accent: Color { .accentColor }
    static var cpu: Color { Color(nsColor: .systemBlue) }
    static var gpu: Color { dynamicColor(light: emphasizeLight(.systemOrange, amount: 0.35), dark: .systemOrange) }
    static var ok: Color { dynamicColor(light: emphasizeLight(.systemGreen, amount: 0.35), dark: .systemGreen) }
    static var warn: Color { dynamicColor(light: emphasizeLight(.systemYellow, amount: 0.45), dark: .systemYellow) }
    static var error: Color { Color(nsColor: .systemRed) }
    static var tabSelectedFill: Color { Color(nsColor: .selectedControlColor).opacity(0.2) }
    static var tabSelectedStroke: Color { Color(nsColor: .selectedControlColor).opacity(0.45) }
    static var tabSeparator: Color { Color(nsColor: .separatorColor).opacity(0.3) }
    static var controlFill: Color { Color(nsColor: .controlBackgroundColor).opacity(0.85) }
    static var controlHoverFill: Color { Color(nsColor: .controlBackgroundColor).opacity(1.0) }
    static var controlStroke: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    static var rowHoverFill: Color { Color(nsColor: .tertiaryLabelColor).opacity(0.2) }
    static var popoverBackground: Color {
        dynamicColor(
            light: NSColor.windowBackgroundColor.withAlphaComponent(0.18),
            dark: .clear
        )
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            return match == .darkAqua ? dark : light
        })
    }

    private static func emphasizeLight(_ color: NSColor, amount: CGFloat) -> NSColor {
        let base = color.usingColorSpace(.sRGB) ?? color
        return base.blended(withFraction: amount, of: .black) ?? base
    }
}
