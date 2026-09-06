import Foundation

/// Port of Communication/J2534/Uds/WorkshopCode.cs. Decodes the 9-byte
/// "workshop code" fingerprint format some Simos flash-tools write to DID
/// 0xF15B ("Fingerprint and Programming Date"): [YY MM DD (BCD)] [ASW CRC8]
/// [4 bytes CAL ID] [CRC8 of the whole thing]. Only the decode direction is
/// ported, same as the C# - nothing in this app writes a workshop code back.
struct WorkshopCode {
    var flashDate: Date
    var isValid: Bool
    var isOld: Bool
    var calId: [UInt8]
    var aswChecksum: Int

    /// Mirrors WorkshopCode(workshop_code=...) - decodes an existing 9-byte code.
    static func decode(_ workshopCode: [UInt8]) -> WorkshopCode {
        var isOld = false

        var components = DateComponents()
        let year = Bcd.convertFromBcd(Int(workshopCode[0]))
        let month = Bcd.convertFromBcd(Int(workshopCode[1]))
        let day = Bcd.convertFromBcd(Int(workshopCode[2]))
        components.year = year <= 0 ? 1 : year
        components.month = month
        components.day = day

        let calendar = Calendar(identifier: .gregorian)
        let flashDate = calendar.date(from: components) ?? Date()

        let isValid = isWorkshopCodeValid(workshopCode)
        var calId: [UInt8]
        var aswChecksum: Int

        if isValid {
            calId = Array(workshopCode[4..<8])
            aswChecksum = Int(workshopCode[3])
        } else {
            if workshopCode.count > 4, workshopCode[3] == 0x42, workshopCode[4] == 0x04 {
                isOld = true
            }
            calId = Array("UNKN".utf8)
            aswChecksum = 0
        }

        return WorkshopCode(flashDate: flashDate, isValid: isValid, isOld: isOld, calId: calId, aswChecksum: aswChecksum)
    }

    private static func isWorkshopCodeValid(_ workshopCode: [UInt8]) -> Bool {
        guard workshopCode.count >= 9 else { return false }
        let first8 = Array(workshopCode[0..<8])
        let crc = Crc8Vw.hash(Data(first8))
        return workshopCode[8] == crc
    }

    /// Mirrors human_readable().
    func humanReadable() -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: flashDate)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM dd"
        let monthDay = formatter.string(from: flashDate)
        let dateText = "\(year) \(monthDay)"
        var fingerprint = "Block fingerprint dated '\(dateText)"

        if isValid {
            fingerprint += " is valid and was written by SimosTools or VW_Flash. "
        } else if isOld {
            fingerprint += " was written by an older version of SimosTools or VW_Flash."
            return fingerprint
        } else {
            fingerprint += " does not appear to be from SimosTools or VW_Flash."
            return fingerprint
        }

        fingerprint += "It was written with ASW Checksum "
        fingerprint += String(aswChecksum)
        fingerprint += " and CAL ID : "
        fingerprint += String(decoding: calId, as: UTF8.self)
        return fingerprint
    }
}

/// Port of WorkshopCodeCodec.decode(): hex dump of the raw payload, followed
/// by human-readable fingerprints for each 10-byte chunk (workshop codes are
/// stored back-to-back, most recent last).
enum WorkshopCodeCodec {
    static func decode(_ payload: [UInt8]) -> String {
        var result = payload.map { String(format: "%02x", $0) }.joined()
        result += "\n"

        var lines: [String] = []
        var i = 0
        while i < payload.count {
            let chunkLen = min(10, payload.count - i)
            let chunk = Array(payload[i..<(i + chunkLen)])
            i += 10

            if chunk.count < 9 { continue } // matches Python's chunk[0:9] silently truncating short trailing data

            let codeBytes = Array(chunk[0..<9])
            lines.append(WorkshopCode.decode(codeBytes).humanReadable())
        }

        result += lines.joined(separator: "\n")
        return result
    }
}
