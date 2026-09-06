import Foundation

/// Port of Communication/Simos18/CbootPatcher.cs, itself ported from
/// VW_Flash (bri3d, BSD 2-Clause) lib/patch_cboot.py.
///
/// Original comment from patch_cboot.py, preserved verbatim for reference:
///
///   Here we look for
///
///   da 00           mov        d15,#0x0
///   3c 02           j          +2
///   da 01           mov        d15,#0x1
///   02 f2           mov        d2,d15
///
///   And patch it to
///
///   00 00           nop
///   00 00           nop
///   da 01           mov        d15,#0x1
///   02 f2           mov        d2,d15
///
///   This forces the return value of the method with this pattern to "1".
///   If the needle worked correctly, this will only match the
///   is_sample_mode function.
///
/// Logic is intentionally a 1:1 mirror of the Python original, including
/// the exact match-count edge case handling (0, 1, and 3+ matches are all
/// left unpatched; only exactly 2 matches are patched).
enum CbootPatcher {
    static let needle: [UInt8] = hexToBytes("DA003C02DA0102F2")
    static let patch: [UInt8] = hexToBytes("00000000DA0102F2")

    enum PatchResult {
        case patched
        case needleNotFound
        case tooManyMatches
    }

    /// Mirrors patch_cboot(cboot_binary: bytes) -> bytes from the Python original.
    static func patchCboot(_ cbootBinary: [UInt8]) -> (data: [UInt8], result: PatchResult) {
        var working = cbootBinary

        let firstAddress = indexOf(working, needle, from: 0)
        let secondAddress = firstAddress == -1 ? -1 : indexOf(working, needle, from: firstAddress + needle.count)
        let thirdAddress = secondAddress == -1 ? -1 : indexOf(working, needle, from: secondAddress + needle.count)

        if thirdAddress != -1 {
            return (working, .tooManyMatches) // "Too many matches" - returned unchanged, same as Python
        } else if firstAddress == -1 || secondAddress == -1 {
            return (working, .needleNotFound) // "Could not find needle for CBOOT patching. Already patched?"
        } else {
            for i in 0..<patch.count {
                working[firstAddress + i] = patch[i]
                working[secondAddress + i] = patch[i]
            }
            return (working, .patched)
        }
    }

    /// Byte-array equivalent of Python's bytes.find(sub, start).
    private static func indexOf(_ haystack: [UInt8], _ pattern: [UInt8], from start: Int) -> Int {
        let start = max(start, 0)
        if pattern.isEmpty { return start <= haystack.count ? start : -1 }

        let last = haystack.count - pattern.count
        guard last >= start else { return -1 }

        for i in start...last {
            var match = true
            for j in 0..<pattern.count {
                if haystack[i + j] != pattern[j] { match = false; break }
            }
            if match { return i }
        }
        return -1
    }
}
