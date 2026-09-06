import Foundation

enum ChecksumState {
    case validChecksum
    case invalidChecksum
    case fixedChecksum
}

/// Port of Communication/Simos18/Crypto/BlockChecksum.cs: validate() and
/// fix() - the "normal" per-block security header check. Does NOT include
/// the ECM3 CAL-monitoring checksum (see Ecm3Checksum.swift) - that's a
/// separate, more involved secondary checksum ported independently, same
/// split as the C# original.
///
/// Header layout (preserved from the C#'s comment):
///   +0: initial checksum value (always 0 observed)
///   +4: the "correct" checksum - little-endian CRC32 of all checksummed
///       areas run sequentially
///   +8: count of areas to checksum (up to 16 in some Simos versions)
///   +12, +16, ...: [start, end] address pairs, little-endian absolute
///                  addresses (subtract the block's base address to get
///                  an offset into this block's own data)
enum BlockChecksum {
    static func validate(
        checksumBlockLocation: [Int: Int],
        baseAddresses: [Int: UInt32],
        dataBinary: [UInt8],
        blockNum: Int,
        shouldFix: Bool = false
    ) -> (state: ChecksumState, data: [UInt8]) {
        let checksumLocation = checksumBlockLocation[blockNum]!

        let currentChecksum = readUInt32LE(dataBinary, checksumLocation + 4)
        let checksumAreaCount = Int(dataBinary[checksumLocation + 8])
        let baseAddress = baseAddresses[blockNum]!

        var offsets: [Int64] = []
        for i in 0..<(checksumAreaCount * 2) {
            let address = readUInt32LE(dataBinary, checksumLocation + 12 + (i * 4))
            let offset = Int64(address) - Int64(baseAddress)
            offsets.append(offset)
        }

        var checksumData: [UInt8] = []
        var i = 0
        while i < offsets.count {
            let startAddress = Int(offsets[i])
            let endAddress = Int(offsets[i + 1])
            // Python slice end is exclusive, so +1 makes this an inclusive range.
            let length = endAddress + 1 - startAddress
            checksumData.append(contentsOf: dataBinary[startAddress..<(startAddress + length)])
            i += 2
        }

        let checksum = Crc32Simos.compute(Data(checksumData))

        if checksum == currentChecksum {
            return (.validChecksum, dataBinary)
        } else {
            if shouldFix {
                return fix(dataBinary: dataBinary, checksum: checksum, checksumLocation: checksumLocation)
            } else {
                return (.invalidChecksum, dataBinary)
            }
        }
    }

    static func fix(dataBinary: [UInt8], checksum: UInt32, checksumLocation: Int) -> (state: ChecksumState, data: [UInt8]) {
        var result = dataBinary
        writeUInt32LE(&result, checksumLocation + 4, checksum)
        return (.fixedChecksum, result)
    }

    private static func readUInt32LE(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
