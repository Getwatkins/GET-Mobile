import Foundation

/// Anything that can send a UDS request on one CAN ID and hand back the
/// ECU's response on another - the ESP32 bridge, an ELM327 WiFi dongle, and
/// an ELM327 BLE dongle all implement this the same way from the app's
/// point of view, even though the wire protocol underneath each one is
/// completely different.
@MainActor
protocol UdsTransport: AnyObject {
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double) async throws -> Data

    /// Waits for another response on the currently-outstanding request
    /// *without* resending it. Needed because ISO 14229's NRC 0x78
    /// ("response pending") means "I'm still working, keep waiting" - the
    /// client must not resend, or the ECU may treat it as a brand new
    /// request and restart whatever slow operation (e.g. flash erase) it
    /// was already partway through. This is a routine occurrence during
    /// flashing, not an edge case.
    func waitForResponse(timeoutSeconds: Double) async throws -> Data

    func disconnect()

    /// Lets a caller doing a long bulk transfer (currently: only the
    /// TransferData loop of a normal block flash) request a tighter
    /// minimum gap between outgoing ISO-TP consecutive frames than the
    /// transport's own default. Only GVRET has a software pacing floor to
    /// begin with (see IsoTp.minimumSendIntervalSeconds's doc comment for
    /// why it exists) - the BLE bridge and ELM327 hand frame timing off to
    /// their own firmware/adapter and have nothing to override, so they
    /// get the no-op default below for free. Pass nil to restore the
    /// transport's normal default pacing.
    /// Immediately abandons whatever ISO-TP wait is currently in flight,
    /// resolving it as if it had timed out, and frees the transport for a
    /// new caller. Exists because Task cancellation does NOT interrupt a
    /// custom continuation-based wait like this transport's - only
    /// GvretWifiManager implements this for real (see its doc comment for
    /// the incident that prompted it); other transports get the no-op
    /// default and don't need it for the same reason they don't need
    /// setBulkTransferPacing.
    func abandonPendingOperation()

    /// Gives HSL exclusive ownership of the shared ECU CAN transaction path.
    /// GVRET implements this because HSL and normal UDS/gauge traffic share
    /// 0x7E0/0x7E8. Other transports get a no-op default.
    func beginHslExclusive() async

    /// Releases the HSL transaction lock so normal UDS/gauge traffic can resume.
    func endHslExclusive()
}

extension UdsTransport {
    func setBulkTransferPacing(_ intervalSeconds: Double?) {}
    func abandonPendingOperation() {}
    func beginHslExclusive() async {}
    func endHslExclusive() {}
}

/// Optional high-speed logging transport. HSL is not a normal ISO-TP response:
/// the patched Simos application acknowledges the 0x3E04 request with 0x7E and
/// then streams the configured payload as raw CAN frames. Implementations that
/// can collect that stream can provide this specialized path.
@MainActor
protocol HslRawTransport: AnyObject {
    func sendHslRequest(_ payload: Data, expectedPayloadBytes: Int, timeoutSeconds: Double) async throws -> Data
}

extension UdsTransport {
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data) async throws -> Data {
        try await sendRequest(rxID: rxID, txID: txID, payload: payload, timeoutSeconds: 2.0)
    }
}
