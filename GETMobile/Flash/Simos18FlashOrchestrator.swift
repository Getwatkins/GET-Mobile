import Foundation

enum Simos18ModuleType {
    case simos18_1
    case simos18_10
}

struct Simos18FlashOptions {
    let moduleType: Simos18ModuleType

    /// SA2 script bytes for the target module. Leave nil to use the
    /// built-in script for moduleType.
    var sa2Script: [UInt8]? = nil

    /// Raw block bytes extracted from a factory FRF (blocks 1-5) for the
    /// initial unlock flash. Leave nil for a normal post-unlock flash (see
    /// inputBlocksForNormalFlash) where no unlock/patch block is involved.
    var frfBlocksForUnlock: [Int: [UInt8]]? = nil

    /// Raw block bytes (1-5, no patch) for a normal flash on an
    /// already-unlocked ECU. Exactly one of this, frfBlocksForUnlock, or
    /// inputBlocksForCalFlash should be set.
    var inputBlocksForNormalFlash: [Int: [UInt8]]? = nil

    /// Raw block bytes (1-5) for a CAL-only "fast flash" - matches
    /// VW_Flash's flash_cal action. Only block 5 (CAL) actually gets
    /// written; the rest are only used to extract CAL's own embedded box
    /// code for the safety check against the ECU's currently installed box
    /// code (DID 0xF187) before writing anything.
    var inputBlocksForCalFlash: [Int: [UInt8]]? = nil

    var shouldPatchCboot: Bool = false
}

/// Bundles one module's worth of Simos18ModuleInfo/Simos1810ModuleInfo
/// constants together, so the orchestrator can resolve them all in one
/// switch instead of ~15 separate if/else assignments.
private struct ModuleMetadata {
    let blockNamesFrf: [Int: String]
    let checksumBlockLocation: [Int: Int]
    let baseAddresses: [Int: UInt32]
    let boxCodeLocation: [Int: (start: Int, end: Int)]
    let softwareVersionLocation: [Int: (start: Int, end: Int)]
    let blockLengths: [Int: Int]
    let blockTransferSizes: [Int: Int]
    let blockIdentifiers: [Int: UInt8]
    let udsBlockChecksum: [UInt8]
    let aesKey: [UInt8]
    let aesIv: [UInt8]
    let ecm3: Ecm3Constants
    let patchInfo: UnlockPatchInfo
    let rxID: UInt16
    let txID: UInt16
    let calBoxCodeLocation: (start: Int, end: Int)
    let sa2Script: [UInt8]
    let blockTransferSizesPatch: (Int, Int) -> Int

    static func forModule(_ type: Simos18ModuleType) -> ModuleMetadata {
        switch type {
        case .simos18_1:
            return ModuleMetadata(
                blockNamesFrf: Simos18ModuleInfo.blockNamesFrf,
                checksumBlockLocation: Simos18ModuleInfo.checksumBlockLocation,
                baseAddresses: Simos18ModuleInfo.baseAddresses,
                boxCodeLocation: Simos18ModuleInfo.boxCodeLocation,
                softwareVersionLocation: Simos18ModuleInfo.softwareVersionLocation,
                blockLengths: Simos18ModuleInfo.blockLengths,
                blockTransferSizes: Simos18ModuleInfo.blockTransferSizes,
                blockIdentifiers: Simos18ModuleInfo.blockIdentifiers,
                udsBlockChecksum: Simos18ModuleInfo.udsBlockChecksum,
                aesKey: Simos18ModuleInfo.aesKey,
                aesIv: Simos18ModuleInfo.aesIv,
                ecm3: Simos18ModuleInfo.ecm3,
                patchInfo: Simos18ModuleInfo.patchInfo,
                rxID: Simos18ModuleInfo.rxid,
                txID: Simos18ModuleInfo.txid,
                calBoxCodeLocation: Simos18ModuleInfo.calBoxCodeLocation,
                sa2Script: Simos18ModuleInfo.sa2Script,
                blockTransferSizesPatch: Simos18ModuleInfo.blockTransferSizesPatch)
        case .simos18_10:
            return ModuleMetadata(
                blockNamesFrf: Simos1810ModuleInfo.blockNamesFrf,
                checksumBlockLocation: Simos1810ModuleInfo.checksumBlockLocation,
                baseAddresses: Simos1810ModuleInfo.baseAddresses,
                boxCodeLocation: Simos1810ModuleInfo.boxCodeLocation,
                softwareVersionLocation: Simos1810ModuleInfo.softwareVersionLocation,
                blockLengths: Simos1810ModuleInfo.blockLengths,
                blockTransferSizes: Simos1810ModuleInfo.blockTransferSizes,
                blockIdentifiers: Simos1810ModuleInfo.blockIdentifiers,
                udsBlockChecksum: Simos1810ModuleInfo.udsBlockChecksum,
                aesKey: Simos1810ModuleInfo.aesKey,
                aesIv: Simos1810ModuleInfo.aesIv,
                ecm3: Simos1810ModuleInfo.ecm3,
                patchInfo: Simos1810ModuleInfo.patchInfo,
                rxID: Simos1810ModuleInfo.rxid,
                txID: Simos1810ModuleInfo.txid,
                calBoxCodeLocation: Simos1810ModuleInfo.calBoxCodeLocation,
                sa2Script: Simos1810ModuleInfo.sa2Script,
                blockTransferSizesPatch: Simos1810ModuleInfo.blockTransferSizesPatch)
        }
    }
}

/// Port of Communication/Simos18/Simos18FlashOrchestrator.cs. Ties together
/// every earlier phase - module metadata, the unlock sequence, block
/// preparation, and the flash/patch loops - into the single entry point a
/// UI calls. Ported from flash_uds.py's flash_blocks(), specifically the
/// portion after setup (block loop through final reset) - the setup/unlock
/// portion itself lives in UnlockSequence.
///
/// One simplification vs. the C#: there's no separate "close this J2534
/// connection, open a new one" dance around the final clear-DTCs step,
/// since a UdsTransport here is a persistent object that can send on any
/// rxID/txID pair without needing to be reconstructed - the actual UDS
/// behavior (what bytes go out, in what order) is unchanged.
enum Simos18FlashOrchestrator {
    private static let checkProgrammingDependenciesRoutine: UInt16 = 0xFF01

    enum FlashError: Error, LocalizedError {
        case noInputBlocksProvided
        case couldNotBuildUnlockSequence(String)
        case missingCalBlockForCalFlash
        case boxCodeMismatch(ecu: String, file: String)
        case missingPreparedBlock(Int)

        var errorDescription: String? {
            switch self {
            case .noInputBlocksProvided:
                return "One of frfBlocksForUnlock, inputBlocksForNormalFlash, or inputBlocksForCalFlash must be set."
            case .couldNotBuildUnlockSequence(let detail):
                return "Could not build unlock sequence: \(detail)"
            case .missingCalBlockForCalFlash:
                return "Input file is missing block 5 (CAL) - cannot do a CAL flash."
            case .boxCodeMismatch(let ecu, let file):
                return "Attempting to flash a file that doesn't match box codes - refusing. " +
                    "ECU is \"\(ecu)\" but file CAL block is \"\(file)\". " +
                    "This safety check exists to stop a CAL meant for a different ECU/hardware from being written."
            case .missingPreparedBlock(let n):
                return "Block \(n) was not successfully prepared (see log) - aborting rather than flashing a partial set."
            }
        }
    }

    static func runFlash(
        transport: UdsTransport,
        options: Simos18FlashOptions,
        statusCallback: ((_ step: String, _ status: String, _ progress: Int) -> Void)? = nil,
        logDetail: ((String) -> Void)? = nil
    ) async throws {
        let meta = ModuleMetadata.forModule(options.moduleType)
        let sa2Script = (options.sa2Script?.isEmpty == false) ? options.sa2Script! : meta.sa2Script

        let isUnlockFlash = options.frfBlocksForUnlock != nil
        let isCalFlash = options.inputBlocksForCalFlash != nil
        let rawInputBlocks = isUnlockFlash ? options.frfBlocksForUnlock
            : (isCalFlash ? options.inputBlocksForCalFlash : options.inputBlocksForNormalFlash)

        guard let rawInputBlocks else { throw FlashError.noInputBlocksProvided }

        var blocksToPrepare: [Int: [UInt8]]
        var flashOrder: [Int]

        if isUnlockFlash {
            let calBoxCodeLoc = meta.boxCodeLocation[5] ?? (start: 0, end: 0)

            let result = UnlockOrchestrator.buildUnlockSequence(
                extractedFrfBlocks: rawInputBlocks,
                blockNamesFrf: meta.blockNamesFrf,
                calBoxCodeLocation: calBoxCodeLoc,
                patchInfo: meta.patchInfo,
                readPatchFileBytes: { fileName in
                    let path = try Simos18ResourcePaths.unlockPatchPath(fileName)
                    return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
                })

            guard let orderedBlocks = result.blocks else {
                throw FlashError.couldNotBuildUnlockSequence(result.errorMessage ?? "unknown error")
            }

            var dict: [Int: [UInt8]] = [:]
            flashOrder = []
            for b in orderedBlocks {
                dict[b.blockNumber] = b.blockBytes
                flashOrder.append(b.blockNumber)
            }
            blocksToPrepare = dict
        } else if isCalFlash {
            // Mirrors flash_cal's filtering: only CAL (block 5) actually
            // gets flashed. The rest of rawInputBlocks (if present) isn't
            // used further - the box-code safety check below reads CAL's
            // own embedded box code, not anything from the other blocks.
            guard let calBytes = rawInputBlocks[5] else { throw FlashError.missingCalBlockForCalFlash }
            blocksToPrepare = [5: calBytes]
            flashOrder = [5]
        } else {
            blocksToPrepare = rawInputBlocks
            flashOrder = [1, 2, 3, 4, 5]
        }

        let preparedBlocks = BlockPreparer.prepareBlocks(
            blockNamesFrf: meta.blockNamesFrf,
            checksumBlockLocation: meta.checksumBlockLocation,
            baseAddresses: meta.baseAddresses,
            boxCodeLocation: meta.boxCodeLocation,
            softwareVersionLocation: meta.softwareVersionLocation,
            ecm3: meta.ecm3,
            boxCodesCsvPath: try Simos18ResourcePaths.boxCodesCsvPath(),
            aesKey: meta.aesKey,
            aesIv: meta.aesIv,
            udsBlockChecksum: meta.udsBlockChecksum,
            inputBlocks: blocksToPrepare,
            shouldPatchCboot: options.shouldPatchCboot,
            logDetail: logDetail)

        let unlockOptions = UnlockSequenceOptions(sa2Script: sa2Script, rxID: meta.rxID, txID: meta.txID)
        let unlockResult = try await UnlockSequence.run(transport: transport, options: unlockOptions, logDetail: logDetail, statusCallback: statusCallback)
        let client = unlockResult.client

        if isCalFlash {
            let sparePartNumberDid: UInt16 = 0xF187

            statusCallback?("SETUP", "Verifying box code matches ECU...", 100)
            let ecuBoxCode = try await client.readDataByIdentifierAsAscii(sparePartNumberDid)
                .trimmingCharacters(in: .whitespaces)
            let fileBoxCode = (preparedBlocks[5]?.boxCode ?? "").trimmingCharacters(in: .whitespaces)

            logDetail?("ECU box code: \"\(ecuBoxCode)\" | File CAL box code: \"\(fileBoxCode)\"")

            guard ecuBoxCode == fileBoxCode else {
                throw FlashError.boxCodeMismatch(ecu: ecuBoxCode, file: fileBoxCode)
            }
            logDetail?("File matches ECU box code.")
        }

        for blockNumber in flashOrder {
            guard let block = preparedBlocks[blockNumber] else { throw FlashError.missingPreparedBlock(blockNumber) }

            if blockNumber <= 5 {
                try await FlashBlockRunner.flashBlock(
                    client: client, block: block, blockIdentifiers: meta.blockIdentifiers,
                    blockLengths: meta.blockLengths, blockTransferSizes: meta.blockTransferSizes,
                    statusCallback: statusCallback, logDetail: logDetail)
            } else {
                let patchTargetBlockNumber = blockNumber - 5
                let patchBlockLength = meta.blockLengths[patchTargetBlockNumber] ?? 0
                try await PatchBlockRunner.patchBlock(
                    client: client, block: block, blockLength: patchBlockLength,
                    blockTransferSizesPatch: meta.blockTransferSizesPatch,
                    statusCallback: statusCallback, logDetail: logDetail)
            }
        }

        statusCallback?("SETUP", "Verifying reprogramming dependencies...", 100)
        logDetail?("Verifying programming dependencies, routine 0xFF01...")
        try await client.startRoutine(checkProgrammingDependenciesRoutine)

        try await client.testerPresent()

        // "If a periodic task was patched or altered as part of the process,
        // let's give it a few seconds to run" - matches the Python's
        // time.sleep(5) exactly.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        statusCallback?("SETUP", "Finalizing...", 100)
        logDetail?("Rebooting ECU...")
        try await client.ecuReset(.hardReset)

        logDetail?("Sending 0x4 Clear Emissions DTCs over OBD-2")
        _ = try await transport.sendRequest(rxID: 0x7E8, txID: 0x700, payload: Data([0x04]), timeoutSeconds: 5)

        statusCallback?("SETUP", "DONE!...", 100)
        logDetail?("Done!")
    }
}
