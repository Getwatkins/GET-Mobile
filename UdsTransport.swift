import Foundation

/// Anything that can send a UDS request on one CAN ID and hand back the
/// ECU's response on another - the ESP32 bridge, an ELM327 WiFi dongle, and
/// an ELM327 BLE dongle all implement this the same way from the app's
/// point of view, even though the wire protocol underneath each one is
/// completely different.
protocol UdsTransport: AnyObject {
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double) async throws -> Data
    func disconnect()
}

extension UdsTransport {
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data) async throws -> Data {
        try await sendRequest(rxID: rxID, txID: txID, payload: payload, timeoutSeconds: 2.0)
    }
}
