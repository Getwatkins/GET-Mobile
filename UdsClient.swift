import Foundation

/// Port of Communication/J2534/Uds/UdsClient.cs. Standard ISO 14229-1
/// service framing (documented protocol, not reverse-engineered) built on
/// top of UdsTransport - works identically whether the underlying
/// connection is the ESP32 bridge, ELM327 WiFi, or ELM327 BLE.
///
/// The one behavior carried over from the original because it's easy to
/// miss and matters for real ECUs: on NRC 0x78 ("response pending"), keep
/// waiting instead of failing - see sendRequest(_:).
final class UdsClient {
    private let transport: UdsTransport
    private let rxID: UInt16
    private let txID: UInt16

    /// Normal per-request timeout, matching flash_uds.py's Client(request_timeout=5).
    var requestTimeoutSeconds: Double = 5

    /// Extended timeout used while the server is sending NRC 0x78 (response
    /// pending). UnlockSequence widens requestTimeoutSeconds to 30s after
    /// entering the programming session anyway, which in practice covers
    /// this too; kept as a separate, generous default regardless.
    var responsePendingTimeoutSeconds: Double = 30

    init(transport: UdsTransport, rxID: UInt16 = BridgeProtocol.simos18ResponseID, txID: UInt16 = BridgeProtocol.simos18RequestID) {
        self.transport = transport
        self.rxID = rxID
        self.txID = txID
    }

    enum ClientError: Error, LocalizedError {
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .malformedResponse(let detail): return detail
            }
        }
    }

    // MARK: Core request loop

    /// Sends a UDS request and returns the raw response frame, retrying the
    /// *wait* (not the send) while the server replies with NRC 0x78
    /// RequestCorrectlyReceived_ResponsePending. Throws
    /// UdsNegativeResponseException for any other negative response.
    func sendRequest(_ request: Data) async throws -> Data {
        var timeout = requestTimeoutSeconds
        var usingExtendedTimeout = false
        var response = try await transport.sendRequest(rxID: rxID, txID: txID, payload: request, timeoutSeconds: timeout)

        while true {
            let bytes = [UInt8](response)
            if bytes.count >= 3, bytes[0] == UdsPdu.negativeResponseSid,
               bytes[2] == UdsNegativeResponseCode.requestCorrectlyReceivedResponsePending.rawValue {
                if !usingExtendedTimeout {
                    timeout = responsePendingTimeoutSeconds
                    usingExtendedTimeout = true
                }
                response = try await transport.waitForResponse(timeoutSeconds: timeout)
                continue
            }
            return response
        }
    }

    /// Sends a raw, pre-built request payload instead of the normal
    /// encoding, still going through the same 0x78-aware wait loop. Used
    /// for the "switchpatch" programming-session fallback in UnlockSequence.
    func sendRawRequest(_ rawRequest: Data) async throws -> Data {
        try await sendRequest(rawRequest)
    }

    // MARK: DiagnosticSessionControl (0x10)

    func changeSession(_ session: UdsSession) async throws {
        let request = UdsPdu.buildRequest(.diagnosticSessionControl, subfunction: session.rawValue)
        let response = try await sendRequest(request)
        _ = try UdsPdu.parseResponse(.diagnosticSessionControl, response, hasSubfunctionEcho: true)
    }

    // MARK: TesterPresent (0x3E)

    func testerPresent() async throws {
        let request = UdsPdu.buildRequest(.testerPresent, subfunction: 0x00)
        let response = try await sendRequest(request)
        _ = try UdsPdu.parseResponse(.testerPresent, response, hasSubfunctionEcho: true)
    }

    // MARK: ReadDataByIdentifier (0x22)

    /// Reads a single DID and returns the raw data (with the echoed 2-byte
    /// DID stripped off). Same external behavior as before this class grew
    /// the rest of the flashing methods - GaugeSession's live-poll loop uses
    /// this unchanged.
    func readDataByIdentifier(_ did: UInt16) async throws -> Data {
        var didBytes = Data()
        didBytes.append(UInt8((did >> 8) & 0xFF))
        didBytes.append(UInt8(did & 0xFF))

        let request = UdsPdu.buildRequest(.readDataByIdentifier, data: didBytes)
        let response = try await sendRequest(request)
        let (payload, _) = try UdsPdu.parseResponse(.readDataByIdentifier, response, hasSubfunctionEcho: false)

        guard payload.count >= 2 else {
            throw ClientError.malformedResponse("ReadDataByIdentifier response missing echoed DID.")
        }
        return payload.suffix(from: payload.startIndex.advanced(by: 2))
    }

    func readDataByIdentifierAsAscii(_ did: UInt16) async throws -> String {
        let data = try await readDataByIdentifier(did)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: RequestDownload (0x34)

    /// Mirrors client.request_download(memloc, dfi): blockIdentifier encoded
    /// as a single-byte address (address_format=8), blockLength as a 4-byte
    /// big-endian size (memorysize_format=32) - matching flash_block()'s
    /// exact encoding, not a general-purpose arbitrary-format implementation.
    @discardableResult
    func requestDownload(blockIdentifier: UInt8, blockLength: UInt32, compressionType: UInt8, encryptionType: UInt8) async throws -> Data {
        let dfiByte = ((compressionType & 0xF) << 4) | (encryptionType & 0xF)
        let alfidByte: UInt8 = 0x41 // (memorysize_format=32 -> 4 bytes) << 4 | (address_format=8 -> 1 byte)

        var payload = Data()
        payload.append(dfiByte)
        payload.append(alfidByte)
        payload.append(blockIdentifier)
        payload.append(UInt8((blockLength >> 24) & 0xFF))
        payload.append(UInt8((blockLength >> 16) & 0xFF))
        payload.append(UInt8((blockLength >> 8) & 0xFF))
        payload.append(UInt8(blockLength & 0xFF))

        let request = UdsPdu.buildRequest(.requestDownload, data: payload)
        let response = try await sendRequest(request)
        let (result, _) = try UdsPdu.parseResponse(.requestDownload, response, hasSubfunctionEcho: false)
        return result
    }

    // MARK: TransferData (0x36)

    /// Mirrors client.transfer_data(sequence_number, data), including
    /// validating the echoed sequence number matches what was sent.
    func transferData(sequenceNumber: UInt8, data: Data) async throws {
        var payload = Data([sequenceNumber])
        payload.append(data)

        let request = UdsPdu.buildRequest(.transferData, data: payload)
        let response = try await sendRequest(request)
        let (responsePayload, _) = try UdsPdu.parseResponse(.transferData, response, hasSubfunctionEcho: false)

        guard let echoed = responsePayload.first, echoed == sequenceNumber else {
            let echoedStr = responsePayload.first.map { String(format: "0x%02X", $0) } ?? "0x00"
            throw ClientError.malformedResponse(
                "TransferData response echoed sequence number \(echoedStr), expected \(String(format: "0x%02X", sequenceNumber)).")
        }
    }

    /// Mirrors flash_uds.py's counter wraparound (next_counter): 1..0xFF then wraps to 0, not back to 1.
    static func nextTransferCounter(_ counter: UInt8) -> UInt8 {
        counter == 0xFF ? 0 : counter + 1
    }

    // MARK: RequestTransferExit (0x37)

    func requestTransferExit() async throws {
        let request = UdsPdu.buildRequest(.requestTransferExit)
        let response = try await sendRequest(request)
        _ = try UdsPdu.parseResponse(.requestTransferExit, response, hasSubfunctionEcho: false)
    }

    // MARK: ReadDTCInformation (0x19)

    /// Sub-function 0x02 (reportDTCByStatusMask). Returns the raw response
    /// payload (SID and subfunction echo already stripped) -
    /// [availabilityMask][DTC hi][DTC mid][DTC lo][status] repeated per DTC.
    func readDtcByStatusMask(_ statusMask: UInt8) async throws -> Data {
        let request = UdsPdu.buildRequest(.readDTCInformation, subfunction: 0x02, data: Data([statusMask]))
        let response = try await sendRequest(request)
        let (payload, _) = try UdsPdu.parseResponse(.readDTCInformation, response, hasSubfunctionEcho: true)
        return payload
    }

    // MARK: WriteDataByIdentifier (0x2E)

    func writeDataByIdentifier(_ did: UInt16, data: Data) async throws {
        var didBytes = Data()
        didBytes.append(UInt8((did >> 8) & 0xFF))
        didBytes.append(UInt8(did & 0xFF))

        var payload = didBytes
        payload.append(data)

        let request = UdsPdu.buildRequest(.writeDataByIdentifier, data: payload)
        let response = try await sendRequest(request)
        let (responsePayload, _) = try UdsPdu.parseResponse(.writeDataByIdentifier, response, hasSubfunctionEcho: false)

        let bytes = [UInt8](responsePayload)
        guard bytes.count >= 2, bytes[0] == didBytes[0], bytes[1] == didBytes[1] else {
            throw ClientError.malformedResponse("WriteDataByIdentifier response did not echo the expected DID.")
        }
    }

    // MARK: ECUReset (0x11)

    enum ResetType: UInt8 {
        case hardReset = 1
        case keyOffOnReset = 2
        case softReset = 3
    }

    func ecuReset(_ resetType: ResetType) async throws {
        let request = UdsPdu.buildRequest(.ecuReset, subfunction: resetType.rawValue)
        let response = try await sendRequest(request)
        _ = try UdsPdu.parseResponse(.ecuReset, response, hasSubfunctionEcho: true)
    }

    // MARK: RoutineControl (0x31)

    @discardableResult
    func startRoutine(_ routineId: UInt16, data: Data? = nil) async throws -> Data {
        var routineIdBytes = Data()
        routineIdBytes.append(UInt8((routineId >> 8) & 0xFF))
        routineIdBytes.append(UInt8(routineId & 0xFF))

        var payload = routineIdBytes
        if let data { payload.append(data) }

        let request = UdsPdu.buildRequest(.routineControl, subfunction: UdsRoutineControlType.start.rawValue, data: payload)
        let response = try await sendRequest(request)
        let (result, _) = try UdsPdu.parseResponse(.routineControl, response, hasSubfunctionEcho: true)
        return result
    }

    // MARK: SecurityAccess (0x27)

    enum SecurityError: Error, LocalizedError {
        case echoedWrongLevel(got: UInt8?, expected: UInt8)
        var errorDescription: String? {
            switch self {
            case .echoedWrongLevel(let got, let expected):
                let gotStr = got.map { String(format: "0x%02X", $0) } ?? "nil"
                return "SecurityAccess response echoed level \(gotStr), expected \(String(format: "0x%02X", expected))."
            }
        }
    }

    /// Requests a seed for the given security level (must be the odd
    /// subfunction value, e.g. 0x11) and returns the raw seed bytes.
    func requestSeed(level: UInt8, seedParams: Data? = nil) async throws -> Data {
        let request = UdsPdu.buildRequest(.securityAccess, subfunction: level, data: seedParams)
        let response = try await sendRequest(request)
        let (payload, echoedLevel) = try UdsPdu.parseResponse(.securityAccess, response, hasSubfunctionEcho: true)

        guard echoedLevel == level else { throw SecurityError.echoedWrongLevel(got: echoedLevel, expected: level) }
        return payload
    }

    /// Sends a computed key for the given (even) security level, e.g. 0x12.
    func sendKey(level: UInt8, key: Data) async throws {
        let request = UdsPdu.buildRequest(.securityAccess, subfunction: level, data: key)
        let response = try await sendRequest(request)
        let (_, echoedLevel) = try UdsPdu.parseResponse(.securityAccess, response, hasSubfunctionEcho: true)

        guard echoedLevel == level else { throw SecurityError.echoedWrongLevel(got: echoedLevel, expected: level) }
    }

    /// Full SA2 Seed/Key unlock: request seed at requestSeedLevel (must be
    /// odd, e.g. 0x11), compute the key by running sa2Script against the
    /// seed via Sa2SeedKeyVm, and send it at sendKeyLevel (the corresponding
    /// even value, e.g. 0x12). Mirrors flash_uds.py's
    /// volkswagen_security_algo + client.unlock_security_access(17),
    /// including udsoncan's "all-zero seed means already unlocked, skip the
    /// key send" check.
    func unlockSecurityAccess(requestSeedLevel: UInt8, sendKeyLevel: UInt8, sa2Script: [UInt8]) async throws {
        let seed = try await requestSeed(level: requestSeedLevel)

        let seedBytes = [UInt8](seed)
        let seedIsAllZero = !seedBytes.contains { $0 != 0 }
        if !seedBytes.isEmpty, seedIsAllZero {
            return // already unlocked - matches udsoncan's behavior exactly
        }

        let seedValue = bytesToUInt32BigEndian(seedBytes)
        let keyValue = try Sa2SeedKeyVm(instructionTape: sa2Script, seed: seedValue).execute()
        let key = uInt32ToBytesBigEndian(keyValue)

        try await sendKey(level: sendKeyLevel, key: key)
    }

    private func bytesToUInt32BigEndian(_ bytes: [UInt8]) -> UInt32 {
        // Only ever a 4-byte seed for SA2, but tolerate shorter/longer defensively rather than assuming.
        var value: UInt32 = 0
        for b in bytes { value = (value << 8) | UInt32(b) }
        return value
    }

    private func uInt32ToBytesBigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
