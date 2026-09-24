import Foundation

/// Where a description came from - shown in the UI so it's always clear
/// how much to trust it.
enum DtcDescriptionSource {
    /// bri3d/VW_Flash data/dtcs.csv (from the Simos18 ECM's own ODX data).
    /// Exact match on the ECU's 24-bit DTC value.
    case simos18Table
    /// Generic SAE J2012 wording for a code decoded from the DTC's bytes
    /// using the standard SAE bit layout. An interpretation, not a
    /// module-specific table.
    case saeGeneric

    var label: String {
        switch self {
        case .simos18Table: return "Simos18 table"
        case .saeGeneric: return "SAE generic"
        }
    }
}

struct DtcInfo: Hashable {
    /// e.g. "P0606-00" (SAE code, dash, failure-type byte). nil when the
    /// code couldn't be mapped to anything meaningful.
    let displayCode: String?
    let name: String?
    /// VW_Flash's internal symbol (SV_ERR_SYM_...) when the ECM table has one.
    let symbol: String?
    let source: DtcDescriptionSource?
}

/// Looks up human-readable text for a DTC. Two bundled tables:
///
/// * `simos18_ecm_dtcs.csv` - copied verbatim from bri3d/VW_Flash
///   (data/dtcs.csv, BSD-2-Clause). ECM only.
/// * `sae_generic_dtcs.csv` - generic SAE J2012 transmission / network
///   wording, used for the TCM. VW_Flash has no TCM table.
enum DtcCatalog {

    private struct EcmEntry { let pcode: String; let name: String; let symbol: String }

    private static let ecmTable: [UInt32: EcmEntry] = {
        var table: [UInt32: EcmEntry] = [:]
        for (i, row) in loadRows("simos18_ecm_dtcs").enumerated() where i > 0 && row.count >= 4 {
            guard let code = UInt32(row[0]) else { continue }
            table[code] = EcmEntry(pcode: row[1], name: row[2], symbol: row[3])
        }
        return table
    }()

    private static let saeTable: [String: String] = {
        var table: [String: String] = [:]
        for (i, row) in loadRows("sae_generic_dtcs").enumerated() where i > 0 && row.count >= 2 {
            table[row[0]] = row[1]
        }
        return table
    }()

    /// False if a bundled table failed to load, so the UI can say so
    /// instead of silently showing "no description" for everything.
    static var ecmTableLoaded: Bool { !ecmTable.isEmpty }
    static var saeTableLoaded: Bool { !saeTable.isEmpty }

    static func describe(raw: UInt32, module: DiagModule) -> DtcInfo {
        switch module {
        case .ecm:
            if let e = ecmTable[raw] {
                return DtcInfo(displayCode: formatPcode(e.pcode), name: e.name, symbol: e.symbol, source: .simos18Table)
            }
            // Not in VW_Flash's table. Show the raw value only - the ECM's
            // numbers are VW-internal, so an SAE decode would be meaningless.
            return DtcInfo(displayCode: nil, name: nil, symbol: nil, source: nil)

        case .tcm:
            let (base, ftb) = saeDecode(raw)
            let display = base + "-" + String(format: "%02X", ftb)
            if let name = saeTable[base] {
                return DtcInfo(displayCode: display, name: name, symbol: nil, source: .saeGeneric)
            }
            return DtcInfo(displayCode: display, name: nil, symbol: nil, source: nil)
        }
    }

    // MARK: Decoding helpers

    /// Standard SAE J2012 / ISO 14229 24-bit layout:
    /// byte0 bits 7-6 = letter (P/C/B/U), bits 5-4 = first digit (0-3),
    /// bits 3-0 = second digit; byte1 = third and fourth digits (hex);
    /// byte2 = failure type byte. Example: 0x173500 -> ("P1735", 0x00).
    static func saeDecode(_ raw: UInt32) -> (code: String, failureType: UInt8) {
        let b0 = UInt8((raw >> 16) & 0xFF)
        let b1 = UInt8((raw >> 8) & 0xFF)
        let b2 = UInt8(raw & 0xFF)
        let letters = ["P", "C", "B", "U"]
        let letter = letters[Int((b0 >> 6) & 0x3)]
        func hex(_ nibble: UInt8) -> String { String(nibble, radix: 16, uppercase: true) }
        let code = letter + hex((b0 >> 4) & 0x3) + hex(b0 & 0xF) + hex(b1 >> 4) + hex(b1 & 0xF)
        return (code, b2)
    }

    /// VW_Flash's pcode column is 7 characters ("P060600" = P0606 + FTB 00).
    /// Show it as "P0606-00" so the failure-type byte is visibly separate.
    private static func formatPcode(_ pcode: String) -> String {
        guard pcode.count == 7 else { return pcode }
        let base = pcode.prefix(5)
        let ftb = pcode.suffix(2)
        return "\(base)-\(ftb)"
    }

    // MARK: CSV loading

    private static func loadRows(_ resource: String) -> [[String]] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseCSV(text)
    }

    /// Small RFC-4180 parser (quoted fields, "" escapes, CRLF or LF).
    /// Note Swift treats "\r\n" as ONE Character, hence the explicit case.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
