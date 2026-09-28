import Foundation

/// Port of VW_Flash's lib/modules/dq381.py (bri3d, BSD-2-Clause) - the
/// Bosch DQ381-MQB DSG. Values transcribed directly from that file.
///
/// Scope implemented here: CAL (block 3) only, per the user's own
/// description - the bootloader (block 1) doesn't need to be touched for
/// this module, and ASW (block 2) is left alone for the same "don't touch
/// the application software" reasoning as DQ250 above.
enum Dq381ModuleInfo {
    static let rxid: UInt16 = 0x7E9
    static let txid: UInt16 = 0x7E1

    static let calBlockNumber = 3

    static let blockNamesFrf: [Int: String] = [3: "FD_03DATA"]

    /// Unlike DQ250, DQ381's block identifiers ARE just the block numbers.
    static let blockIdentifiers: [Int: UInt8] = [3: 3]

    static let blockLengths: [Int: Int] = [3: 0x3FE00]

    static let blockTransferSizes: [Int: Int] = [3: 0xF0]

    /// Absolute base address CAL's own embedded checksum-range pointers
    /// (read from the binary itself - see DsgChecksum.dq381Validate) are
    /// expressed relative to.
    static let calBaseAddress = 0x140200

    static let boxCodeLocation: [Int: (start: Int, end: Int)] = [3: (0x0, 0x0)]

    /// AES-128-CBC. Yes, this key and IV really are just sequential bytes
    /// in VW_Flash's own shipped source (00-0F / 10-1F) - not a
    /// transcription shortcut taken here. See the flash notes for why this
    /// gave me pause and what settled it.
    static let aesKey: [UInt8] = hexToBytes("000102030405060708090A0B0C0D0E0F")
    static let aesIv: [UInt8] = hexToBytes("101112131415161718191A1B1C1D1E1F")

    static let sa2Script: [UInt8] = hexToBytes("6806814A05876B5F7DD5494C")

    static let binfileOffsets: [Int: Int] = [3: 0x140200]
    static let binfileSize = 0x180000
    static let projectName = "F"
    static let softwareVersionLocation: [Int: (start: Int, end: Int)] = [3: (0x0, 0x0)]
}
