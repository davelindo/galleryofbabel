import AppKit
import SwiftUI
import GobxCore

@MainActor
struct MenuContentView: View {
    @ObservedObject var model: ExploreMenuModel
    @Namespace private var animationNamespace

    var body: some View {
        ZStack {
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
            .padding(12)
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
        VStack(spacing: 4) {
            HStack {
                Label {
                    Text("Gobx Explore")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                } icon: {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                }

                Spacer()

                StatusBadge(
                    text: model.isPaused ? "PAUSED" : (model.isRunning ? "ACTIVE" : "IDLE"),
                    state: model.isPaused ? .warning : (model.isRunning ? .success : .neutral)
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 0)

            HStack(spacing: 2) {
                ForEach(MenuTab.allCases) { tab in
                    TabButton(tab: tab, selected: $model.selectedTab, namespace: animationNamespace)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var contentContainer: some View {
        switch model.selectedTab {
        case .dashboard:
            ScrollView(showsIndicators: true) {
                DashboardView(model: model)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
            }
            .scrollIndicatorsVisible()
            .frame(maxHeight: .infinity)
        case .stats:
            ScrollView(showsIndicators: true) {
                StatsView(model: model)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
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
                Text(formatDuration(model.summary.elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Group {
                if model.isRunning {
                    ControlButton(icon: model.isPaused ? "play.fill" : "pause.fill", action: { model.togglePause() })
                        .help(model.isPaused ? "Resume" : "Pause")

                    ControlButton(icon: "stop.fill", action: { model.stop() })
                        .help("Stop Engine")
                } else {
                    ControlButton(icon: "play.fill", action: { model.start() })
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
    @State private var showBestSeed = false
    @State private var closeTask: DispatchWorkItem?

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
                    title: "Session Best",
                    icon: "trophy.fill",
                    headerTrailing: {
                        if let top = model.summary.topBestScore {
                            Text("Current #1: \(String(format: "%.6f", top))")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let best = model.summary.bestScore {
                            HStack {
                                Text(String(format: "%.6f", best))
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        guard model.summary.bestSeed != nil else { return }
                                        if hovering {
                                            cancelClose()
                                            showBestSeed = true
                                        } else {
                                            scheduleClose()
                                        }
                                    }

                                Spacer()
                            }
                            .popover(isPresented: $showBestSeed, arrowEdge: .trailing) {
                                if let seed = model.summary.bestSeed {
                                    SeedHoverView(seed: seed, source: model.summary.bestSource)
                                        .onHover { hovering in
                                            if hovering {
                                                cancelClose()
                                                showBestSeed = true
                                            } else {
                                                scheduleClose()
                                            }
                                        }
                                        .padding(8)
                                }
                            }
                        }

                        if let best = model.summary.bestScore, let top = model.summary.topBestScore {
                            ProgressView(value: best, total: top * 1.1)
                                .tint(AppTheme.accent)
                                .scaleEffect(y: 0.5)
                        }

                        if model.summary.bestScore != nil || model.summary.personalBestPreviousScore != nil {
                            HStack {
                                if let best = model.summary.bestScore {
                                    Text("Personal Best (This Run): \(String(format: "%.6f", best))")
                                }
                                Spacer()
                                if let previous = model.summary.personalBestPreviousScore {
                                    Text("Personal Best (Previous): \(String(format: "%.6f", previous))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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

    private func scheduleClose() {
        cancelClose()
        let task = DispatchWorkItem { showBestSeed = false }
        closeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }
}

struct StatsView: View {
    @ObservedObject var model: ExploreMenuModel

    var body: some View {
        VStack(spacing: 16) {
            ChartCard(title: "Throughput (Total)", value: model.history.map { $0.totalRate }, color: AppTheme.accent)

            if model.summary.backend == .mps || model.summary.backend == .all {
                HStack(spacing: 12) {
                    ChartCard(title: "MPS Rate", value: model.history.map { $0.mpsRate }, color: AppTheme.gpu, height: 80)
                    ChartCard(title: "CPU Rate", value: model.history.map { $0.cpuRate }, color: AppTheme.cpu, height: 80)
                }
            }

            GlassCard(title: "System Load", icon: "memorychip") {
                VStack(spacing: 12) {
                    HStack {
                        Gauge(value: model.summary.system.gpuUtilPercent ?? 0, in: 0...100) {
                            Text("GPU Util")
                        } currentValueLabel: {
                            Text("\(Int(model.summary.system.gpuUtilPercent ?? 0))%")
                        }
                        .gaugeStyle(.accessoryCircular)
                        .tint(AppTheme.gpu)

                        Spacer()

                        VStack(alignment: .trailing) {
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
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
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
                    LogLineView(
                        time: s.time,
                        message: formatSub(s),
                        color: colorForSub(s.kind)
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    func formatSub(_ s: SubmissionLogEntry) -> String {
        let sc = s.score.isFinite ? String(format: "%.5f", s.score) : "NaN"
        return "\(s.kind.rawValue.uppercased()) | Score: \(sc) | Seed: \(s.seed)"
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
                        Image("github-mark", bundle: .module)
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(profile.marketingName, systemImage: energyIcon(profile))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(Int(profile.factor * 100))% GPU")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.gpu)
            }

            Slider(value: energyValue, in: 0.1...1.0)
                .tint(AppTheme.gpu)

            HStack {
                ForEach(energyProfiles, id: \.self) { item in
                    Text("\(Int(item.factor * 100))%")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(item == profile ? AppTheme.gpu : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
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

    var body: some View {
        GlassCard(title: title) {
            Sparkline(values: value, tint: color)
                .frame(height: height)
                .padding(8)
        }
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
                        .fill(Color.white.opacity(0.1))
                        .matchedGeometryEffect(id: "TABBG", in: namespace)
                }
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected == tab ? .white : .secondary)
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
        .background(hovering ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.1))
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

struct MetricInline: View {
    let value: String
    let label: String
    let color: Color
    var animateValue: Double? = nil

    var body: some View {
        let transitionValue = animateValue ?? (Double(value) ?? 0)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .contentTransition(.numericText(value: transitionValue))
                .animation(animateValue == nil ? .default : .snappy, value: transitionValue)
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
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

struct AppTheme {
    static let accent = Color.cyan
    static let cpu = Color.blue
    static let gpu = Color.orange
    static let ok = Color.green
    static let warn = Color.yellow
    static let error = Color.red
}
