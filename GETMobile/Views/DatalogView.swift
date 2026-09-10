import SwiftUI
import Charts

struct DatalogView: View {
    @ObservedObject var logger: HslLoggerSession
    @ObservedObject var gaugeSession: GaugeSessionViewModel
    let transport: UdsTransport
    @Environment(\.dismiss) private var dismiss
    @State private var showPidPicker = false
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var selectedChartName = "Engine Speed"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    controls
                    currentValues
                    chart
                    pidSummary
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
            .navigationTitle("Datalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        logger.stop()
                        gaugeSession.startLive()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPidPicker) {
                HslPidPicker(logger: logger)
            }

            .onAppear {
                // Datalogging is a separate transport workload. Do not automatically
                // start it when the screen appears; the user explicitly starts logging.
                // This prevents the gauge poller from being mistaken for the logger and
                // makes HSL startup failures visible on this screen.
                gaugeSession.stopLive()
                logger.attach(transport: transport)
            }
            .onDisappear {
                logger.stop()
                gaugeSession.startLive()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("SIMOS HSL DATALOGGER")
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(GETTheme.gold)
            Text("SimosTools-compatible 3E high-speed logging")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if logger.isRunning { logger.stop() } else { logger.start() }
                } label: {
                    Label(logger.isRunning ? "Stop Logging" : "Start Logging", systemImage: logger.isRunning ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(logger.isRunning ? GETTheme.warningRed : GETTheme.amber)
                        .foregroundColor(.black)
                        .cornerRadius(7)
                }

                Button {
                    showPidPicker = true
                } label: {
                    Label("PIDs", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(GETTheme.panelBackground)
                        .foregroundColor(GETTheme.gold)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(GETTheme.border, lineWidth: 1))
                        .cornerRadius(7)
                }
            }

            HStack {
                Text("Rate")
                Spacer()
                Picker("Rate", selection: $logger.sampleRate) {
                    Text("5 Hz").tag(5.0)
                    Text("10 Hz").tag(10.0)
                    Text("15 Hz").tag(15.0)
                    Text("20 Hz").tag(20.0)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.gray)

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
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(logger.selectedPids) { pid in
                VStack(alignment: .leading, spacing: 2) {
                    Text(pid.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.gray).lineLimit(1)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(formatValue(logger.latestValues[pid.name]))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text(pid.unit).font(.system(size: 10)).foregroundColor(GETTheme.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(GETTheme.background)
                .cornerRadius(6)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live graph").font(.system(size: 15, weight: .bold)).foregroundColor(GETTheme.gold)
                Spacer()
                Picker("Channel", selection: $selectedChartName) {
                    ForEach(logger.selectedPids) { pid in Text(pid.name).tag(pid.name) }
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
            }
            .frame(height: 210)
        }
        .padding()
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(8)
    }

    private var pidSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Selected channels (\(logger.selectedPids.count))")
                .font(.system(size: 14, weight: .bold)).foregroundColor(GETTheme.gold)
            Text(logger.selectedPids.map(\.name).joined(separator: " • "))
                .font(.system(size: 11)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct HslPidPicker: View {
    @ObservedObject var logger: HslLoggerSession
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [HslPid] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return HslPidCatalog.all }
        return HslPidCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.assignment?.localizedCaseInsensitiveContains(q) == true }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select the channels to record. HSL reads the ECU memory list in one high-speed response, so selecting more channels changes the response size but not the basic logging method.")
                        .font(.system(size: 12)).foregroundColor(.gray)
                }
                ForEach(filtered) { pid in
                    Button {
                        if logger.selectedNames.contains(pid.name) {
                            logger.selectedNames.remove(pid.name)
                        } else {
                            logger.selectedNames.insert(pid.name)
                        }
                    } label: {
                        HStack {
                            Image(systemName: logger.selectedNames.contains(pid.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(logger.selectedNames.contains(pid.name) ? GETTheme.amber : .gray)
                            VStack(alignment: .leading) {
                                Text(pid.name).foregroundColor(.white)
                                Text("0x\(String(pid.address, radix: 16, uppercase: true)) • \(pid.length) byte\(pid.length == 1 ? "" : "s")\(pid.unit.isEmpty ? "" : " • \(pid.unit)")")
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
            .navigationTitle("HSL Channels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

