import Foundation

/// Shared logic between the WiFi and Bluetooth ELM327 transports - both talk
/// the exact same ASCII AT-command language, just over a different pipe
/// underneath (TCP socket vs. BLE UART characteristic).
///
/// Honesty note: ELM327 is a de-facto standard, not a strict one - genuine
/// ELM327 chips and the many clones all vary slightly in exactly how they
/// format responses (whether the CAN header/byte-count prefix is included,
/// spacing, multi-frame reassembly quirks). The setup sequence below is the
/// standard one for talking UDS over 11-bit/500kbaud CAN (protocol 6, which
/// is what Simos18 uses), and the response parser is written defensively -
/// it hunts for the actual UDS response bytes (0x62.../0x7F...) rather than
/// assuming an exact prefix format - but this hasn't been verified against
/// a real dongle yet. If parsing fails on real hardware, the raw response
/// string is exactly what to inspect first.
enum Elm327Protocol {
    /// Sent once after connecting, in order. ATZ resets and needs a beat to
    /// settle - callers should pause briefly after sending it before the rest.
    static let setupCommands: [String] = [
        "ATZ",        // reset
        "ATE0",       // echo off - don't need our own command echoed back
        "ATL0",       // linefeeds off - simpler line parsing
        "ATS0",       // spaces off in responses - simpler hex parsing
        "ATH1",       // headers on - response lines include the CAN ID, so we can confirm it's really 0x7E8 talking back
        "ATCAF1",     // CAN auto-formatting on - the adapter reassembles multi-frame ISO-TP responses for us
        "ATSP6",      // protocol 6 = ISO 15765-4 CAN, 11-bit ID, 500kbaud - Simos18's bus
        "ATSH\(String(format: "%03X", BridgeProtocol.simos18RequestID))",   // set the header (transmit) CAN ID to 7E0
        "ATCRA\(String(format: "%03X", BridgeProtocol.simos18ResponseID))", // filter received CAN frames to just 7E8
    ]

    /// Builds the line to send for a UDS request - just the raw payload
    /// bytes as hex, no spaces, terminated by \r (0x0D).
    static func requestLine(for payload: Data) -> String {
        payload.map { String(format: "%02X", $0) }.joined() + "\r"
    }

    static func command(_ command: String) -> String { command + "\r" }

    /// Pulls the UDS response bytes back out of whatever the adapter sent.
    /// Strips everything that isn't a hex character (handles the '>' prompt,
    /// stray CR/LF, and an optional "7E8" header prefix if ATH1 kept it),
    /// then looks for the response starting at a genuine UDS response byte
    /// (0x62 for positive, 0x7F for negative) rather than assuming a fixed
    /// prefix layout, since that varies between adapters.
    static func extractUdsResponse(from raw: String) -> Data? {
        let hexOnly = raw.filter { $0.isHexDigit }
        guard hexOnly.count >= 2, hexOnly.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        var idx = hexOnly.startIndex
        while idx < hexOnly.endIndex {
            let next = hexOnly.index(idx, offsetBy: 2)
            guard let byte = UInt8(hexOnly[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }

        // Find the first 0x62 (positive ReadDataByIdentifier response) or
        // 0x7F (negative response) and treat everything from there as the
        // UDS payload - anything before it is CAN header/byte-count noise
        // depending on the adapter's exact ATH/CAF formatting.
        guard let startIdx = bytes.firstIndex(where: { $0 == 0x62 || $0 == 0x7F }) else { return nil }
        return Data(bytes[startIdx...])
    }
}
