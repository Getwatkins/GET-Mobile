import Foundation

/// Port of Communication/Simos18/BlockData.cs. Represents one flashable
/// block: its UDS block number, raw bytes, and (for FRF-extracted blocks) a
/// display name.
struct BlockData {
    let blockNumber: Int
    let blockBytes: [UInt8]
    let blockName: String?

    init(blockNumber: Int, blockBytes: [UInt8], blockName: String? = nil) {
        self.blockNumber = blockNumber
        self.blockBytes = blockBytes
        self.blockName = blockName
    }
}
