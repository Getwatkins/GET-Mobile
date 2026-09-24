import Foundation

/// Port of Communication/J2534/Uds/UdsPdu.cs.
enum UdsServiceId: UInt8 {
    case diagnosticSessionControl = 0x10
    case ecuReset = 0x11
    case readDTCInformation = 0x19
    case readDataByIdentifier = 0x22
    case securityAccess = 0x27
    case writeDataByIdentifier = 0x2E
    case routineControl = 0x31
    case requestDownload = 0x34
    case transferData = 0x36
    case requestTransferExit = 0x37
    case testerPresent = 0x3E
}

enum UdsSession: UInt8 {
    case `default` = 1
    case programming = 2
    case extendedDiagnostic = 3
}

enum UdsRoutineControlType: UInt8 {
    case start = 1
    case stop = 2
    case requestResults = 3
}

/// Standard ISO 14229-1 negative response codes (for accurate error messages).
enum UdsNegativeResponseCode: UInt8 {
    case generalReject = 0x10
    case serviceNotSupported = 0x11
    case subFunctionNotSupported = 0x12
    case incorrectMessageLengthOrInvalidFormat = 0x13
    case responseTooLong = 0x14
    case busyRepeatRequest = 0x21
    case conditionsNotCorrect = 0x22
    case requestSequenceError = 0x24
    case noResponseFromSubnetComponent = 0x25
    case failurePreventsExecutionOfRequestedAction = 0x26
    case requestOutOfRange = 0x31
    case securityAccessDenied = 0x33
    case authenticationRequired = 0x34
    case invalidKey = 0x35
    case exceedNumberOfAttempts = 0x36
    case requiredTimeDelayNotExpired = 0x37
    case uploadDownloadNotAccepted = 0x70
    case transferDataSuspended = 0x71
    case generalProgrammingFailure = 0x72
    case wrongBlockSequenceCounter = 0x73
    case requestCorrectlyReceivedResponsePending = 0x78
    case subFunctionNotSupportedInActiveSession = 0x7E
    case serviceNotSupportedInActiveSession = 0x7F
}

struct UdsNegativeResponseException: Error, LocalizedError {
    let requestedService: UdsServiceId
    let negativeResponseCode: UInt8

    var errorDescription: String? {
        let nrcName = UdsNegativeResponseCode(rawValue: negativeResponseCode).map { String(describing: $0) }
            ?? String(format: "Unknown(0x%02X)", negativeResponseCode)
        return String(format: "Server refused %@ with negative response code %@ (0x%02X).",
                      String(describing: requestedService), nrcName, negativeResponseCode)
    }
}

/// Minimal standard UDS request/response framing. Not VW-specific and not
/// reverse-engineered - this is exactly what ISO 14229-1 documents:
///
///   Request:           [SID] [subfunction?] [data...]
///   Positive response: [SID + 0x40] [subfunction echo?] [data...]
///   Negative response: [0x7F] [SID] [NRC]
enum UdsPdu {
    static let negativeResponseSid: UInt8 = 0x7F

    static func buildRequest(_ sid: UdsServiceId, subfunction: UInt8? = nil, data: Data? = nil) -> Data {
        var request = Data()
        request.append(sid.rawValue)
        if let subfunction { request.append(subfunction) }
        if let data { request.append(data) }
        return request
    }

    enum ParseError: Error, LocalizedError {
        case emptyResponse
        case malformedNegativeResponse
        case missingSubfunctionEcho
        case unexpectedSid(got: UInt8, expected: UInt8, service: UdsServiceId)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Empty UDS response."
            case .malformedNegativeResponse: return "Malformed negative UDS response (too short)."
            case .missingSubfunctionEcho: return "UDS response missing expected subfunction echo byte."
            case .unexpectedSid(let got, let expected, let service):
                return String(format: "Unexpected UDS response SID 0x%02X, expected positive response 0x%02X for %@.", got, expected, String(describing: service))
            }
        }
    }

    /// Validates a response against the expected service, throwing
    /// UdsNegativeResponseException on a 0x7F negative response. Returns
    /// the response payload with the SID (and, if present, subfunction
    /// echo) stripped off.
    static func parseResponse(_ expectedSid: UdsServiceId, _ response: Data, hasSubfunctionEcho: Bool) throws -> (payload: Data, subfunctionEcho: UInt8?) {
        guard !response.isEmpty else { throw ParseError.emptyResponse }
        let bytes = [UInt8](response)

        if bytes[0] == negativeResponseSid {
            guard bytes.count >= 3 else { throw ParseError.malformedNegativeResponse }
            let requestedService = UdsServiceId(rawValue: bytes[1]) ?? expectedSid
            throw UdsNegativeResponseException(requestedService: requestedService, negativeResponseCode: bytes[2])
        }

        let expectedPositiveSid = expectedSid.rawValue &+ 0x40
        guard bytes[0] == expectedPositiveSid else {
            throw ParseError.unexpectedSid(got: bytes[0], expected: expectedPositiveSid, service: expectedSid)
        }

        var headerLen = 1
        var subfunctionEcho: UInt8? = nil
        if hasSubfunctionEcho {
            guard bytes.count >= 2 else { throw ParseError.missingSubfunctionEcho }
            subfunctionEcho = bytes[1]
            headerLen = 2
        }

        return (response.suffix(from: response.startIndex.advanced(by: headerLen)), subfunctionEcho)
    }
}
