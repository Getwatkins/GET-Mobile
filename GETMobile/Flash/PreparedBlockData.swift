import Foundation

/// Port of Communication/Simos18/BlockPreparer.cs's Ecm3Constants - bundles
/// the ECM3 constants from Simos18ModuleInfo/Simos1810ModuleInfo for passing
/// into BlockPreparer.prepareBlocks.
struct Ecm3Constants {
    var checksumOffset: Int
    var addressesOffset: Int
    var addressesOffsetEarly: Int
    var offsetUncached: Int64
    var offsetCached: Int64
}

/// Port of Communication/Simos18/UnlockPatchInfo.cs.
struct UnlockPatchInfo {
    /// The exact box code (VW part number + software index) that the
    /// supplied FRF's CAL block must match for this patch to be applicable,
    /// e.g. "8V0906259H__0001". Compared against the FRF's actual box code
    /// using only the part before the first run of underscores.
    let patchBoxCode: String

    /// Which block (1=CBOOT, 2=ASW1, 3=ASW2, 4=ASW3, 5=CAL) this patch
    /// binary replaces the content of.
    let patchBlockIndex: Int

    /// Path (filename) to the pre-built patch binary asset.
    let patchFilePath: String
}

/// Port of Communication/Simos18/PreparedBlockData.cs.
struct PreparedBlockData {
    let blockNumber: Int
    let blockEncryptedBytes: [UInt8]
    let boxCode: String
    let compressionType: UInt8
    let encryptionType: UInt8
    let shouldErase: Bool
    let udsChecksum: [UInt8]
    let blockName: String?
}
