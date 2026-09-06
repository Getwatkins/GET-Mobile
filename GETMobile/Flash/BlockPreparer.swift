import Foundation

/// Port of Communication/Simos18/BlockPreparer.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/simos_flash_utils.py:
/// checksum_and_patch_blocks() + prepare_blocks(). Takes raw block bytes (as
/// extracted from an FRF, or - for the unlock patch block - the pre-built
/// patch binary) and produces PreparedBlockData ready to send over UDS:
/// ECM3 checksum fixed (CAL only), CRC32 checksum fixed, optionally CBOOT
/// sample-mode patched, LZSS-compressed, then AES-encrypted.
enum BlockPreparer {
    private static let cbootBlockNumber = 1
    private static let asw1BlockNumber = 2
    private static let calBlockNumber = 5
    private static let cbootTempBlockNumber = 6

    enum PrepareError: Error, LocalizedError {
        case couldNotDetermineEcm3Addresses(blockNumber: Int)
        var errorDescription: String? {
            switch self {
            case .couldNotDetermineEcm3Addresses(let n):
                return "Could not locate ECM3 checksum addresses for block \(n) - see log for details."
            }
        }
    }

    static func prepareBlocks(
        blockNamesFrf: [Int: String],
        checksumBlockLocation: [Int: Int],
        baseAddresses: [Int: UInt32],
        boxCodeLocation: [Int: (start: Int, end: Int)],
        softwareVersionLocation: [Int: (start: Int, end: Int)],
        ecm3: Ecm3Constants,
        boxCodesCsvPath: String,
        aesKey: [UInt8],
        aesIv: [UInt8],
        udsBlockChecksum: [UInt8],
        inputBlocks: [Int: [UInt8]], // block number -> raw bytes
        shouldPatchCboot: Bool = false,
        logDetail: ((String) -> Void)? = nil
    ) -> [Int: PreparedBlockData] {
        let checksummedBlocks = checksumAndPatchBlocks(
            checksumBlockLocation: checksumBlockLocation, baseAddresses: baseAddresses,
            softwareVersionLocation: softwareVersionLocation, ecm3: ecm3, boxCodesCsvPath: boxCodesCsvPath,
            inputBlocks: inputBlocks, shouldPatchCboot: shouldPatchCboot, logDetail: logDetail)

        var output: [Int: PreparedBlockData] = [:]

        for (blockNum, binaryData) in checksummedBlocks {
            var boxCode = "-"
            if let loc = boxCodeLocation[blockNum] {
                let length = loc.end - loc.start
                if length > 0, loc.start + length <= binaryData.count {
                    boxCode = String(decoding: binaryData[loc.start..<(loc.start + length)], as: UTF8.self)
                }
            }

            logDetail?("Compressing block \(blockNum), input size: \(binaryData.count)")
            let compressed = blockNum < 6 ? LzssCompressor.compress(binaryData) : binaryData

            logDetail?("Encrypting block \(blockNum), compressed size: \(compressed.count)")
            let encrypted: [UInt8]
            do {
                encrypted = [UInt8](try AesCbcCipher.encrypt(Data(compressed), key: Data(aesKey), iv: Data(aesIv)))
            } catch {
                logDetail?("AES encryption failed for block \(blockNum): \(error.localizedDescription)")
                continue
            }

            output[blockNum] = PreparedBlockData(
                blockNumber: blockNum,
                blockEncryptedBytes: encrypted,
                boxCode: boxCode,
                compressionType: 0xA,
                encryptionType: 0xA,
                shouldErase: true,
                udsChecksum: udsBlockChecksum,
                blockName: blockNamesFrf[blockNum]
            )
        }

        return output
    }

    /// Mirrors checksum_and_patch_blocks(): ECM3 fix (CAL only) + CBOOT
    /// sample-mode patch (optional) + CRC32 fix (+ CBOOT_TEMP secondary fix
    /// for CBOOT). ECM3 runs against the CAL block's *original* bytes from
    /// inputBlocks, its result then feeds into the CRC32 step below, same
    /// order as the original.
    static func checksumAndPatchBlocks(
        checksumBlockLocation: [Int: Int],
        baseAddresses: [Int: UInt32],
        softwareVersionLocation: [Int: (start: Int, end: Int)],
        ecm3: Ecm3Constants,
        boxCodesCsvPath: String,
        inputBlocks: [Int: [UInt8]],
        shouldPatchCboot: Bool,
        logDetail: ((String) -> Void)?
    ) -> [Int: [UInt8]] {
        var output: [Int: [UInt8]] = [:]

        for (blockNum, originalData) in inputBlocks {
            var binaryData = originalData

            if blockNum == calBlockNumber {
                var addresses: [Int64]?

                if let asw1Bytes = inputBlocks[asw1BlockNumber] {
                    addresses = try? Ecm3Checksum.locateEcm3WithAsw1(
                        ecm3CalMonitorChecksum: ecm3.checksumOffset,
                        ecm3CalMonitorAddressesEarly: ecm3.addressesOffsetEarly,
                        ecm3CalMonitorAddresses: ecm3.addressesOffset,
                        ecm3CalMonitorOffsetUncached: ecm3.offsetUncached,
                        ecm3CalMonitorOffsetCached: ecm3.offsetCached,
                        asw1Bytes: asw1Bytes, calBytes: binaryData, calBaseAddress: baseAddresses[calBlockNumber]!)
                } else if let loc = softwareVersionLocation[calBlockNumber] {
                    addresses = Ecm3Checksum.loadEcm3Location(
                        calBytes: binaryData, softwareVersionLocation: loc, boxCodesCsvPath: boxCodesCsvPath)
                }

                guard let resolvedAddresses = addresses else {
                    logDetail?("Failure to checksum and/or locate ECM3 addresses! Skipping this block.")
                    continue // matches the Python's `continue` on FAILED_ACTION
                }

                let (ecm3Result, ecm3Fixed) = Ecm3Checksum.validateEcm3(
                    addresses: resolvedAddresses, dataBinaryCal: binaryData,
                    ecm3CalMonitorChecksum: ecm3.checksumOffset, shouldFix: true)
                binaryData = ecm3Fixed
                logDetail?("ECM3 checksum result: \(ecm3Result)")
            }

            if blockNum == cbootBlockNumber, shouldPatchCboot {
                logDetail?("Patching CBOOT into Sample Mode.")
                let (patched, patchResult) = CbootPatcher.patchCboot(binaryData)
                binaryData = patched
                logDetail?("CBOOT sample-mode patch result: \(patchResult)")
            }

            var correctedFile: [UInt8]
            if blockNum < 6 {
                let (result, fixedData) = BlockChecksum.validate(
                    checksumBlockLocation: checksumBlockLocation, baseAddresses: baseAddresses,
                    dataBinary: binaryData, blockNum: blockNum, shouldFix: true)
                correctedFile = fixedData
                logDetail?("Block \(blockNum) CRC32 checksum: \(result)")

                if blockNum == cbootBlockNumber {
                    let (tempResult, tempFixed) = BlockChecksum.validate(
                        checksumBlockLocation: checksumBlockLocation, baseAddresses: baseAddresses,
                        dataBinary: correctedFile, blockNum: cbootTempBlockNumber, shouldFix: true)
                    correctedFile = tempFixed
                    logDetail?("CBOOT_TEMP secondary CRC32 checksum: \(tempResult)")
                }
            } else {
                correctedFile = binaryData
            }

            output[blockNum] = correctedFile
        }

        return output
    }
}
