import Foundation

/// The two control modules the diagnostics screen can talk to. CAN IDs
/// match VW_Flash: the Simos18 ECM is 0x7E0/0x7E8 and both the DQ250-MQB
/// and DQ381-MQB DSG TCMs are 0x7E1/0x7E9.
enum DiagModule: String, CaseIterable, Identifiable {
    case ecm
    case tcm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ecm: return "Engine (ECM)"
        case .tcm: return "Transmission (TCM)"
        }
    }

    var shortName: String {
        switch self {
        case .ecm: return "ECM"
        case .tcm: return "TCM"
        }
    }

    var txID: UInt16 { self == .ecm ? 0x7E0 : 0x7E1 }
    var rxID: UInt16 { self == .ecm ? 0x7E8 : 0x7E9 }

    /// VW's functional ("broadcast") request address, used by VW_Flash to
    /// send OBD-II Mode 04 (clear emissions DTCs). Only ever a fallback.
    static let functionalTxID: UInt16 = 0x700
}

/// ISO 14229-1 DTC status byte.
struct DtcStatus: OptionSet, Hashable {
    let rawValue: UInt8

    static let testFailed                       = DtcStatus(rawValue: 0x01)
    static let testFailedThisOperationCycle     = DtcStatus(rawValue: 0x02)
    static let pending                          = DtcStatus(rawValue: 0x04)
    static let confirmed                        = DtcStatus(rawValue: 0x08)
    static let testNotCompletedSinceLastClear   = DtcStatus(rawValue: 0x10)
    static let testFailedSinceLastClear         = DtcStatus(rawValue: 0x20)
    static let testNotCompletedThisCycle        = DtcStatus(rawValue: 0x40)
    static let warningIndicatorRequested        = DtcStatus(rawValue: 0x80)

    /// One entry per set bit, in bit order, worded for a human.
    var flagLabels: [String] {
        var labels: [String] = []
        if contains(.testFailed) { labels.append("Test failed (present now)") }
        if contains(.testFailedThisOperationCycle) { labels.append("Failed this operation cycle") }
        if contains(.pending) { labels.append("Pending") }
        if contains(.confirmed) { labels.append("Confirmed") }
        if contains(.testNotCompletedSinceLastClear) { labels.append("Test not completed since clear") }
        if contains(.testFailedSinceLastClear) { labels.append("Failed since last clear") }
        if contains(.testNotCompletedThisCycle) { labels.append("Test not completed this cycle") }
        if contains(.warningIndicatorRequested) { labels.append("Warning light requested") }
        return labels
    }

    enum Summary {
        case active      // failing right now
        case stored      // confirmed, not failing at the moment
        case pending     // seen once, not yet confirmed
        case history     // failed since last clear, otherwise quiet
    }

    var summary: Summary {
        if contains(.testFailed) { return .active }
        if contains(.confirmed) { return .stored }
        if contains(.pending) { return .pending }
        return .history
    }
}

struct DiagnosticTroubleCode: Identifiable, Hashable {
    /// Position in the ECU's response. Deliberately NOT the DTC value:
    /// keeps SwiftUI ids unique even if a module ever repeats a code
    /// (same class of bug as the earlier Identifiable-id collision).
    let id: Int
    let module: DiagModule
    /// Full 24-bit DTC exactly as received (3 bytes, big-endian).
    let raw: UInt32
    let statusByte: UInt8
    let info: DtcInfo

    var status: DtcStatus { DtcStatus(rawValue: statusByte) }
    var rawHex: String { String(format: "0x%06X", raw) }
}

enum DtcParser {
    enum ParseError: Error, LocalizedError {
        case empty
        var errorDescription: String? { "The module returned an empty DTC response." }
    }

    struct Parsed {
        let availabilityMask: UInt8
        let entries: [(raw: UInt32, status: UInt8)]
        /// Bytes left over that didn't form a whole 4-byte record (should be 0).
        let strayBytes: Int
    }

    /// `payload` is what `UdsClient.readDtcByStatusMask` returns: the
    /// response with SID (0x59) and subfunction echo (0x02) already
    /// stripped - `[availabilityMask]` then `[DTC hi][DTC mid][DTC lo][status]`
    /// repeated once per DTC.
    static func parse(_ payload: Data) throws -> Parsed {
        let bytes = [UInt8](payload)
        guard let mask = bytes.first else { throw ParseError.empty }

        var entries: [(raw: UInt32, status: UInt8)] = []
        var index = 1
        while index + 4 <= bytes.count {
            let raw = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8) | UInt32(bytes[index + 2])
            entries.append((raw, bytes[index + 3]))
            index += 4
        }
        return Parsed(availabilityMask: mask, entries: entries, strayBytes: bytes.count - index)
    }
}
