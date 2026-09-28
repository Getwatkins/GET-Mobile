import Foundation

/// Port of lib/crypto/dsg.py (bri3d/VW_Flash, BSD-2-Clause) - the DQ250-MQB
/// DSG's block encryption. A progressive substitution cipher: a rolling
/// offset (built from the data stream itself, the previous byte, and a
/// slowly-advancing pointer into the key table) selects where in a 256-byte
/// permutation table each byte gets looked up. Per VW_Flash's own comment,
/// reverse-engineered directly from the TCM's firmware (code at 0x800164AC,
/// key material at 0x8001053C, from DQ250_MQB_0D9300012L_4516).
///
/// Verified before use: `dsgKeyTable` is confirmed a true permutation of
/// 0-255 (each byte value appears exactly once - required for `encrypt` to
/// have a well-defined inverse), and a Python mirror of this exact
/// algorithm was round-tripped (encrypt then decrypt recovers the original)
/// against the real key bytes below.
enum DsgCipher {
    /// mqb_dsg_key.bin, embedded directly (VW_Flash reads it from disk;
    /// there's no separate "resource" concept worth introducing here for
    /// one fixed 256-byte table).
    private static let dsgKeyTable: [UInt8] = hexToBytes(
        "4593ca72845d11e978b99fa265e28be5c977cd59f78901bf02f368e0dc30c4d" +
        "4f525cc8723c8ee3a12ab70610041d30dc0f422afd1cbb0b715278fd909ac5c" +
        "f2f1c72a21568c063508e7c3734939cf40436bc66eea906d1bb453d25fb674" +
        "16d72b975a8a58c53375fcad3b60ce62912d0c3cda42269283fa182832074a" +
        "bb542cb89d4ce4a4715ea7ed2f377634d8c18e44636451f61ec2f8690adfe6" +
        "f99e4ea8ff889a5b0f1f3f24e3fe9bb3a58086961d50de04a6553d059ceb8d" +
        "b5ef946c31a02014134f66f02946bdd64bdbbe360b85a1b2b11910fd1c81e1" +
        "0e7da9e847d51a035738bcae98fbaa7e6a526f17a3677a7bddec2e3e7f7c48" +
        "d099ba79954d82"
    )

    /// Index[value] -> position in dsgKeyTable where `value` lives.
    /// Precomputed once since the table is fixed; equivalent to (and
    /// verified against) Python's `dsg_key_bytes.index(data_byte)`, which
    /// only has a well-defined single answer because the table is a true
    /// permutation.
    private static let inverseTable: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (index, value) in dsgKeyTable.enumerated() { inv[Int(value)] = UInt8(index) }
        return inv
    }()

    /// Encrypts plaintext (e.g. compressed calibration data) into what the
    /// TCM expects to receive. This is the direction actually used for
    /// flashing - decrypt() is not needed here and not implemented.
    static func encrypt(_ data: [UInt8]) -> [UInt8] {
        var offset: UInt8 = 0
        var rollingStreamOffset: UInt16 = 0
        var lastData: UInt8 = 0
        var output = [UInt8](); output.reserveCapacity(data.count)

        for byte in data {
            let matchIndex = inverseTable[Int(byte)]
            let cipherByte = matchIndex &- offset
            offset = offset &+ byte
            offset = offset &+ lastData
            rollingStreamOffset = rollingStreamOffset &+ 0x167
            offset = offset &+ dsgKeyTable[Int((rollingStreamOffset >> 8) & 0xFF)]
            lastData = byte
            output.append(cipherByte)
        }
        return output
    }
}
