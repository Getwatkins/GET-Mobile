import SwiftUI
import Charts

/// Dragy-style performance timer: 0-60, rolling 60-130, drag-strip marks
/// (60 ft / 1/8 mi / 1/4 mi with ET and trap speed) and acceleration. Speed
/// comes from the iPhone's GPS, or from the ECU's vehicle-speed channel.
struct PerformanceView: View {
    @ObservedObject var perf: PerformanceSession

    private enum Tab: String, CaseIterable, Identifiable {
        case speed = "Speed", drag = "Drag Strip", accel = "Accel", history = "History"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .speed
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                sourceBar
                speedHeader

                Picker("Mode", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch tab {
                case .speed: speedRuns
                case .drag: dragStrip
                case .accel: acceleration
                case .history: historyList
                }

                controls
                footnote
            }
            .padding(.vertical, 12)
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { perf.stop() }
        .confirmationDialog("Clear all saved runs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { perf.clearHistory() }
        }
    }

    // MARK: Header

    private var sourceBar: some View {
        VStack(spacing: 8) {
            Picker("Source", selection: $perf.source) {
                ForEach(PerfSourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(sourceInfo)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Spacer()
                Toggle("1 ft rollout", isOn: $perf.rollout)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .fixedSize()
                    .tint(GETTheme.amber)
            }
        }
        .padding(.horizontal)
    }

    private var sourceInfo: String {
        guard perf.running else { return perf.source == .gps ? "iPhone GPS" : "ECU vehicle speed" }
        let rate = perf.sampleRate > 0 ? String(format: "%.0f Hz", perf.sampleRate) : "no data"
        if perf.source == .gps {
            let acc = perf.gpsAccuracyM.map { " ±\(Int($0)) m" } ?? ""
            return "GPS\(acc) • \(rate)"
        }
        return "OBD • \(rate)"
    }

    private var stateText: String {
        if let n = perf.notice { return n }
        if !perf.running { return "Press Start, then stop the car to arm" }
        if perf.sampleRate == 0 { return perf.source == .gps ? "Waiting for GPS fix…" : "Waiting for vehicle speed…" }
        switch perf.phase {
        case .waiting: return "Stop the car to arm"
        case .armed: return "READY — launch when you are"
        case .running: return "GO!"
        case .finished: return "Run complete — stop to re-arm"
        }
    }

    private var stateColor: Color {
        if perf.notice != nil { return GETTheme.warningRed }
        switch perf.phase {
        case .armed where perf.running: return .green
        case .running: return GETTheme.gold
        default: return .gray
        }
    }

    private var speedHeader: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.0f", perf.speedMph))
                .font(GETTheme.monoFont(84))
                .foregroundColor(GETTheme.valueWhite)
                .minimumScaleFactor(0.6)
            Text("mph")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(GETTheme.amber)
            Text(stateText)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(stateColor)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(stateColor.opacity(0.6), lineWidth: 1.5))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: Speed runs

    /// Elapsed seconds since the (rollout-adjusted) launch while a run is live.
    private func liveElapsed(_ now: Date) -> Double? {
        guard perf.phase == .running, let t = perf.launchTime else { return nil }
        return max(0, now.timeIntervalSinceReferenceDate - t)
    }

    private var speedRuns: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                statCard(title: "0 – 60 mph",
                         value: perf.results.zeroTo60,
                         live: perf.results.zeroTo60 == nil && perf.speedMph < 60 ? liveElapsed(ctx.date) : nil,
                         best: perf.best060,
                         hint: "Launch from a standstill")
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                statCard(title: "60 – 130 mph (rolling)",
                         value: perf.rolling ? nil : perf.lastRolling,
                         live: rollingLive(ctx.date),
                         best: perf.bestRolling,
                         hint: "Starts when you pass 60, no stop needed")
            }
            if perf.results.topSpeedMph > 0 {
                HStack {
                    Text("Top speed this run").foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "%.1f mph", perf.results.topSpeedMph))
                        .font(GETTheme.monoFont(16)).foregroundColor(GETTheme.gold)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 24)
            }
        }
    }

    private func rollingLive(_ now: Date) -> Double? {
        guard perf.rolling, let st = perf.rollingStartTime else { return nil }
        return max(0, now.timeIntervalSinceReferenceDate - st)
    }

    private func statCard(title: String, value: Double?, live: Double?, best: Double?, hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(GETTheme.amber)
            if let v = value {
                Text(String(format: "%.2f s", v)).font(GETTheme.monoFont(44)).foregroundColor(GETTheme.gold)
            } else if let l = live {
                Text(String(format: "%.2f s", l)).font(GETTheme.monoFont(44)).foregroundColor(.white)
            } else {
                Text("-- . -- s").font(GETTheme.monoFont(44)).foregroundColor(Color(white: 0.3))
            }
            HStack {
                Text(hint).font(.system(size: 11)).foregroundColor(.gray)
                Spacer()
                if let b = best { Text(String(format: "Best %.2f s", b)).font(.system(size: 12, weight: .semibold)).foregroundColor(.green) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: Drag strip

    private var dragStrip: some View {
        VStack(spacing: 0) {
            dragRow(["Distance", "ET", "Speed", "Best ET"], header: true)
            dragMarkRow("60 ft", 60)
            dragMarkRow("1/8 mile", 660)
            dragMarkRow("1/4 mile", 1320)
        }
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func dragMarkRow(_ name: String, _ feet: Double) -> some View {
        let m = perf.results.mark(feet)
        let best = perf.bestMark(feet)
        return dragRow([
            name,
            m.map { String(format: "%.3f s", $0.et) } ?? "--",
            m.map { String(format: "%.1f mph", $0.speedMph) } ?? "--",
            best.map { String(format: "%.3f", $0.et) } ?? "--",
        ], header: false, highlight: m != nil)
    }

    private func dragRow(_ cols: [String], header: Bool, highlight: Bool = false) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                Text(c)
                    .font(header ? .system(size: 12, weight: .semibold) : (i == 0 ? .system(size: 15, weight: .semibold) : GETTheme.monoFont(15)))
                    .foregroundColor(header ? GETTheme.amber : (i == 3 ? .green : (highlight && i > 0 ? GETTheme.gold : (i == 0 ? .white : Color(white: 0.4)))))
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, header ? 8 : 14)
        .background(header ? Color(white: 0.08) : Color.clear)
    }

    // MARK: Acceleration

    private var acceleration: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text("Acceleration").font(.system(size: 14, weight: .semibold)).foregroundColor(GETTheme.amber)
                Text(String(format: "%+.2f g", perf.liveG))
                    .font(GETTheme.monoFont(48))
                    .foregroundColor(perf.liveG < -0.05 ? GETTheme.warningRed : GETTheme.gold)
                gBar(perf.liveG)
                HStack {
                    Text("Peak this run").foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "%.2f g", perf.results.peakG)).font(GETTheme.monoFont(16)).foregroundColor(GETTheme.gold)
                }
                .font(.system(size: 14))
            }
            .padding(14)
            .background(GETTheme.panelBackground)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(GETTheme.border, lineWidth: 1))
            .cornerRadius(12)
            .padding(.horizontal)

            if perf.trace.count > 1 {
                runCharts
            } else {
                Text("Charts appear after a run.")
                    .font(.system(size: 13)).foregroundColor(.gray)
            }
        }
    }

    private func gBar(_ g: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = max(-1.5, min(1.5, g))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.12))
                Rectangle().fill(Color(white: 0.4)).frame(width: 2).position(x: w / 2, y: geo.size.height / 2)
                let x0 = w / 2
                let len = abs(clamped) / 1.5 * (w / 2)
                Capsule()
                    .fill(clamped >= 0 ? GETTheme.gold : GETTheme.warningRed)
                    .frame(width: max(len, 2), height: geo.size.height)
                    .offset(x: clamped >= 0 ? x0 : x0 - len)
            }
        }
        .frame(height: 14)
    }

    private struct ChartPoint: Identifiable { let id: Int; let t: Double; let v: Double }

    private var speedSeries: [ChartPoint] {
        guard let t0 = perf.trace.first?.t else { return [] }
        return perf.trace.enumerated().map { ChartPoint(id: $0.offset, t: $0.element.t - t0, v: $0.element.v / PerfConst.mph) }
    }

    private var gSeries: [ChartPoint] {
        let tr = perf.trace
        guard let t0 = tr.first?.t, tr.count > 1 else { return [] }
        var out: [ChartPoint] = []
        for i in 1..<tr.count {
            var j = i - 1
            while j > 0, tr[i].t - tr[j].t < 0.25 { j -= 1 }
            let g = ((tr[i].v - tr[j].v) / (tr[i].t - tr[j].t)) / PerfConst.g
            out.append(ChartPoint(id: i, t: tr[i].t - t0, v: g))
        }
        return out
    }

    private var runCharts: some View {
        VStack(spacing: 14) {
            chartCard(title: "Speed (mph)", data: speedSeries, color: GETTheme.gold)
            chartCard(title: "Acceleration (g)", data: gSeries, color: .green)
        }
        .padding(.horizontal)
    }

    private func chartCard(title: String, data: [ChartPoint], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(GETTheme.amber)
            Chart(data) { p in
                LineMark(x: .value("Time", p.t), y: .value(title, p.v))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxisLabel("seconds")
            .frame(height: 150)
        }
        .padding(12)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(12)
    }

    // MARK: History

    private var historyList: some View {
        VStack(spacing: 8) {
            if perf.history.isEmpty {
                Text("No saved runs yet. Completed runs are saved automatically.")
                    .font(.system(size: 13)).foregroundColor(.gray).padding()
            } else {
                ForEach(perf.history) { rec in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.date.formatted(date: .abbreviated, time: .shortened) + " • " + rec.source)
                            .font(.system(size: 11)).foregroundColor(.gray)
                        Text(summary(rec.results))
                            .font(GETTheme.monoFont(13, weight: .semibold)).foregroundColor(GETTheme.gold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(GETTheme.panelBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(GETTheme.border, lineWidth: 1))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .padding(.top, 4)
            }
        }
    }

    private func summary(_ r: PerfResults) -> String {
        var parts: [String] = []
        if let t = r.zeroTo60 { parts.append(String(format: "0-60 %.2fs", t)) }
        if let t = r.sixtyTo130 { parts.append(String(format: "60-130 %.2fs", t)) }
        if let m = r.mark(60) { parts.append(String(format: "60ft %.3f", m.et)) }
        if let m = r.mark(660) { parts.append(String(format: "1/8 %.2f@%.0f", m.et, m.speedMph)) }
        if let m = r.mark(1320) { parts.append(String(format: "1/4 %.2f@%.0f", m.et, m.speedMph)) }
        return parts.joined(separator: "  ")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                perf.running ? perf.stop() : perf.start()
            } label: {
                Text(perf.running ? "Stop" : "Start")
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(perf.running ? GETTheme.warningRed : GETTheme.gold)
                    .foregroundColor(.black)
                    .cornerRadius(12)
            }
            Button {
                perf.resetRun()
            } label: {
                Text("Reset")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 110)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.18))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }

    private var footnote: some View {
        Text("For track/closed-course use only. Don't operate this screen while driving. iPhone GPS updates about once per second, so times are interpolated and can be off by roughly 0.1–0.3 s; Vehicle speed (OBD) samples faster. Drag-strip marks use speed integrated over time, trap speed is the average over the last 66 ft.")
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }
}
