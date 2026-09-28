import Foundation

enum DsgModuleType {
    case dq250
    case dq381

    var displayName: String {
        switch self {
        case .dq250: return "DQ250-MQB (Temic)"
        case .dq381: return "DQ381-MQB (Bosch)"
        }
    }
}

struct DsgFlashOptions {
    let moduleType: DsgModuleType
    /// The user's combined "F"-project .bin. Sliced per the module's own
    /// offset table (Dq250ModuleInfo / Dq381ModuleInfo) - only the blocks
    /// this orchestrator actually writes are ever read out of it.
    let binFileBytes: [UInt8]
}

/// DSG/TCM CAL flash. Same UDS sequence as Simos18FlashOrchestrator's
/// CAL-only path (VW_Flash's flash_blocks() is one generic function for all
/// module families - only block PREPARATION differs, see DsgBlockPreparer),
/// with three deliberate differences:
///   * No unlock/CBOOT-patch logic at all - DSG doesn't use one.
///   * Standard 20ms frame-pacing floor throughout (useFastPacing: false).
///   * VIN / active-session preflight reads are non-fatal (see
///     UnlockSequenceOptions.strictPreflightReads).
/// Scope: DQ250 = Driver (block 2, required flash-loader) + CAL (block 4).
/// DQ381 = CAL (block 3) only. ASW/bootloader are never written.
enum DsgFlashOrchestrator {
    private static let checkProgrammingDependenciesRoutine: UInt16 = 0xFF01

    enum FlashError: Error, LocalizedError {
        case missingBlock(name: String, expectedOffset: Int, fileSize: Int)
        case unsupportedModule

        var errorDescription: String? {
            switch self {
            case .missingBlock(let name, let offset, let size):
                return "The \(name) block could not be read from this file (expected at offset 0x\(String(offset, radix: 16, uppercase: true)), file is \(size) bytes, or its project ID didn't match). Refusing to flash - this usually means the wrong file or a truncated one."
            case .unsupportedModule:
                return "Unsupported TCM type."
            }
        }
    }

    static func runFlash(
        transport: UdsTransport,
        options: DsgFlashOptions,
        statusCallback: ((_ step: String, _ status: String, _ progress: Int) -> Void)? = nil,
        logDetail: ((String) -> Void)? = nil
    ) async throws {
        logDetail?("TCM flash: \(options.moduleType.displayName), CAL-only scope.")

        let prepared: [PreparedBlockData]
        let blockIdentifiers: [Int: UInt8]
        let blockLengths: [Int: Int]
        let blockTransferSizes: [Int: Int]
        let sa2Script: [UInt8]
        let rxID: UInt16
        let txID: UInt16

        switch options.moduleType {
        case .dq250:
            let sliced = try slice(options.binFileBytes, offsets: Dq250ModuleInfo.binfileOffsets,
                                   lengths: Dq250ModuleInfo.blockLengths,
                                   versionLoc: Dq250ModuleInfo.softwareVersionLocation,
                                   project: Dq250ModuleInfo.projectName,
                                   expectedSize: Dq250ModuleInfo.binfileSize,
                                   names: [2: "Driver", 4: "CAL"], logDetail: logDetail)
            // Driver first - it's the flash loader the CAL write depends on.
            prepared = [
                DsgBlockPreparer.prepareDq250Block(blockNumber: Dq250ModuleInfo.driverBlockNumber,
                                                   rawBytes: sliced[Dq250ModuleInfo.driverBlockNumber]!, logDetail: logDetail),
                DsgBlockPreparer.prepareDq250Block(blockNumber: Dq250ModuleInfo.calBlockNumber,
                                                   rawBytes: sliced[Dq250ModuleInfo.calBlockNumber]!, logDetail: logDetail),
            ]
            blockIdentifiers = Dq250ModuleInfo.blockIdentifiers
            blockLengths = Dq250ModuleInfo.blockLengths
            blockTransferSizes = Dq250ModuleInfo.blockTransferSizes
            sa2Script = Dq250ModuleInfo.sa2Script
            rxID = Dq250ModuleInfo.rxid; txID = Dq250ModuleInfo.txid

        case .dq381:
            let sliced = try slice(options.binFileBytes, offsets: Dq381ModuleInfo.binfileOffsets,
                                   lengths: Dq381ModuleInfo.blockLengths,
                                   versionLoc: Dq381ModuleInfo.softwareVersionLocation,
                                   project: Dq381ModuleInfo.projectName,
                                   expectedSize: Dq381ModuleInfo.binfileSize,
                                   names: [3: "CAL"], logDetail: logDetail)
            prepared = [
                try DsgBlockPreparer.prepareDq381CalBlock(rawBytes: sliced[Dq381ModuleInfo.calBlockNumber]!, logDetail: logDetail),
            ]
            blockIdentifiers = Dq381ModuleInfo.blockIdentifiers
            blockLengths = Dq381ModuleInfo.blockLengths
            blockTransferSizes = Dq381ModuleInfo.blockTransferSizes
            sa2Script = Dq381ModuleInfo.sa2Script
            rxID = Dq381ModuleInfo.rxid; txID = Dq381ModuleInfo.txid
        }

        // Everything above is pure computation - nothing has touched the
        // module yet. From here on, the module is being talked to.
        var unlockOptions = UnlockSequenceOptions(sa2Script: sa2Script, rxID: rxID, txID: txID)
        unlockOptions.strictPreflightReads = false
        let unlockResult = try await UnlockSequence.run(transport: transport, options: unlockOptions,
                                                        logDetail: logDetail, statusCallback: statusCallback)
        let client = unlockResult.client

        // Informational only - VW_Flash has no box-code check for DSG, and I
        // can't confirm the TCM's F187 uses the same format as the CAL
        // block's embedded string, so a mismatch is reported loudly but does
        // not block the flash the way the ECM path does.
        if let calBlock = prepared.last, calBlock.boxCode != "-" {
            let ecuBoxRaw: String? = try? await client.readDataByIdentifierAsAscii(0xF187)
            let fileBox = calBlock.boxCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ecuBoxRaw {
                let ecuBox = ecuBoxRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                logDetail?("TCM reports part number '\(ecuBox)' | file CAL box code '\(fileBox)' - compare these yourself.")
            } else {
                logDetail?("Could not read TCM part number (0xF187) for comparison - continuing.")
            }
        }

        for block in prepared {
            try await FlashBlockRunner.flashBlock(
                client: client, block: block, blockIdentifiers: blockIdentifiers,
                blockLengths: blockLengths, blockTransferSizes: blockTransferSizes,
                useFastPacing: false,
                statusCallback: statusCallback, logDetail: logDetail)
        }

        statusCallback?("SETUP", "Verifying reprogramming dependencies...", 100)
        logDetail?("Verifying programming dependencies, routine 0xFF01...")
        try await client.startRoutine(checkProgrammingDependenciesRoutine)
        try await client.testerPresent()
        try await Task.sleep(nanoseconds: 5_000_000_000)

        statusCallback?("SETUP", "Finalizing...", 100)
        logDetail?("Rebooting TCM...")
        // Same best-effort tail as the ECM path (and VW_Flash's try/finally):
        // everything that writes/verifies has already succeeded by here.
        do {
            try await client.ecuReset(.hardReset)
            logDetail?("Sending 0x4 Clear Emissions DTCs over OBD-2")
            _ = try await transport.sendRequest(rxID: 0x7E8, txID: 0x700, payload: Data([0x04]), timeoutSeconds: 5)
        } catch {
            logDetail?("Reset/clear-DTCs step reported an error (\(error.localizedDescription)) - expected sometimes while the module reboots. "
                + "The flash write and checksums above already succeeded, so this on its own is NOT a flash failure.")
        }

        statusCallback?("SETUP", "DONE!...", 100)
        logDetail?("Done!")
    }

    /// For the UI: reports, without touching any hardware, whether this file
    /// holds the blocks a flash of `moduleType` needs.
    static func checkFile(moduleType: DsgModuleType, bytes: [UInt8]) -> (ready: Bool, warnings: [String], summary: String) {
        var warnings: [String] = []
        let collect: (String) -> Void = { warnings.append($0) }
        do {
            switch moduleType {
            case .dq250:
                _ = try slice(bytes, offsets: Dq250ModuleInfo.binfileOffsets, lengths: Dq250ModuleInfo.blockLengths,
                              versionLoc: Dq250ModuleInfo.softwareVersionLocation, project: Dq250ModuleInfo.projectName,
                              expectedSize: Dq250ModuleInfo.binfileSize, names: [2: "Driver", 4: "CAL"], logDetail: collect)
                return (true, warnings, "Driver and CAL blocks recognized")
            case .dq381:
                _ = try slice(bytes, offsets: Dq381ModuleInfo.binfileOffsets, lengths: Dq381ModuleInfo.blockLengths,
                              versionLoc: Dq381ModuleInfo.softwareVersionLocation, project: Dq381ModuleInfo.projectName,
                              expectedSize: Dq381ModuleInfo.binfileSize, names: [3: "CAL"], logDetail: collect)
                return (true, warnings, "CAL block recognized")
            }
        } catch {
            warnings.append(error.localizedDescription)
            return (false, warnings, "")
        }
    }

    /// Slices the needed blocks out of the combined bin using the SAME
    /// BinFileHandler the ECM path uses (offset table + project-ID
    /// wrong-file filter). Any needed block missing/discarded aborts before
    /// the module is touched.
    private static func slice(
        _ data: [UInt8], offsets: [Int: Int], lengths: [Int: Int],
        versionLoc: [Int: (start: Int, end: Int)], project: String, expectedSize: Int,
        names: [Int: String], logDetail: ((String) -> Void)?
    ) throws -> [Int: [UInt8]] {
        if data.count != expectedSize {
            logDetail?("Warning: file is \(data.count) bytes; a full image for this TCM is normally \(expectedSize).")
        }
        let result = BinFileHandler.blocksFromData(
            data, binfileOffsets: offsets, blockLengths: lengths,
            softwareVersionLocation: versionLoc, projectName: project,
            blockNumbers: Array(names.keys).sorted())
        for w in result.warnings { logDetail?(w) }
        for (number, name) in names {
            guard result.blocks[number] != nil else {
                throw FlashError.missingBlock(name: name, expectedOffset: offsets[number] ?? 0, fileSize: data.count)
            }
        }
        return result.blocks
    }
}
