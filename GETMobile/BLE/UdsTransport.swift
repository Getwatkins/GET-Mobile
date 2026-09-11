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
}

/// Optional high-speed logging transport. Simos HSL repurposes the 0x3E
/// heartbeat service: 0x3E32 chunks configure the memory-address list, 0x3E33
/// enables/persists the stream, and subsequent 0x3E33 requests return packed
/// HSL samples. Implementations that can collect that stream provide this
/// specialized path.
@MainActor
protocol HslRawTransport: AnyObject {
    func sendHslRequest(_ payload: Data, expectedPayloadBytes: Int, timeoutSeconds: Double) async throws -> Data
}

extension UdsTransport {
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data) async throws -> Data {
        try await sendRequest(rxID: rxID, txID: txID, payload: payload, timeoutSeconds: 2.0)
    }
}
