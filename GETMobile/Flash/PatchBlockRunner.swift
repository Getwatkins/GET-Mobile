import Foundation

/// Port of Communication/J2534/Uds/PatchBlockRunner.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/flash_uds.py: patch_block().
///
/// This is the actual delivery mechanism for the CBOOT-bypass unlock patch
/// (see Flash/CbootPatcher.swift) and is the single highest-stakes code path
/// in this whole port - it's the step that writes the exploit payload
/// itself. Deliberately kept as its own function, not folded into
/// FlashBlockRunner, because it differs from a normal block flash in
/// several ways that matter:
///
///   - Always erases block 5 (CAL) before writing, regardless of which
///     block is actually being patched. This is not a mistake carried over
///     from FlashBlockRunner - it's what the original does, on purpose (the
///     comment in the Python: "Hardcoded to erase block 5 (CAL) prior to
///     patch. This means we must ALWAYS flash CAL after patching."). Skipping
///     the subsequent CAL flash after running this leaves the ECU with an
///     erased CAL.
///   - Uses compression=0x0 (NOT LZSS-compressed, unlike normal blocks) with
///     encryption=0xA.
///   - Uses a variable, address-dependent transfer chunk size specific to
///     the exact patch binary's byte layout (see
///     Simos18ModuleInfo/Simos1810ModuleInfo.blockTransferSizesPatch).
///   - Retries indefinitely on a negative UDS response for each TransferData
///     chunk, incrementing the counter and waiting 25ms between attempts -
///     there is no retry cap here, matching the Python exactly. This is a
///     real, disclosed risk: a persistent failure here hangs indefinitely
///     rather than surfacing an error. Callers driving a UI should apply
///     their own external cancellation/timeout around this call rather than
///     assume it will always return.
enum PatchBlockRunner {
    private static let eraseMemoryRoutine: UInt16 = 0xFF00
    private static let patchCompressionType: UInt8 = 0x0

    static func patchBlock(
        client: UdsClient,
        block: PreparedBlockData,
        blockLength: Int,
        blockTransferSizesPatch: (_ blockNumber: Int, _ address: Int) -> Int,
        statusCallback: ((_ step: String, _ status: String, _ progress: Int) -> Void)? = nil,
        logDetail: ((String) -> Void)? = nil
    ) async throws {
        let patchTargetBlockNumber = block.blockNumber - 5
        let data = block.blockEncryptedBytes

        logDetail?("Erasing next block for PATCH process - erasing block 5 (CAL) to patch \(patchTargetBlockNumber), routine 0xFF00...")

        // Hardcoded to block 5 (CAL) - see enum doc. NOT patchTargetBlockNumber, on purpose.
        try await client.startRoutine(eraseMemoryRoutine, data: Data([0x1, 5]))

        logDetail?("Requesting download to PATCH block \(patchTargetBlockNumber) of length \(blockLength) ...")

        try await client.requestDownload(blockIdentifier: UInt8(patchTargetBlockNumber), blockLength: UInt32(blockLength),
                                          compressionType: patchCompressionType, encryptionType: block.encryptionType)

        logDetail?("Transferring PATCH data... \(data.count) bytes to write")

        var counter: UInt8 = 1
        var transferAddress = 0
        while transferAddress < data.count {
            let transferSize = blockTransferSizesPatch(patchTargetBlockNumber, transferAddress)
            let blockEnd = min(data.count, transferAddress + transferSize)
            let chunk = Array(data[transferAddress..<blockEnd])

            let progress = Int(100.0 * Double(transferAddress) / Double(data.count))
            statusCallback?("PATCHING", "Patching data... ", progress)

            var success = false
            while !success {
                try? await Task.sleep(nanoseconds: 25_000_000) // 25ms, matching Thread.Sleep(25)
                do {
                    try await client.transferData(sequenceNumber: counter, data: Data(chunk))
                    success = true
                    counter = UdsClient.nextTransferCounter(counter)
                } catch is UdsNegativeResponseException {
                    // Deliberately unbounded retry, matching the Python/C# exactly -
                    // see the enum-level doc comment. Any OTHER error type
                    // (not a negative UDS response - e.g. malformed
                    // response, a genuine transport failure) is NOT caught
                    // here and propagates out, same as the original only
                    // ever catching UdsNegativeResponseException.
                    success = false
                    counter = UdsClient.nextTransferCounter(counter)
                }
            }

            transferAddress += transferSize
        }

        logDetail?("Exiting PATCH transfer...")
        try await client.requestTransferExit()
        logDetail?("PATCH successful.")
    }
}
