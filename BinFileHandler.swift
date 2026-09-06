import Foundation

/// Port of Communication/Simos18/BinFileHandler.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/binfile.py. Splits a single flat
/// combined .bin file (the normal, everyday tune-file format - what most
/// commercial Simos18 tools produce/expect) into the 5 addressable blocks
/// using the module's offset table, then filters out any block whose
/// embedded software-version string doesn't match the expected ECU family -
/// this is what actually catches "wrong file for this ECU" rather than
/// silently proceeding with garbage.
enum BinFileHandler {
    static func blocksFromData(
        _ data: [UInt8],
        binfileOffsets: [Int: Int],
        blockLengths: [Int: Int],
        softwareVersionLocation: [Int: (start: Int, end: Int)],
        projectName: String,
        blockNumbers: [Int] = [1, 2, 3, 4, 5]
    ) -> (blocks: [Int: [UInt8]], warnings: [String]) {
        var warnings: [String] = []
        var inputBlocks: [Int: [UInt8]] = [:]

        for blockNumber in blockNumbers {
            guard let offset = binfileOffsets[blockNumber], let length = blockLengths[blockNumber] else { continue }

            if offset + length > data.count {
                warnings.append(
                    "Block \(blockNumber) would read past the end of the file (offset 0x\(String(offset, radix: 16, uppercase: true)) + length 0x\(String(length, radix: 16, uppercase: true)) > file size \(data.count)). " +
                    "This usually means the file is truncated, or isn't a full flat Simos18 image.")
                continue
            }

            inputBlocks[blockNumber] = Array(data[offset..<(offset + length)])
        }

        let filtered = filterBlocks(inputBlocks, softwareVersionLocation: softwareVersionLocation, projectName: projectName, warnings: &warnings)
        return (filtered, warnings)
    }

    private static func filterBlocks(
        _ inputBlocks: [Int: [UInt8]],
        softwareVersionLocation: [Int: (start: Int, end: Int)],
        projectName: String,
        warnings: inout [String]
    ) -> [Int: [UInt8]] {
        var result = inputBlocks
        var toRemove: [Int] = []

        for (blockNumber, blockBytes) in inputBlocks {
            guard let loc = softwareVersionLocation[blockNumber] else {
                warnings.append("Discarding block \(blockNumber) because it did not contain a project ID.")
                toRemove.append(blockNumber)
                continue
            }

            if loc.end > 0 {
                let length = loc.end - loc.start
                guard length > 0, loc.start + length <= blockBytes.count else {
                    warnings.append("Discarding block \(blockNumber) because it did not contain a project ID.")
                    toRemove.append(blockNumber)
                    continue
                }
                let info = String(decoding: blockBytes[loc.start..<(loc.start + length)], as: UTF8.self)

                if !info.hasPrefix(projectName) {
                    warnings.append("Discarding block \(blockNumber) because project ID \"\(info)\" does not match \"\(projectName)\".")
                    toRemove.append(blockNumber)
                }
            } else {
                warnings.append("Keeping block \(blockNumber) because it has no version specifier.")
            }
        }

        for blockNumber in toRemove {
            result.removeValue(forKey: blockNumber)
        }

        return result
    }
}
