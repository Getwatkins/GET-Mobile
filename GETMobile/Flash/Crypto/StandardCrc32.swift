import Foundation

/// The standard, reflected CRC-32 (polynomial 0xEDB88320, init 0xFFFFFFFF,
/// final XOR 0xFFFFFFFF) - the one used by zlib, PKZIP, gzip, PNG, and by
/// Python's `zlib.crc32`. NOT the same algorithm as Crc32Simos (that one is
/// a different, non-reflected MSB-first variant specific to Simos' own
/// block-header format) - this is the variant VW_Flash's DSG/DQ381 checksum
/// modules (dsg_checksum.py, dq381_checksum.py) use, both directly via
/// `zlib.crc32`. Table-driven, verified against the standard CRC-32 check
/// value (crc32("123456789") == 0xCBF43926) during development.
enum StandardCrc32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func compute(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func compute(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
