import Foundation

/// Port of Communication/Simos18/Simos1810ModuleInfo.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/modules/simos1810.py and
/// lib/modules/simosshared.py - trimmed the same way as Simos18ModuleInfo.
enum Simos1810ModuleInfo {
    static let blockNamesFrf: [Int: String] = [
        1: "FD_01DATA", // CBOOT
        2: "FD_02DATA", // ASW1
        3: "FD_03DATA", // ASW2
        4: "FD_04DATA", // ASW3
        5: "FD_05DATA", // CAL
    ]

    /// Box code location is shared across all Simos modules - same as Simos18.1.
    static let calBoxCodeLocation = (start: 0x60, end: 0x6B)

    static let boxCodeLocation: [Int: (start: Int, end: Int)] = [
        1: (0x0, 0x0), 2: (0x0, 0x0), 3: (0x0, 0x0), 4: (0x0, 0x0), 5: (0x60, 0x6B),
    ]

    /// Same standard OBD-II physical addressing as Simos18.1.
    static let rxid: UInt16 = 0x7E8
    static let txid: UInt16 = 0x7E0

    /// Shared across all Simos modules.
    static let checksumBlockLocation: [Int: Int] = [
        1: 0x300, 2: 0x300, 3: 0x0, 4: 0x0, 5: 0x300, 6: 0x340,
    ]

    static let ecm3CalMonitorAddressesEarly = 0x540
    static let ecm3CalMonitorAddresses = 0x520
    static let ecm3CalMonitorOffsetUncached: Int64 = 0
    static let ecm3CalMonitorOffsetCached: Int64 = 0x20000000
    static let ecm3CalMonitorChecksum = 0x400

    static let ecm3 = Ecm3Constants(
        checksumOffset: ecm3CalMonitorChecksum,
        addressesOffset: ecm3CalMonitorAddresses,
        addressesOffsetEarly: ecm3CalMonitorAddressesEarly,
        offsetUncached: ecm3CalMonitorOffsetUncached,
        offsetCached: ecm3CalMonitorOffsetCached
    )

    static let baseAddresses: [Int: UInt32] = [
        0: 0x80000000, // SBOOT
        1: 0x80800000, // CBOOT
        2: 0x80020000, // ASW1
        3: 0x80100000, // ASW2
        4: 0x808C0000, // ASW3
        5: 0xA0820000, // CAL
        6: 0x80880000, // CBOOT_temp
    ]

    static let binfileOffsets: [Int: Int] = [
        0: 0x0,
        1: 0x200000, // CBOOT
        2: 0x20000,  // ASW1
        3: 0x100000, // ASW2
        4: 0x2C0000, // ASW3
        5: 0x220000, // CAL
    ]

    static let binfileSize = 4194304
    static let projectName = "SCG"

    static let blockLengths: [Int: Int] = [
        1: 0x1FE00,  // CBOOT
        2: 0xDFC00,  // ASW1
        3: 0xFFC00,  // ASW2
        4: 0x13FC00, // ASW3
        5: 0x9FC00,  // CAL
        6: 0x1FE00,  // CBOOT_temp
    ]

    /// Shared across all Simos modules.
    static let blockTransferSizes: [Int: Int] = [1: 0xFFD, 2: 0xFFD, 3: 0xFFD, 4: 0xFFD, 5: 0xFFD]

    static let softwareVersionLocation: [Int: (start: Int, end: Int)] = [
        1: (0x437, 0x43F),
        2: (0x627, 0x62F),
        3: (0x203, 0x20B),
        4: (0x203, 0x20B),
        5: (0x23, 0x2B),
    ]

    static let blockIdentifiers: [Int: UInt8] = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5]
    static let udsBlockChecksum: [UInt8] = [0x00, 0x00, 0x00, 0x00]

    /// Extracted programmatically from the C# source, same as Simos18ModuleInfo.
    static let sa2Script: [UInt8] = hexToBytes("6803814A10680293050520154A058722121954824993F423BF7D824A05875A63FC5E824A0181494C")
    static let aesKey: [UInt8] = hexToBytes("AE540502E48E3854DBCA1A1545BA6F33")
    static let aesIv: [UInt8] = hexToBytes("62F313FA5C08532798BCA452471D20D5")

    /// Only block 2 / ASW1 is supported - bespoke to the exact byte layout of simos18_10_unlock_patch.bin.
    static func blockTransferSizesPatch(blockNumber: Int, address: Int) -> Int {
        precondition(blockNumber == 2, "Only patching Simos18.10's Block 2 / ASW1 using a provided patch is supported at this time.")
        if address < 0x5CB00 { return 0x100 }
        if address < 0x5CC00 { return 0x8 }
        if address < 0xB3000 { return 0x100 }
        if address < 0xB3100 { return 0x8 }
        if address < 0xDFB00 { return 0x100 }
        return 0x8
    }

    static let patchInfo = UnlockPatchInfo(
        patchBoxCode: "5G0906259Q__0005",
        patchBlockIndex: 2, // ASW1
        patchFilePath: "simos18_10_unlock_patch.bin"
    )
}
