import Foundation

/// Port of Communication/Simos18/Simos18ModuleInfo.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/modules/simos18.py and
/// lib/modules/simosshared.py.
///
/// NOT ported here: the SA2 script's *execution* (that's Sa2SeedKeyVm,
/// already in Flash/Crypto/ from Phase 1) and the patch-specific
/// block-transfer-size function beyond what's included below.
enum Simos18ModuleInfo {
    /// FRF internal block names, keyed by UDS block number.
    static let blockNamesFrf: [Int: String] = [
        1: "FD_0", // CBOOT
        2: "FD_1", // ASW1
        3: "FD_2", // ASW2
        4: "FD_3", // ASW3
        5: "FD_4", // CAL
    ]

    /// Only block 5 (CAL) has a non-empty range.
    static let calBoxCodeLocation = (start: 0x60, end: 0x6B)

    static let boxCodeLocation: [Int: (start: Int, end: Int)] = [
        1: (0x0, 0x0), 2: (0x0, 0x0), 3: (0x0, 0x0), 4: (0x0, 0x0), 5: (0x60, 0x6B),
    ]

    /// ecu_control_module_identifier = ControlModuleIdentifier(0x7E8, 0x7E0) -
    /// same for both Simos18.1 and Simos18.10, standard OBD-II physical addressing.
    static let rxid: UInt16 = 0x7E8
    static let txid: UInt16 = 0x7E0

    /// Offset within each block's data where its CRC32 security header lives.
    /// CBOOT_TEMP (block 6) is a second header inside CBOOT (block 1)'s data.
    static let checksumBlockLocation: [Int: Int] = [
        1: 0x300, // CBOOT
        2: 0x300, // ASW1
        3: 0x0,   // ASW2
        4: 0x0,   // ASW3
        5: 0x300, // CAL
        6: 0x340, // CBOOT_TEMP
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
        1: 0x8001C000, // CBOOT
        2: 0x80040000, // ASW1
        3: 0x80140000, // ASW2
        4: 0x80880000, // ASW3
        5: 0xA0800000, // CAL
        6: 0x80840000, // CBOOT_temp
    ]

    /// Offsets within a single flat combined .bin file where each block starts.
    static let binfileOffsets: [Int: Int] = [
        0: 0x0,      // SBOOT
        1: 0x1C000,  // CBOOT
        2: 0x40000,  // ASW1
        3: 0x140000, // ASW2
        4: 0x280000, // ASW3
        5: 0x200000, // CAL
    ]

    static let binfileSize = 4194304

    /// Embedded software-version prefix used to validate a bin actually matches this ECU family.
    static let projectName = "SC8"

    static let blockLengths: [Int: Int] = [
        1: 0x23E00, // CBOOT
        2: 0xFFC00, // ASW1
        3: 0xBFC00, // ASW2
        4: 0x7FC00, // ASW3
        5: 0x7FC00, // CAL
        6: 0x23E00, // CBOOT_temp
    ]

    /// Max ISO-TP TransferData chunk size, same for every block on normal (non-patch) Simos flashing.
    static let blockTransferSizes: [Int: Int] = [1: 0xFFD, 2: 0xFFD, 3: 0xFFD, 4: 0xFFD, 5: 0xFFD]

    static let softwareVersionLocation: [Int: (start: Int, end: Int)] = [
        1: (0x437, 0x43F),
        2: (0x627, 0x62F),
        3: (0x203, 0x20B),
        4: (0x203, 0x20B),
        5: (0x23, 0x2B),
    ]

    /// Single-byte block ID used in UDS RequestDownload/RoutineControl payloads.
    /// Coincidentally identical to the block number for Simos.
    static let blockIdentifiers: [Int: UInt8] = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5]

    /// Simos does not use the UDS-level block checksum (routine 0x0202 always
    /// gets 4 zero bytes) - it checksums internally via the embedded CRC32
    /// header instead (see Flash/Crypto/Crc32Simos.swift).
    static let udsBlockChecksum: [UInt8] = [0x00, 0x00, 0x00, 0x00]

    /// The actual per-ECU bytecode program for Sa2SeedKeyVm. Extracted
    /// programmatically from the C# source (not hand-transcribed) - same
    /// verification rigor as Phase 1's lookup tables.
    static let sa2Script: [UInt8] = hexToBytes("6802814A10680493080820094A05872212195482499307122011824A058703112010824A0181494C")

    /// AES-128-CBC key/IV.
    static let aesKey: [UInt8] = hexToBytes("98D31202E48E3854F2CA561545BA6F2F")
    static let aesIv: [UInt8] = hexToBytes("E7861278C508532798BCA4FE451D20D1")

    /// Only the ASW3 (block 4) patch is supported - bespoke to the exact byte
    /// layout of simos18_1_unlock_patch.bin.
    static func blockTransferSizesPatch(blockNumber: Int, address: Int) -> Int {
        precondition(blockNumber == 4, "Only patching Simos18.1's Block 4 / ASW3 using a provided patch is supported at this time.")
        if address < 0x9600 { return 0x100 }
        if address < 0x9800 { return 0x8 }
        if address < 0x7DD00 { return 0x100 }
        if address < 0x7E200 { return 0x8 }
        if address < 0x7F900 { return 0x100 }
        return 0x8
    }

    static let patchInfo = UnlockPatchInfo(
        patchBoxCode: "8V0906259H__0001",
        patchBlockIndex: 4, // ASW3
        patchFilePath: "simos18_1_unlock_patch.bin"
    )
}

/// Shared hex-string decoder used by both module info tables.
func hexToBytes(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    let chars = Array(hex)
    var i = 0
    while i < chars.count {
        let byteStr = String(chars[i]) + String(chars[i + 1])
        bytes.append(UInt8(byteStr, radix: 16)!)
        i += 2
    }
    return bytes
}
