import Foundation

/// Port of Communication/Simos18/Crypto/LzssCompressor.cs (itself ported from
/// VW_Flash's vendored lib/lzss/lzss.c, Michael Dipperstein's LZSS
/// implementation, LGPL 2.1) - EncodeLZSS() only, the compression direction,
/// since that's the only one the flashing pipeline needs (the ECU
/// decompresses; nothing here needs to).
///
/// A byte-oriented sliding-window LZ77 variant (Storer & Szymanski's LZSS)
/// with a fixed 1023-byte window and a coded/uncoded flag grouped 8-to-a-byte.
/// Faithfully keeps the original's specific quirks: encoder fills the window
/// with 0x11 (not zero), match length is capped at 0x3F (63), and there are
/// two distinct padding schemes (-p "skip padding to 16" and -e "exact
/// padding via no-op compression commands") - Simos uses neither, default
/// padding to a multiple of 0x10.
enum LzssCompressor {
    private static let windowSize = 1023 // 10 bits
    private static let maxUncoded = 2
    private static let maxCoded = 61 + 2 + 1 // 64

    private struct EncodedString {
        var offset: Int
        var length: Int
    }

    /// - Parameters:
    ///   - dontPad: mirrors the `-p` flag: skip padding output to a multiple of 0x10.
    ///   - exactPad: mirrors the `-e` flag: pad using no-op compression commands so decompressed length matches exactly.
    static func compress(_ input: [UInt8], dontPad: Bool = false, exactPad: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)

        if input.isEmpty { return [] } // matches EncodeLZSS returning immediately on empty input, before any padding

        var slidingWindow = [UInt8](repeating: 0x11, count: windowSize)
        var uncodedLookahead = [UInt8](repeating: 0, count: maxCoded)

        var windowHead = 0
        var uncodedHead = 0
        var compressedSize = 0

        var inputPos = 0
        var len = 0
        while len < maxCoded, inputPos < input.count {
            uncodedLookahead[len] = input[inputPos]
            inputPos += 1
            len += 1
        }

        var matchData = findMatch(slidingWindow, uncodedLookahead, windowHead, uncodedHead, len)

        var flags: UInt8 = 0
        var flagPos: UInt8 = 0x80
        var encodedData = [UInt8](repeating: 0, count: 16)
        var nextEncoded = 0

        while len > 0 {
            if matchData.length > 0x3F {
                matchData.length = 0x3F
            }

            if matchData.length <= maxUncoded {
                matchData.length = 1
                encodedData[nextEncoded] = uncodedLookahead[uncodedHead]
                nextEncoded += 1
            } else {
                let a = UInt8(truncatingIfNeeded: ((windowSize - matchData.offset) >> 8) | (matchData.length << 2))
                let b = UInt8(truncatingIfNeeded: (windowSize - matchData.offset) & 0xFF)
                encodedData[nextEncoded] = a; nextEncoded += 1
                encodedData[nextEncoded] = b; nextEncoded += 1
                flags |= flagPos
            }

            if flagPos == 0x01 {
                output.append(flags)
                compressedSize += 1
                for i in 0..<nextEncoded {
                    output.append(encodedData[i])
                    compressedSize += 1
                }
                flags = 0
                flagPos = 0x80
                nextEncoded = 0
            } else {
                flagPos >>= 1
            }

            var consumed = 0
            while consumed < matchData.length, inputPos < input.count {
                slidingWindow[windowHead] = uncodedLookahead[uncodedHead]
                uncodedLookahead[uncodedHead] = input[inputPos]
                inputPos += 1
                windowHead = (windowHead + 1) % windowSize
                uncodedHead = (uncodedHead + 1) % maxCoded
                consumed += 1
            }

            while consumed < matchData.length {
                slidingWindow[windowHead] = uncodedLookahead[uncodedHead]
                windowHead = (windowHead + 1) % windowSize
                uncodedHead = (uncodedHead + 1) % maxCoded
                len -= 1
                consumed += 1
            }

            matchData = findMatch(slidingWindow, uncodedLookahead, windowHead, uncodedHead, len)
        }

        if nextEncoded != 0 {
            let totalSize = compressedSize + nextEncoded + 1
            var remainder = 16 - (totalSize % 16)

            if exactPad, totalSize % 16 != 0 {
                while (compressedSize + nextEncoded + 1) % 16 != 0 {
                    if flagPos == 0x00 { break }
                    remainder -= 2
                    encodedData[nextEncoded] = 0; nextEncoded += 1
                    encodedData[nextEncoded] = 0; nextEncoded += 1
                    flags |= flagPos
                    flagPos >>= 1
                }
            }
            _ = remainder // matches the C#: computed but only used inside the exactPad branch above

            output.append(flags)
            compressedSize += 1
            for i in 0..<nextEncoded {
                output.append(encodedData[i])
                compressedSize += 1
            }
        }

        if exactPad {
            var remainder = 16 - (compressedSize % 16)
            let paddingLengths = [0x0, 0x1, 0x12, 0x3, 0x14, 0x5, 0x16, 0x7, 0x18, 0x9, 0x1A, 0xB, 0x1C, 0xD, 0x1E, 0xF, 0x0]
            let paddingBlock: [UInt8] = [0xFF, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0]
            remainder = paddingLengths[remainder]
            for i in 0..<remainder {
                output.append(paddingBlock[i % 0x11])
                compressedSize += 1
            }
        }

        if !dontPad {
            while compressedSize % 0x10 != 0 {
                output.append(0x00)
                compressedSize += 1
            }
        }

        return output
    }

    private static func findMatch(_ slidingWindow: [UInt8], _ uncodedLookahead: [UInt8], _ windowHead: Int, _ uncodedHead: Int, _ uncodedTail: Int) -> EncodedString {
        var matchData = EncodedString(offset: 0, length: 0)

        for i in 0..<windowSize {
            var k = 0
            for j in 0..<maxCoded {
                if j == uncodedTail { break }
                if (i + j) == windowSize { break }
                if slidingWindow[(windowHead + i + j) % windowSize] != uncodedLookahead[(uncodedHead + j) % maxCoded] {
                    break
                }
                k = j + 1
                if k >= matchData.length {
                    matchData.length = k
                    matchData.offset = i
                }
            }
        }

        return matchData
    }
}
