import Foundation

/// Reads and clears fault codes on the ECM and TCM.
///
/// Mirrors what VW_Flash does (`get_dtcs`): switch the module to the
/// extended diagnostic session, then ReadDTCInformation 0x19 sub-function
/// 0x02 (reportDTCByStatusMask). VW_Flash's default status mask is 0xAB
/// (test failed, failed this cycle, confirmed, failed since clear,
/// warning light) - same default here.
///
/// Clearing goes one step beyond VW_Flash, which only sends the OBD-II
/// Mode 04 broadcast (emissions DTCs only, and can't target the TCM):
/// first a proper per-module UDS ClearDiagnosticInformation (0x14,
/// group 0xFFFFFF); if the module refuses that, fall back to VW_Flash's
/// Mode 04 on the VW functional address 0x700. Either way the module is
/// re-read afterwards so the screen shows what's really left.
@MainActor
final class DiagnosticsSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case reading(DiagModule)
        case clearing(DiagModule)
    }

    struct ModuleResult {
        let dtcs: [DiagnosticTroubleCode]
        let readAt: Date
        let statusMask: UInt8
        /// Non-nil if the response had oddities worth telling the user about.
        let warning: String?
    }

    /// VW_Flash's default (Dtc.Status with the "reasonable failures" bits).
    static let standardMask: UInt8 = 0xAB
    /// Standard mask plus the "pending" bit.
    static let includePendingMask: UInt8 = 0xAF

    @Published var selectedModule: DiagModule = .ecm
    @Published var includePending = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [DiagModule: ModuleResult] = [:]
    @Published private(set) var infoMessage: String?
    @Published private(set) var errorMessage: String?

    private var transport: UdsTransport?

    var isBusy: Bool { phase != .idle }
    var canRun: Bool { transport != nil && !isBusy }

    func attach(transport: UdsTransport) {
        self.transport = transport
    }

    /// Called on disconnect - stale codes from a previous connection
    /// shouldn't be shown against whatever gets connected next.
    func reset() {
        transport = nil
        phase = .idle
        results = [:]
        infoMessage = nil
        errorMessage = nil
    }

    // MARK: Read

    func read(_ module: DiagModule) async {
        guard let transport, !isBusy else { return }
        phase = .reading(module)
        infoMessage = nil
        errorMessage = nil
        defer { phase = .idle }

        let client = UdsClient(transport: transport, rxID: module.rxID, txID: module.txID)
        do {
            try await enterExtendedSession(client)
            let result = try await readCodes(client: client, module: module)
            results[module] = result
            if result.dtcs.isEmpty {
                infoMessage = "\(module.shortName): no fault codes stored."
            }
        } catch {
            errorMessage = describe(error, module: module, action: "read fault codes")
        }
    }

    // MARK: Clear

    func clear(_ module: DiagModule) async {
        guard let transport, !isBusy else { return }
        phase = .clearing(module)
        infoMessage = nil
        errorMessage = nil
        defer { phase = .idle }

        let client = UdsClient(transport: transport, rxID: module.rxID, txID: module.txID)
        var method = "UDS ClearDiagnosticInformation (0x14)"

        do {
            try await enterExtendedSession(client)

            do {
                try await client.clearDiagnosticInformation()
            } catch let primary as UdsNegativeResponseException {
                // Module said no to 0x14 - try VW_Flash's method before giving up.
                do {
                    try await obdClear(transport: transport, module: module)
                    method = "OBD-II Mode 04 (VW_Flash method)"
                } catch {
                    errorMessage = "\(module.shortName) refused the clear request. "
                        + describe(primary, module: module, action: "clear fault codes")
                        + " Fallback (OBD-II Mode 04) also failed: \(error.localizedDescription)"
                    return
                }
            }
        } catch {
            errorMessage = describe(error, module: module, action: "clear fault codes")
            return
        }

        // Give the module a moment to finish, then read back what's left.
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            let result = try await readCodes(client: client, module: module)
            results[module] = result
            if result.dtcs.isEmpty {
                infoMessage = "\(module.shortName) codes cleared via \(method). Re-read shows no fault codes."
            } else {
                infoMessage = "Clear accepted (\(method)), but \(result.dtcs.count) code(s) are still reported. "
                    + "Anything still failing right now is set again immediately - fix the cause, then clear again."
            }
        } catch {
            results[module] = nil
            infoMessage = "\(module.shortName) accepted the clear request (\(method)), but the re-read to verify failed: "
                + "\(error.localizedDescription) Tap Read Codes to check."
        }
    }

    // MARK: Report

    /// Plain-text report for the share sheet.
    func reportText(for module: DiagModule) -> String? {
        guard let result = results[module] else { return nil }
        var lines: [String] = []
        let stamp = DateFormatter.localizedString(from: result.readAt, dateStyle: .short, timeStyle: .medium)
        lines.append("GET Mobile - \(module.title) fault codes")
        lines.append("Read: \(stamp)   Status mask: \(String(format: "0x%02X", result.statusMask))   Count: \(result.dtcs.count)")
        lines.append("")
        if result.dtcs.isEmpty { lines.append("No fault codes stored.") }
        for dtc in result.dtcs {
            let code = dtc.info.displayCode ?? "(unmapped)"
            let name = dtc.info.name ?? "No description available"
            lines.append("\(code)  \(name)")
            lines.append("    raw \(dtc.rawHex) = \(dtc.raw)   status \(String(format: "0x%02X", dtc.statusByte)): \(dtc.status.flagLabels.joined(separator: ", "))")
            if let symbol = dtc.info.symbol { lines.append("    \(symbol)") }
        }
        if let warning = result.warning { lines.append(""); lines.append("Note: \(warning)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Internals

    /// VW_Flash switches to the extended session before reading. Some
    /// modules also allow the read in the default session, so a plain
    /// refusal (NRC) is not fatal - carry on. A transport error (no reply
    /// at all) *is* fatal: nothing after it would work either.
    private func enterExtendedSession(_ client: UdsClient) async throws {
        do {
            try await client.changeSession(.extendedDiagnostic)
        } catch is UdsNegativeResponseException {
            // continue in whatever session the module is already in
        }
    }

    private func readCodes(client: UdsClient, module: DiagModule) async throws -> ModuleResult {
        let mask = includePending ? Self.includePendingMask : Self.standardMask
        let payload = try await client.readDtcByStatusMask(mask)
        let parsed = try DtcParser.parse(payload)

        var dtcs: [DiagnosticTroubleCode] = []
        for (index, entry) in parsed.entries.enumerated() {
            dtcs.append(DiagnosticTroubleCode(
                id: index,
                module: module,
                raw: entry.raw,
                statusByte: entry.status,
                info: DtcCatalog.describe(raw: entry.raw, module: module)
            ))
        }

        var warnings: [String] = []
        if parsed.strayBytes > 0 {
            warnings.append("Response had \(parsed.strayBytes) unexpected trailing byte(s); they were ignored.")
        }
        if module == .ecm, !DtcCatalog.ecmTableLoaded {
            warnings.append("The bundled Simos18 DTC description table failed to load, so no descriptions are shown.")
        }
        return ModuleResult(
            dtcs: dtcs,
            readAt: Date(),
            statusMask: mask,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    private enum ObdClearError: Error, LocalizedError {
        case rejected(UInt8)
        case unexpected(String)
        var errorDescription: String? {
            switch self {
            case .rejected(let nrc): return String(format: "negative response 0x%02X.", nrc)
            case .unexpected(let hex): return "unexpected reply \(hex)."
            }
        }
    }

    /// VW_Flash: `send_obd(bytes([0x4]))` on the functional address, with
    /// the module's own response ID as the listen address.
    private func obdClear(transport: UdsTransport, module: DiagModule) async throws {
        let client = UdsClient(transport: transport, rxID: module.rxID, txID: DiagModule.functionalTxID)
        let reply = try await client.sendRequest(Data([0x04]))
        let response = [UInt8](reply)
        if response.first == 0x44 { return }
        if response.count >= 3, response[0] == 0x7F { throw ObdClearError.rejected(response[2]) }
        throw ObdClearError.unexpected(response.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    private func describe(_ error: Error, module: DiagModule, action: String) -> String {
        if let nrc = error as? UdsNegativeResponseException {
            let code = String(format: "0x%02X", nrc.negativeResponseCode)
            switch nrc.negativeResponseCode {
            case 0x11, 0x7F:
                return "\(module.shortName) does not support this request in its current state (\(code)). "
                    + "Note: an ECU running an unlocked/tuned flash state may not answer diagnostic DTC requests."
            case 0x12, 0x7E:
                return "\(module.shortName) does not support that sub-function in the current session (\(code))."
            case 0x22:
                return "\(module.shortName) says conditions are not correct (\(code)). Try ignition on with the engine off, and the car stationary."
            case 0x31:
                return "\(module.shortName) rejected the request as out of range (\(code))."
            case 0x33:
                return "\(module.shortName) requires security access for this request (\(code))."
            default:
                return "Couldn't \(action) on \(module.shortName): \(nrc.localizedDescription)"
            }
        }
        return "Couldn't \(action) on \(module.shortName): \(error.localizedDescription) "
            + "Check ignition is on and the module is fitted and reachable."
    }
}
