import SwiftUI

struct DiagnosticTroubleCode: Identifiable {
    let id = UUID()
    let code: String
    let status: UInt8

    var statusText: String {
        var flags: [String] = []
        if status & 0x01 != 0 { flags.append("test failed") }
        if status & 0x02 != 0 { flags.append("failed this operation cycle") }
        if status & 0x04 != 0 { flags.append("pending") }
        if status & 0x08 != 0 { flags.append("confirmed") }
        if status & 0x10 != 0 { flags.append("not completed since clear") }
        if status & 0x20 != 0 { flags.append("failed since clear") }
        if status & 0x40 != 0 { flags.append("warning requested") }
        return flags.isEmpty ? "No active status flags" : flags.joined(separator: ", ")
    }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var gaugeSession: GaugeSessionViewModel
    let transport: UdsTransport
    @Environment(\.dismiss) private var dismiss
    @State private var codes: [DiagnosticTroubleCode] = []
    @State private var isReading = false
    @State private var isClearing = false
    @State private var message: String?
    @State private var showClearConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GETSectionLogo("Diagnostics")

                Text("ECU FAULT CODES")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(GETTheme.gold)

                Text("Read and clear UDS diagnostic trouble codes from the ECU.")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button {
                        Task { await readCodes() }
                    } label: {
                        Label(isReading ? "Reading..." : "Read Fault Codes", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.gold)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.gold, lineWidth: 1))
                            .cornerRadius(8)
                    }
                    .disabled(isReading || isClearing)

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Label(isClearing ? "Clearing..." : "Clear Codes", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.warningRed)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.warningRed, lineWidth: 1))
                            .cornerRadius(8)
                    }
                    .disabled(isReading || isClearing)
                }

                if let message {
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(message.hasPrefix("Error") ? GETTheme.warningRed : GETTheme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if codes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 34))
                            .foregroundColor(GETTheme.amber)
                        Text("No fault codes loaded")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Tap Read Fault Codes to query the ECU.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .background(GETTheme.panelBackground)
                    .cornerRadius(10)
                } else {
                    ForEach(codes) { dtc in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(dtc.code)
                                    .font(GETTheme.monoFont(21))
                                    .foregroundColor(.white)
                                Spacer()
                                Text(String(format: "0x%02X", dtc.status))
                                    .font(GETTheme.monoFont(12, weight: .semibold))
                                    .foregroundColor(GETTheme.amber)
                            }
                            Text(dtc.statusText)
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GETTheme.panelBackground)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Clear all diagnostic fault codes?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All Codes", role: .destructive) {
                Task { await clearCodes() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The ECU will receive UDS ClearDiagnosticInformation (0x14) for DTC group 0xFFFFFF. This cannot be undone from the app.")
        }
        .onAppear { gaugeSession.stopLive() }
    }

    private func readCodes() async {
        gaugeSession.stopLive()
        isReading = true
        message = nil
        defer { isReading = false }
        do {
            let uds = UdsClient(transport: transport)
            uds.requestTimeoutSeconds = 5
            let payload = try await uds.readDtcByStatusMask(0xFF)
            codes = parseDTCs(payload)
            message = codes.isEmpty ? "ECU reports no DTCs with the requested status mask." : "Read \(codes.count) fault code\(codes.count == 1 ? "" : "s")."
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
    }

    private func clearCodes() async {
        gaugeSession.stopLive()
        isClearing = true
        message = nil
        defer { isClearing = false }
        do {
            let uds = UdsClient(transport: transport)
            uds.requestTimeoutSeconds = 5
            try await uds.clearDiagnosticInformation()
            codes.removeAll()
            message = "ECU accepted the clear-code request."
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
    }

    private func parseDTCs(_ payload: Data) -> [DiagnosticTroubleCode] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 1 else { return [] }
        var result: [DiagnosticTroubleCode] = []
        var index = 1 // first byte is DTCStatusAvailabilityMask
        while index + 3 < bytes.count {
            let raw = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8) | UInt32(bytes[index + 2])
            result.append(DiagnosticTroubleCode(code: formatDTC(raw), status: bytes[index + 3]))
            index += 4
        }
        return result
    }

    private func formatDTC(_ raw: UInt32) -> String {
        let first = UInt8((raw >> 16) & 0xFF)
        let prefix: String
        switch (first >> 6) & 0x03 {
        case 0: prefix = "P"
        case 1: prefix = "C"
        case 2: prefix = "B"
        default: prefix = "U"
        }
        let d1 = (first >> 4) & 0x03
        let d2 = first & 0x0F
        let d3 = UInt8((raw >> 8) & 0x0F)
        let d4 = UInt8(raw & 0x0F)
        return "\(prefix)\(d1)\(String(format: "%X", d2))\(String(format: "%X", d3))\(String(format: "%X", d4))"
    }
}
