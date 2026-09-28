import Foundation

/// Port of VW_Flash's lib/modules/dq250mqb.py (bri3d, BSD-2-Clause) - the
/// Temic DQ250-MQB DSG. Values transcribed directly from that file; not
/// independently re-derived.
///
/// Scope actually implemented here: DRIVER (block 2) + CAL (block 4) only.
/// The Driver is not optional - VW_Flash's own docs describe it as a small
/// flash-loader routine uploaded to the TCM's scratchpad RAM, required
/// infrastructure for writing any other block, not an alternative to CAL.
/// ASW (block 3, ~1.2MB) is deliberately NOT wired up - matches "CAL only"
/// in the sense that actually matters (the application software itself
/// isn't touched), and keeps this to the same narrower, better-understood
/// scope as everything else this app flashes.
enum Dq250ModuleInfo {
    static let rxid: UInt16 = 0x7E9
    static let txid: UInt16 = 0x7E1

    static let driverBlockNumber = 2
    static let calBlockNumber = 4

    static let blockNamesFrf: [Int: String] = [2: "FD_2", 4: "FD_4"]

    /// UDS block-identifier bytes used in RequestDownload / RoutineControl
    /// payloads - NOT the same as the block numbers (unlike Simos18, where
    /// they coincide). Getting this wrong would point a write at the wrong
    /// memory region, so these are transcribed verbatim, not inferred.
    static let blockIdentifiers: [Int: UInt8] = [2: 0x30, 4: 0x51]

    static let blockLengths: [Int: Int] = [
        2: 0x80E,    // DRIVER
        4: 0x20000,  // CAL
    ]

    static let blockTransferSizes: [Int: Int] = [2: 0x4B0, 4: 0x800]

    static let boxCodeLocation: [Int: (start: Int, end: Int)] = [
        2: (0x0, 0x0),
        4: (0x1FFC0, 0x1FFD3),
    ]

    /// The Driver's checksum is a fixed, known-good value for the one
    /// unchanging Driver binary VW_Flash ships - not computed from
    /// whatever bytes happen to be supplied, the same way Simos18's blocks
    /// are. CAL's checksum is always 0xFFFFFFFF: DSG blocks other than the
    /// Driver are validated by their own embedded JAMCRC instead of the
    /// external UDS routine (see DsgChecksum + DsgBlockPreparer).
    static let blockChecksums: [Int: [UInt8]] = [
        2: hexToBytes("F974176E"),
        4: hexToBytes("FFFFFFFF"),
    ]

    static let sa2Script: [UInt8] = hexToBytes("68028149680593A55A55AA4A0587810595268249845AA5AA558703F780384C")

    /// Where each block lives inside the combined "F"-project bin file
    /// (dsg_binfile_offsets / dsg_binfile_size / dsg_project_name).
    static let binfileOffsets: [Int: Int] = [2: 0x0, 4: 0x30000]
    static let binfileSize = 1572864
    static let projectName = "F"

    /// Used by BinFileHandler's wrong-file check: CAL's own embedded project
    /// ID must start with projectName. Driver has none (0,0) - kept as-is.
    static let softwareVersionLocation: [Int: (start: Int, end: Int)] = [
        2: (0x0, 0x0),
        4: (0x1FFE0, 0x1FFE4),
    ]
}
