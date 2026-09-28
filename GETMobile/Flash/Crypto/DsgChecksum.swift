import Foundation

/// Ports of lib/dsg_checksum.py (DQ250) and lib/dq381_checksum.py (DQ381)
/// from bri3d/VW_Flash (BSD-2-Clause). Two distinct, unrelated embedded
/// checksum schemes - grouped here only because both are DSG-family and
/// both feed the same DsgBlockPreparer step.
enum DsgChecksum {
    /// DQ250: JAMCRC (the bitwise complement of standard CRC-32) over every
    /// byte except the last 4, written little-endian into those last 4
    /// bytes. Used for ASW/CAL (blocks 3/4) - NOT the Driver (block 2),
    /// which uses a different, external, fixed-value mechanism instead
    /// (see Dq250ModuleInfo.blockChecksums).
    static func fixJamCrc(_ data: [UInt8]) -> [UInt8] {
        guard data.count >= 4 else { return data }
        var result = data
        let crc = StandardCrc32.compute(data[0..<(data.count - 4)])
        let jamCrc = 0xFFFFFFFF &- crc
        let bytes = withUnsafeBytes(of: jamCrc.littleEndian) { Array($0) }
        result.replaceSubrange((data.count - 4)..<data.count, with: bytes)
        return result
    }

    /// DQ381: standard CRC-32 (not inverted) over a byte RANGE whose
    /// start/end addresses are themselves read out of the block's own
    /// bytes (as big-endian absolute addresses at fixed offsets 0x38/0x3C,
    /// converted to file-relative offsets by subtracting the block's base
    /// address), written big-endian at offset 0x44.
    /// Returns nil (rather than the unmodified data) when the block's own
    /// embedded range pointers don't make sense - that means a wrong or
    /// corrupt file, and silently flashing it as-is would be exactly the
    /// wrong response.
    static func fixDq381(_ data: [UInt8], baseAddress: Int) -> [UInt8]? {
        let checksumLocation = 0x44, startLocation = 0x38, endLocation = 0x3C
        guard data.count >= checksumLocation + 4, data.count >= endLocation + 4 else { return nil }

        func readU32BE(_ offset: Int) -> Int {
            (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
        }

        let start = readU32BE(startLocation) - baseAddress
        let end = readU32BE(endLocation) - baseAddress
        // Python: data_binary[checksum_start : checksum_end + 1] - an
        // inclusive end, unlike Swift's usual half-open convention.
        guard start >= 0, end >= start, end + 1 <= data.count else { return nil }

        let crc = StandardCrc32.compute(data[start..<(end + 1)])
        var result = data
        let bytes = withUnsafeBytes(of: crc.bigEndian) { Array($0) }
        result.replaceSubrange(checksumLocation..<(checksumLocation + 4), with: bytes)
        return result
    }
}
