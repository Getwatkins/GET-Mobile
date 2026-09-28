import Foundation

/// DSG-family block preparation. Two genuinely different pipelines - kept
/// as two separate functions rather than forced into one generic shape,
/// mirroring VW_Flash's own choice to keep dsg_flash_utils.py and
/// dq381_flash_utils.py as separate modules rather than one shared one.
/// Only the outer UDS mechanics (FlashBlockRunner, UnlockSequence) are
/// actually shared between module families.
enum DsgBlockPreparer {
    enum PrepError: Error, LocalizedError {
        case invalidChecksumRange
        var errorDescription: String? {
            switch self {
            case .invalidChecksumRange:
                return "This CAL's embedded checksum-range pointers don't make sense for a DQ381 CAL block - it's most likely the wrong file or corrupt. Refusing to flash."
            }
        }
    }


    // MARK: DQ250 (lib/dsg_flash_utils.py: checksum_blocks + prepare_blocks)

    /// - Parameters:
    ///   - blockNumber: Dq250ModuleInfo.driverBlockNumber or .calBlockNumber.
    ///   - rawBytes: unmodified bytes for this block, already sliced out of
    ///     the user's combined "F"-project bin file at Dq250ModuleInfo's
    ///     offset for this block (slicing itself happens at the call site,
    ///     not here).
    static func prepareDq250Block(blockNumber: Int, rawBytes: [UInt8], logDetail: ((String) -> Void)?) -> PreparedBlockData {
        // The Driver's checksum is external/fixed (see Dq250ModuleInfo's doc
        // comment) - its own bytes are never modified here, matching
        // checksum_blocks()'s `if blocknum != 2` branch exactly.
        let checksummed: [UInt8]
        if blockNumber == Dq250ModuleInfo.driverBlockNumber {
            checksummed = rawBytes
        } else {
            checksummed = DsgChecksum.fixJamCrc(rawBytes)
            logDetail?("DQ250 block \(blockNumber): JAMCRC checksum fixed.")
        }

        var boxCode = "-"
        if let loc = Dq250ModuleInfo.boxCodeLocation[blockNumber] {
            let length = loc.end - loc.start
            if length > 0, loc.start + length <= checksummed.count {
                boxCode = String(decoding: checksummed[loc.start..<(loc.start + length)], as: UTF8.self)
            }
        }

        logDetail?("DQ250 block \(blockNumber): compressing (LZSS, no padding), input size \(checksummed.count)")
        // dsg_flash_utils.py: lzss.lzss_compress(binary_data, skip_padding=True)
        let compressed = LzssCompressor.compress(checksummed, dontPad: true)

        logDetail?("DQ250 block \(blockNumber): encrypting (DSG cipher), compressed size \(compressed.count)")
        let encrypted = DsgCipher.encrypt(compressed)

        // dsg_flash_utils.py: should_erase = blocknum > 2 (Driver/2 is scratchpad
        // RAM, not persistent flash - nothing to erase).
        let shouldErase = blockNumber > Dq250ModuleInfo.driverBlockNumber

        return PreparedBlockData(
            blockNumber: blockNumber,
            blockEncryptedBytes: encrypted,
            boxCode: boxCode,
            compressionType: 0x1,
            encryptionType: 0x1,
            shouldErase: shouldErase,
            udsChecksum: Dq250ModuleInfo.blockChecksums[blockNumber] ?? [0, 0, 0, 0],
            blockName: Dq250ModuleInfo.blockNamesFrf[blockNumber]
        )
    }

    // MARK: DQ381 (lib/dq381_flash_utils.py: checksum_and_patch_blocks + prepare_blocks)

    static func prepareDq381CalBlock(rawBytes: [UInt8], logDetail: ((String) -> Void)?) throws -> PreparedBlockData {
        guard let checksummed = DsgChecksum.fixDq381(rawBytes, baseAddress: Dq381ModuleInfo.calBaseAddress) else {
            throw PrepError.invalidChecksumRange
        }
        logDetail?("DQ381 CAL: embedded-range CRC32 checksum fixed.")

        var boxCode = "-"
        if let loc = Dq381ModuleInfo.boxCodeLocation[Dq381ModuleInfo.calBlockNumber] {
            let length = loc.end - loc.start
            if length > 0, loc.start + length <= checksummed.count {
                boxCode = String(decoding: checksummed[loc.start..<(loc.start + length)], as: UTF8.self)
            }
        }

        // The UDS-level checksum (routine 0x0202) is a plain whole-block
        // CRC32 of the checksummed-but-not-yet-compressed bytes - computed
        // here, before compression, matching dq381_flash_utils.py's
        // ordering exactly (block_checksum = zlib.crc32(binary_data)
        // computed from `block.block_bytes`, i.e. checksum_and_patch_blocks'
        // OUTPUT, before prepare_blocks compresses it).
        let udsChecksum = withUnsafeBytes(of: StandardCrc32.compute(checksummed).bigEndian) { Array($0) }

        logDetail?("DQ381 CAL: compressing (LZSS, exact padding), input size \(checksummed.count)")
        // dq381_flash_utils.py: lzss.lzss_compress(binary_data, exact_padding=True)
        let compressed = LzssCompressor.compress(checksummed, exactPad: true)

        logDetail?("DQ381 CAL: encrypting (AES-128-CBC), compressed size \(compressed.count)")
        // A failure here must abort the flash, not silently proceed with
        // empty/wrong bytes - unlike Simos18's BlockPreparer (which can
        // afford to `continue`/skip one block out of several and let the
        // caller notice a missing entry), this function returns exactly
        // one block, so there's no safe way to represent "skip this" other
        // than throwing.
        let encrypted = [UInt8](try AesCbcCipher.encrypt(
            Data(compressed), key: Data(Dq381ModuleInfo.aesKey), iv: Data(Dq381ModuleInfo.aesIv)))

        return PreparedBlockData(
            blockNumber: Dq381ModuleInfo.calBlockNumber,
            blockEncryptedBytes: encrypted,
            boxCode: boxCode,
            compressionType: 0xA,
            encryptionType: 0xA,
            shouldErase: true,
            udsChecksum: udsChecksum,
            blockName: Dq381ModuleInfo.blockNamesFrf[Dq381ModuleInfo.calBlockNumber]
        )
    }
}
