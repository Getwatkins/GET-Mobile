import Foundation

/// Port of Communication/J2534/Uds/Bcd.cs.
enum Bcd {
    static func convertToBcd(_ decimalValue: Int) -> Int {
        var value = decimalValue
        var place = 0
        var bcd = 0
        while value > 0 {
            let nibble = value % 10
            bcd += nibble << place
            value /= 10
            place += 4
        }
        return bcd
    }

    static func convertFromBcd(_ hexValue: Int) -> Int {
        // Python: hex.to_bytes(4, "big") then iterates all 4 bytes - for a
        // value that only occupies the low byte (as it always does here, a
        // single BCD-encoded byte), the upper 3 bytes are zero and
        // contribute 0 to the result, so iterating just the low byte is
        // equivalent for the actual inputs this is called with, but the
        // full 4-byte loop is kept for exact fidelity, matching the C# port.
        let bytes: [UInt8] = [
            UInt8((hexValue >> 24) & 0xFF),
            UInt8((hexValue >> 16) & 0xFF),
            UInt8((hexValue >> 8) & 0xFF),
            UInt8(hexValue & 0xFF),
        ]
        var result = 0
        for b in bytes {
            result = result * 100 + Int(b >> 4) * 10 + Int(b & 0xF)
        }
        return result
    }
}
