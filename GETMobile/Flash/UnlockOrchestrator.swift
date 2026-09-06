import Foundation

enum UnlockSequenceError {
    case none
    case missingBlock
    case boxCodeMismatch
}

/// Port of Communication/Simos18/UnlockOrchestrator.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) - the block-ordering and box-code-
/// validation logic in the "flash_unlock" action of VW_Flash.py.
///
/// This does NOT perform any UDS communication or block encryption/
/// checksumming - it only decides, from the 5 blocks extracted out of a
/// factory FRF, what the final ordered list of blocks to write is,
/// including inserting the pre-built unlock patch binary at the correct
/// position. That ordered list is what FlashOrchestrator actually writes to
/// the ECU, in order.
enum UnlockOrchestrator {
    struct Result {
        let blocks: [BlockData]?
        let error: UnlockSequenceError
        let errorMessage: String?
    }

    /// - Parameters:
    ///   - extractedFrfBlocks: The 5 blocks (keyed 1-5: CBOOT, ASW1, ASW2, ASW3, CAL) already extracted from the factory FRF.
    ///   - blockNamesFrf: Simos18ModuleInfo/Simos1810ModuleInfo.blockNamesFrf
    ///   - calBoxCodeLocation: Simos18ModuleInfo/Simos1810ModuleInfo.calBoxCodeLocation
    ///   - patchInfo: Simos18ModuleInfo/Simos1810ModuleInfo.patchInfo
    ///   - readPatchFileBytes: Injected file-read function so this stays testable without touching disk.
    static func buildUnlockSequence(
        extractedFrfBlocks: [Int: [UInt8]],
        blockNamesFrf: [Int: String],
        calBoxCodeLocation: (start: Int, end: Int),
        patchInfo: UnlockPatchInfo,
        readPatchFileBytes: (String) throws -> [UInt8]
    ) -> Result {
        for i in 1...5 {
            if extractedFrfBlocks[i] == nil {
                return Result(blocks: nil, error: .missingBlock, errorMessage: "Missing block \(i) in extracted FRF data.")
            }
        }

        let calBlockBytes = extractedFrfBlocks[5]!

        // Python slicing is [start:end) with end clamped to the buffer
        // length, not an exception on overrun - clamped explicitly here too.
        let start = calBoxCodeLocation.start
        let end = min(calBoxCodeLocation.end, calBlockBytes.count)
        let length = max(0, end - start)
        let fileBoxCode = length > 0 ? String(decoding: calBlockBytes[start..<(start + length)], as: UTF8.self) : ""

        let expectedBoxCode = patchInfo.patchBoxCode.split(separator: "_", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)

        if fileBoxCode.trimmingCharacters(in: .whitespaces) != expectedBoxCode {
            let message = "Boxcode mismatch for unlocking. Got box code \(fileBoxCode) but expected " +
                "\(patchInfo.patchBoxCode). Please don't try to be clever. Supply the correct " +
                "file and the process will work."
            return Result(blocks: nil, error: .boxCodeMismatch, errorMessage: message)
        }

        let patchBytes: [UInt8]
        do {
            patchBytes = try readPatchFileBytes(patchInfo.patchFilePath)
        } catch {
            return Result(blocks: nil, error: .missingBlock, errorMessage: "Could not read unlock patch file: \(error.localizedDescription)")
        }

        let unlockPatchBlock = BlockData(blockNumber: patchInfo.patchBlockIndex + 5, blockBytes: patchBytes, blockName: "UNLOCK_PATCH")

        // key_order = [1,2,3,4,5]; key_order.insert(4, "UNLOCK_PATCH")
        // -> effective block order: [1, 2, 3, 4, UNLOCK_PATCH, 5]
        let orderedBlocks: [BlockData] = [
            BlockData(blockNumber: 1, blockBytes: extractedFrfBlocks[1]!, blockName: blockNamesFrf[1]),
            BlockData(blockNumber: 2, blockBytes: extractedFrfBlocks[2]!, blockName: blockNamesFrf[2]),
            BlockData(blockNumber: 3, blockBytes: extractedFrfBlocks[3]!, blockName: blockNamesFrf[3]),
            BlockData(blockNumber: 4, blockBytes: extractedFrfBlocks[4]!, blockName: blockNamesFrf[4]),
            unlockPatchBlock,
            BlockData(blockNumber: 5, blockBytes: extractedFrfBlocks[5]!, blockName: blockNamesFrf[5]),
        ]

        return Result(blocks: orderedBlocks, error: .none, errorMessage: nil)
    }
}
