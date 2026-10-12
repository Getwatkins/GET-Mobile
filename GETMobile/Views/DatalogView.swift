import SwiftUI
import Charts
import UniformTypeIdentifiers

struct DatalogView: View {
    @ObservedObject var logger: HslLoggerSession
    @ObservedObject var gaugeSession: GaugeSessionViewModel
    let transport: UdsTransport
    @Environment(\.dismiss) private var dismiss
    @State private var showPidPicker = false
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var selectedChartName = "Engine Speed"
    @State private var showFileImporter = false

    var body: some View {
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
            .withTopLogo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        logger.stop()
                        gaugeSession.endHslLogging(resumeLive: false)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPidPicker) {
                HslPidPicker(logger: logger)
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { logger.importParameterFile(from: url) }
                case .failure(let error):
                    exportError = "Could not open parameter file: \(error.localizedDescription)"
                }
            }
            .onChange(of: logger.selectedFile) { _ in
                // A different file has different channels - keep the chart on one that exists.
                if !logger.selectedPids.contains(where: { $0.name == selectedChartName }),
                   let first = logger.selectedPids.first {
                    selectedChartName = first.name
                }
            }

            .onAppear {
                // HSL ownership was acquired by LoggingMenuView BEFORE this
                // screen was pushed. Do not acquire/release it here: SwiftUI
                // may rebuild this view while logging, and ownership must
                // remain stable until the user explicitly taps Done.
                logger.attach(transport: transport)
            }
            .onDisappear {
                // Never resume gauges from onDisappear. The explicit Done button is
                // the only place that releases the HSL ownership lock.
                logger.stop()
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
            parameterFileSection

            HStack(spacing: 10) {
                Button {
                    if logger.isRunning { logger.stop() } else { logger.start() }
                } label: {
                    Label(logger.isStarting ? "Starting HSL..." : (logger.isRunning ? "Stop Logging" : "Start Logging"), systemImage: logger.isRunning ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(logger.isRunning ? GETTheme.warningRed : GETTheme.amber)
                        .foregroundColor(.black)
                        .cornerRadius(7)
                    }
                    .disabled(logger.isStarting || (logger.selectedFile == nil && !logger.isRunning))
                    .opacity(logger.selectedFile == nil && !logger.isRunning ? 0.4 : 1)

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
                Text("Poll Delay")
                Spacer()
                Stepper(value: $logger.pollDelayMs, in: 0...1000, step: 10) {
                    Text("\(logger.pollDelayMs) ms")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 220)
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

    /// Mirrors the desktop logger's "Parameter File" dropdown + "Browse for custom .csv...".
    /// Nothing is pre-selected: the correct file depends on the ECU's software version.
    private var parameterFileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parameter File")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer()
                Menu {
                    ForEach(logger.parameterFiles) { file in
                        Button {
                            logger.selectParameterFile(file)
                        } label: {
                            if logger.selectedFile == file {
                                Label(file.displayName, systemImage: "checkmark")
                            } else {
                                Text(file.displayName)
                            }
                        }
                    }
                    Divider()
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import custom .csv...", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(logger.selectedFile?.displayName ?? "Select a file...")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(logger.selectedFile == nil ? GETTheme.warningRed : GETTheme.amber)
                }
                .disabled(logger.isRunning || logger.isStarting)
            }
            Text(parameterFileInfo)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var parameterFileInfo: String {
        guard logger.selectedFile != nil else {
            return "Choose the file that matches your ECU's software version (e.g. S50, O30). A mismatched file reads the wrong memory addresses."
        }
        let polled = logger.parameters.filter { !$0.isVirtual }.count
        let calculated = logger.parameters.count - polled
        return "\(logger.parameters.count) parameters in this file (\(polled) read from the ECU, \(calculated) calculated)."
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
        guard !q.isEmpty else { return logger.parameters }
        return logger.parameters.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.assignment?.localizedCaseInsensitiveContains(q) == true }
    }

    private func detail(for pid: HslPid) -> String {
        var parts: [String] = []
        if pid.isVirtual {
            parts.append("calculated")
        } else {
            parts.append("0x" + String(pid.address, radix: 16, uppercase: true))
            parts.append("\(pid.length) byte" + (pid.length == 1 ? "" : "s"))
        }
        if !pid.unit.isEmpty { parts.append(pid.unit) }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which channels to display and export. The ECU is always asked for every parameter in the selected file (like the desktop logger) - this only filters what you see and save.")
                        .font(.system(size: 12)).foregroundColor(.gray)
                    HStack(spacing: 16) {
                        Button("Select All") { logger.selectAllChannels() }
                        Button("Select None") { logger.selectNoChannels() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(GETTheme.amber)
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
                                Text(detail(for: pid))
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

