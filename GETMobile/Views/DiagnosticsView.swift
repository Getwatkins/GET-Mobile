import SwiftUI

/// Home -> Diagnostics. Read and clear fault codes on the ECM or TCM,
/// with a description for each code where one is available.
struct DiagnosticsView: View {
    @ObservedObject var diag: DiagnosticsSession
    @ObservedObject var gaugeSession: GaugeSessionViewModel
    let transport: UdsTransport

    @State private var confirmClear = false

    private var module: DiagModule { diag.selectedModule }
    private var result: DiagnosticsSession.ModuleResult? { diag.results[module] }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                modulePicker
                Toggle("Include pending codes", isOn: $diag.includePending)
                    .toggleStyle(SwitchToggleStyle(tint: GETTheme.amber))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .disabled(diag.isBusy)
                controls
                messages
                resultsSection
                footer
            }
            .padding()
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .withTopLogo()
        .confirmationDialog(
            "Clear \(module.title) fault codes?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear \(module.shortName) Codes", role: .destructive) {
                Task { await diag.clear(module) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases stored fault codes and their freeze-frame data, and resets emissions readiness monitors. Codes for faults that are still present will come straight back. Read and note them first if you need a record.")
        }
        .onAppear {
            // Same "one owner of the ECU connection" lock the loggers use, so
            // Live gauge polling can't race these requests on the shared transport.
            gaugeSession.beginHslLogging()
            diag.attach(transport: transport)
        }
        .onDisappear {
            gaugeSession.endHslLogging(resumeLive: false)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 5) {
            Text("DIAGNOSTICS")
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(GETTheme.gold)
            Text("Read and clear fault codes. Ignition on, car stationary.")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var modulePicker: some View {
        Picker("Module", selection: $diag.selectedModule) {
            ForEach(DiagModule.allCases) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .disabled(diag.isBusy)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await diag.read(module) }
            } label: {
                Text(isReading ? "Reading..." : "Read Codes").bold()
                    .frame(maxWidth: .infinity).padding(10)
                    .background(GETTheme.gold).foregroundColor(.black).cornerRadius(6)
            }
            .disabled(!diag.canRun)

            Button {
                confirmClear = true
            } label: {
                Text(isClearing ? "Clearing..." : "Clear Codes").bold()
                    .frame(maxWidth: .infinity).padding(10)
                    .background(GETTheme.warningRed).foregroundColor(.black).cornerRadius(6)
            }
            .disabled(!diag.canRun)
        }
        .opacity(diag.canRun ? 1 : 0.5)
    }

    private var isReading: Bool {
        if case .reading = diag.phase { return true }
        return false
    }

    private var isClearing: Bool {
        if case .clearing = diag.phase { return true }
        return false
    }

    @ViewBuilder
    private var messages: some View {
        if diag.isBusy {
            HStack(spacing: 8) {
                ProgressView().tint(GETTheme.amber)
                Text("Talking to the module...").font(.system(size: 12)).foregroundColor(.gray)
            }
        }
        if let info = diag.infoMessage {
            Text(info)
                .font(.system(size: 12))
                .foregroundColor(GETTheme.gold)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = diag.errorMessage {
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(GETTheme.warningRed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let result {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(module.shortName): \(result.dtcs.count) code\(result.dtcs.count == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(result.dtcs.isEmpty ? .green : .white)
                    Spacer()
                    Text(DateFormatter.localizedString(from: result.readAt, dateStyle: .none, timeStyle: .medium))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }

                ForEach(result.dtcs) { dtc in
                    DtcCard(dtc: dtc)
                }

                if let warning = result.warning {
                    Text(warning).font(.system(size: 11)).foregroundColor(GETTheme.amber)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let text = diag.reportText(for: module) {
            ShareLink(item: text) {
                Label("Share \(module.shortName) report", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(GETTheme.panelBackground)
                    .foregroundColor(GETTheme.amber)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.amber, lineWidth: 1))
                    .cornerRadius(6)
            }
        }

        Text(sourceNote)
            .font(.system(size: 10))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceNote: String {
        switch module {
        case .ecm:
            return "ECM descriptions: bri3d/VW_Flash Simos18 DTC table (BSD-2-Clause). Codes not in that table show their raw value only."
        case .tcm:
            return "TCM descriptions are generic SAE J2012 wording decoded from the code's bytes - VW_Flash has no DSG-specific table. Treat them as a guide and check the raw value if a description looks wrong for a DSG."
        }
    }
}

private struct DtcCard: View {
    let dtc: DiagnosticTroubleCode

    private var badge: (text: String, color: Color) {
        switch dtc.status.summary {
        case .active: return ("ACTIVE", GETTheme.warningRed)
        case .stored: return ("STORED", GETTheme.amber)
        case .pending: return ("PENDING", GETTheme.gold)
        case .history: return ("HISTORY", .gray)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(dtc.info.displayCode ?? dtc.rawHex)
                    .font(GETTheme.monoFont(17))
                    .foregroundColor(.white)
                Spacer()
                if dtc.status.contains(.warningIndicatorRequested) {
                    Text("MIL")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(GETTheme.amber).foregroundColor(.black).cornerRadius(4)
                }
                Text(badge.text)
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badge.color).foregroundColor(.black).cornerRadius(4)
            }

            Text(dtc.info.name ?? "No description available for this code")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(dtc.info.name == nil ? .gray : GETTheme.gold)
                .fixedSize(horizontal: false, vertical: true)

            Text(detailLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)

            Text(dtc.status.flagLabels.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(badge.color.opacity(0.6), lineWidth: 1))
        .cornerRadius(8)
    }

    private var detailLine: String {
        var parts = ["raw \(dtc.rawHex) (\(dtc.raw))", String(format: "status 0x%02X", dtc.statusByte)]
        if let source = dtc.info.source { parts.append(source.label) }
        if let symbol = dtc.info.symbol { parts.append(symbol) }
        return parts.joined(separator: "  ")
    }
}
