import Foundation

/// Mirrors Communication/J2534/Uds/UdsClient.cs's ReadDataByIdentifier -
/// same UDS service byte (0x22), same request/response shape, same
/// Simos18 rxID/txID. The only thing that changed vs. the Windows app is
/// the transport underneath (BLE bridge instead of a J2534 USB cable).
final class UdsClient {
    private let transport: UdsTransport

    init(transport: UdsTransport) {
        self.transport = transport
    }

    enum UdsError: Error, LocalizedError {
        case negativeResponse(code: UInt8)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .negativeResponse(let code): return String(format: "ECU returned negative response (NRC 0x%02X)", code)
            case .malformedResponse: return "Malformed UDS response."
            }
        }
    }

    /// Reads one DID (service 0x22). Positive response is
    /// [0x62][DIDhi][DIDlo][data...], same as the Windows app expects.
    func readDataByIdentifier(_ did: UInt16) async throws -> Data {
        var request = Data()
        request.append(0x22)
        request.append(UInt8((did >> 8) & 0xFF))
        request.append(UInt8(did & 0xFF))

        let response = try await transport.sendRequest(rxID: BridgeProtocol.simos18ResponseID,
                                                         txID: BridgeProtocol.simos18RequestID,
                                                         payload: request)

        guard response.count >= 3 else { throw UdsError.malformedResponse }
        let bytes = [UInt8](response)

        if bytes[0] == 0x7F { // negative response: [0x7F][serviceEcho][NRC]
            throw UdsError.negativeResponse(code: bytes.count > 2 ? bytes[2] : 0)
        }
        guard bytes[0] == 0x62, bytes[1] == UInt8((did >> 8) & 0xFF), bytes[2] == UInt8(did & 0xFF) else {
            throw UdsError.malformedResponse
        }
        return response.suffix(from: response.startIndex.advanced(by: 3))
    }
}
