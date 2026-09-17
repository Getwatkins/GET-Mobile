import SwiftUI
import Charts

struct DidLoggerView: View {
    @ObservedObject var logger: DidLoggerSession
    @ObservedObject var gaugeSession: GaugeSessionViewModel
    let transport: UdsTransport
    @Environment(\.dismiss) private var dismiss
    @State private var showChannelPicker = false
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var selectedChartName = "Engine Speed"
    @State private var scrubDate: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    controls
                    currentValues
                    chart
                    channelSummary
                    if let error = logger.lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(GETTheme.warningRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let exportError {
                        Text(exportError).font(.system(size: 12)).foregroundColor(GETTheme.warningRed)
                    }
                }
                .padding()
            }
            .background(GETTheme.background.ignoresSafeArea())
            .navigationTitle("Datalog (Standard)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        logger.stop()
                        gaugeSession.endHslLogging(resumeLive: false)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showChannelPicker) {
                DidChannelPicker(logger: logger)
            }
            .onAppear {
                // Same ownership lock DatalogView/HSL uses - keeps normal Live
                // gauge polling from racing this logger on the shared transport.
                // Acquired by GaugesView before this view was presented; not
                // re-acquired/released here so it survives SwiftUI rebuilds.
                logger.attach(transport: transport)
            }
            .onDisappear {
                logger.stop()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("STANDARD DATALOGGER")
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(GETTheme.gold)
            Text("Records normal DID reads over time - the same reliable path the gauges use")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if logger.isRunning { logger.stop() } else { scrubDate = nil; logger.start() }
                } label: {
                    Label(logger.isStarting ? "Starting..." : (logger.isRunning ? "Stop Logging" : "Start Logging"), systemImage: logger.isRunning ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(logger.isRunning ? GETTheme.warningRed : GETTheme.amber)
                        .foregroundColor(.black)
                        .cornerRadius(7)
                }
                .disabled(logger.isStarting)

                Button {
                    showChannelPicker = true
                } label: {
                    Label("Channels", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(GETTheme.panelBackground)
                        .foregroundColor(GETTheme.gold)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(GETTheme.border, lineWidth: 1))
                        .cornerRadius(7)
                }
            }

            Text("More channels selected = slower per-channel update rate, since each one is its own request/response - same tradeoff as running more gauges at once.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Label(logger.isRunning ? "Logging" : "Stopped", systemImage: logger.isRunning ? "circle.fill" : "circle")
                    .foregroundColor(logger.isRunning ? GETTheme.amber : .gray)
                Spacer()
                Text("\(logger.sampleCount) samples")
                Text(formatDuration(logger.duration))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.gray)

            HStack(spacing: 10) {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share CSV", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(9)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.amber)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(GETTheme.amber, lineWidth: 1))
                            .cornerRadius(7)
                    }
                } else {
                    Button {
                        do {
                            shareURL = try logger.exportCSV()
                            exportError = nil
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(9)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.amber)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(GETTheme.amber, lineWidth: 1))
                            .cornerRadius(7)
                    }
                    .disabled(logger.samples.isEmpty)
                }

                Button("Clear", role: .destructive) {
                    logger.stop()
                    logger.clear()
                    shareURL = nil
                    scrubDate = nil
                }
                .padding(.horizontal, 14)
            }
        }
        .padding()
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(8)
    }

    private var currentValues: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let scrubbedSample {
                    Label("At \(scrubbedSample.timestamp.formatted(date: .omitted, time: .standard))", systemImage: "hand.point.up.left.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(GETTheme.amber)
                    Spacer()
                    Button("Back to Live") { scrubDate = nil }
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray)
                    Spacer()
                    if !logger.samples.isEmpty {
                        Text("Tap or drag the graph below to inspect a point")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(logger.selectedEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.gray).lineLimit(1)
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(formatValue((scrubbedSample?.values ?? logger.latestValues)[entry.name]))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text(entry.unit).font(.system(size: 10)).foregroundColor(GETTheme.amber)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(GETTheme.background)
                    .cornerRadius(6)
                }
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Graph").font(.system(size: 15, weight: .bold)).foregroundColor(GETTheme.gold)
                Spacer()
                Picker("Channel", selection: $selectedChartName) {
                    ForEach(logger.selectedEntries) { entry in Text(entry.name).tag(entry.name) }
                }
                .pickerStyle(.menu)
            }
            Chart {
                ForEach(Array(logger.samples.suffix(500))) { sample in
                    if let value = sample.values[selectedChartName] {
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value(selectedChartName, value)
                        )
                    }
                }
                if let scrubbedSample {
                    RuleMark(x: .value("Selected", scrubbedSample.timestamp))
                        .foregroundStyle(GETTheme.amber.opacity(0.6))
                    if let value = scrubbedSample.values[selectedChartName] {
                        PointMark(
                            x: .value("Time", scrubbedSample.timestamp),
                            y: .value(selectedChartName, value)
                        )
                        .foregroundStyle(GETTheme.amber)
                    }
                }
            }
            .frame(height: 210)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard !logger.samples.isEmpty else { return }
                                    let originX = geo[proxy.plotAreaFrame].origin.x
                                    let x = value.location.x - originX
                                    if let date: Date = proxy.value(atX: x) {
                                        scrubDate = date
                                    }
                                }
                        )
                }
            }
            if !logger.samples.isEmpty {
                Text("Tap or drag to inspect a point - values above update to match.")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(8)
    }

    private var channelSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Selected channels (\(logger.selectedEntries.count))")
                .font(.system(size: 14, weight: .bold)).foregroundColor(GETTheme.gold)
            Text(logger.selectedEntries.map(\.name).joined(separator: " • "))
                .font(.system(size: 11)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nearest recorded sample to the scrubbed timestamp - nil while there's
    /// no active scrub selection, which is how currentValues knows to fall
    /// back to the live latest values instead.
    private var scrubbedSample: DidLogSample? {
        guard let scrubDate else { return nil }
        return logger.samples.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(scrubDate)) < abs(rhs.timestamp.timeIntervalSince(scrubDate))
        }
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct DidChannelPicker: View {
    @ObservedObject var logger: DidLoggerSession
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [CommonDidEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return CommonDidCatalog.all }
        return CommonDidCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select channels to record. Each one is read with its own normal request, same as a gauge - more channels means a slower cycle, not a bigger single request.")
                        .font(.system(size: 12)).foregroundColor(.gray)
                    HStack(spacing: 10) {
                        Button("Select All \(CommonDidCatalog.all.count)") {
                            logger.selectedNames = Set(CommonDidCatalog.all.map(\.name))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Deselect All", role: .destructive) {
                            logger.selectedNames.removeAll()
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
                ForEach(filtered) { entry in
                    Button {
                        if logger.selectedNames.contains(entry.name) {
                            logger.selectedNames.remove(entry.name)
                        } else {
                            logger.selectedNames.insert(entry.name)
                        }
                    } label: {
                        HStack {
                            Image(systemName: logger.selectedNames.contains(entry.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(logger.selectedNames.contains(entry.name) ? GETTheme.amber : .gray)
                            VStack(alignment: .leading) {
                                Text(entry.name).foregroundColor(.white)
                                Text(entry.displayText)
                                    .font(.system(size: 10)).foregroundColor(.gray)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(GETTheme.panelBackground)
                }
            }
            .searchable(text: $search)
            .scrollContentBackground(.hidden)
            .background(GETTheme.background)
            .navigationTitle("Log Channels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
