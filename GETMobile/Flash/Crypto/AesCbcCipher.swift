import Foundation
import CommonCrypto

/// Port of Communication/Simos18/Crypto/AesCbcCipher.cs. Like the C# original,
/// this isn't an algorithmic "port" - AES-CBC is a fixed standard - it just
/// has to call the platform's implementation with the same key/IV/mode/no-padding
/// settings. CommonCrypto's CCCrypt with options=0 (no kCCOptionPKCS7Padding)
/// is the direct equivalent of .NET's Aes with Padding = PaddingMode.None:
/// the input must already be a multiple of the 16-byte block size, which it
/// always is here since LZSS compression pads its output to a multiple of 16
/// before AES ever sees it (same precondition the C# doc comment notes).
enum AesCbcCipher {
    enum CryptoError: Error, LocalizedError {
        case operationFailed(CCCryptorStatus)
        case invalidKeyOrIVLength
        var errorDescription: String? {
            switch self {
            case .operationFailed(let status): return "AES-CBC operation failed (status \(status))."
            case .invalidKeyOrIVLength: return "AES key must be 16/24/32 bytes and IV must be 16 bytes."
            }
        }
    }

    static func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidKeyOrIVLength
        }

        var outBuffer = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var bytesMoved = 0

        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                data.withUnsafeBytes { dataPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        0, // no padding - matches .NET's PaddingMode.None; caller must pre-pad to a multiple of 16
                        keyPtr.baseAddress, key.count,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress, data.count,
                        &outBuffer, outBuffer.count,
                        &bytesMoved
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw CryptoError.operationFailed(status) }
        return Data(outBuffer.prefix(bytesMoved))
    }
}
