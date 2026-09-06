import Foundation

/// Port of Communication/J2534/Uds/FlashBlockRunner.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/flash_uds.py: flash_block(). Flashes
/// one prepared block: erase, RequestDownload, chunked TransferData loop,
/// RequestTransferExit, tester present, then the checksum routine (0x0202)
/// using the block's UDS checksum (always 4 zero bytes for Simos - see
/// Simos18ModuleInfo.udsBlockChecksum).
enum FlashBlockRunner {
    private static let eraseMemoryRoutine: UInt16 = 0xFF00
    private static let checksumRoutine: UInt16 = 0x0202

    static func flashBlock(
        client: UdsClient,
        block: PreparedBlockData,
        blockIdentifiers: [Int: UInt8],
        blockLengths: [Int: Int],
        blockTransferSizes: [Int: Int],
        statusCallback: ((_ step: String, _ status: String, _ progress: Int) -> Void)? = nil,
        logDetail: ((String) -> Void)? = nil
    ) async throws {
        let blockNumber = block.blockNumber
        let data = block.blockEncryptedBytes
        guard let blockIdentifier = blockIdentifiers[blockNumber] else {
            throw FlashError.unknownBlock(blockNumber)
        }

        logDetail?("Beginning block flashing process for block \(blockNumber) : \(block.blockName ?? "?") ...")

        if block.shouldErase {
            statusCallback?("FLASHING", "Erasing block \(blockNumber)", 0)
            logDetail?("Erasing block \(blockNumber), routine 0xFF00...")
            try await client.startRoutine(eraseMemoryRoutine, data: Data([0x1, blockIdentifier]))
        }

        statusCallback?("FLASHING", "Requesting Download for block \(blockNumber)", 0)
        let blockLength = blockLengths[blockNumber] ?? 0
        logDetail?("Requesting download for block \(blockNumber) of length \(blockLength) with block identifier: \(blockIdentifier)")

        try await client.requestDownload(blockIdentifier: blockIdentifier, blockLength: UInt32(blockLength),
                                          compressionType: block.compressionType, encryptionType: block.encryptionType)

        statusCallback?("FLASHING", "Transferring data... \(data.count)", 0)
        logDetail?("Transferring data... \(data.count) bytes to write")

        var counter: UInt8 = 1
        let transferSize = blockTransferSizes[blockNumber] ?? 0xFFD
        var baseAddress = 0
        while baseAddress < data.count {
            let end = min(data.count, baseAddress + transferSize)
            let progress = Int((100.0 * Double(end) / Double(data.count) * 10).rounded() / 10)
            statusCallback?("FLASHING", "Transferring data... ", progress)

            let chunk = data.subdata(in: data.startIndex.advanced(by: baseAddress)..<data.startIndex.advanced(by: end))
            try await client.transferData(sequenceNumber: counter, data: chunk)
            counter = UdsClient.nextTransferCounter(counter)

            baseAddress += transferSize
        }

        statusCallback?("FLASHING", "Exiting transfer... ", 100)
        logDetail?("Exiting transfer...")
        try await client.requestTransferExit()

        // NOTE: the tuner-tag magic-payload override on tester_present (for
        // tuned-CBOOT CAL-validity force-overwrite) from the Python original
        // is intentionally not ported - it's an advanced/optional feature
        // layered on top of the base flashing flow, not part of the core
        // sequence needed to get a block written.
        try await client.testerPresent()

        statusCallback?("FLASHING", "Checksumming block... ", 100)
        logDetail?("Checksumming block \(blockNumber), routine 0x0202...")

        var checksumData = Data([0x01, blockIdentifier, 0, 0x4])
        checksumData.append(contentsOf: block.udsChecksum)
        try await client.startRoutine(checksumRoutine, data: checksumData)

        statusCallback?("FLASHING", "Success flashing block... ", 100)
        logDetail?("Successfully flashed block \(blockNumber).")
    }

    enum FlashError: Error, LocalizedError {
        case unknownBlock(Int)
        var errorDescription: String? {
            switch self {
            case .unknownBlock(let n): return "No block identifier configured for block \(n)."
            }
        }
    }
}
