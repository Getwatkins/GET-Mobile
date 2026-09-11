import Foundation
import Network

/// Talks to a Macchina A0 running A0RET firmware in WiFi mode (the same
/// protocol SavvyCAN uses) over a plain TCP socket. Unlike the other 3
/// transports, this one has to do its own ISO-TP segmentation (see
/// IsoTp.swift) since A0RET only relays raw CAN frames.
@MainActor
final class GvretWifiManager: NSObject, ObservableObject, UdsTransport, HslRawTransport {
    @Published private(set) var state: BridgeConnectionState = .disconnected

    /// Raw diagnostic trail - every command we send, and every CAN frame we
    /// see (matching or not) - surfaced in the UI so a real connection can
    /// actually be debugged against real traffic instead of guessing blind.
    @Published private(set) var debugLog: [String] = []

    private var connection: NWConnection?
    private var host: String?
    private var port: UInt16 = GvretProtocol.tcpPort
    private var userInitiatedDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private let parser = GvretProtocol.FrameParser()

    /// Frames matching whatever ID the caller is currently waiting for are
    /// delivered here; anything else observed on the bus is just dropped -
    /// this app only cares about the one ECU conversation at a time.
    private var pendingFrameContinuation: CheckedContinuation<[UInt8]?, Never>?
    private var pendingFrameRxID: UInt32?
    private var pendingTimeoutTask: Task<Void, Never>?

    // A TCP read can contain several complete CAN frames. In particular, a
    // multi-frame ISO-TP response can deliver the First Frame and one or more
    // Consecutive Frames in the same TCP callback. The old implementation
    // dropped a matching frame whenever no continuation was installed yet,
    // which made VIN and other multi-frame UDS reads time out. Keep a small
    // per-ID queue so frames are never lost between ISO-TP receive steps.
    private var receivedFrameQueues: [UInt32: [[UInt8]]] = [:]
    private let maxQueuedFramesPerID = 32

    /// The txID of the request currently in flight - needed so that
    /// waitForResponse (used for NRC 0x78 "response pending" retries, where
    /// no new request goes out) can still correctly send Flow Control back
    /// to the ECU on the right ID if the eventual real answer turns out to
    /// be multi-frame. Without this, a 0x78-then-multiframe-response
    /// sequence would send FC on the wrong CAN ID and stall.
    private var pendingFrameTxID: UInt32?

    /// HSL uses one long ISO-TP transaction at a time. A second Start tap must
    /// never interleave its First/Consecutive Frames with the first transaction.
    private var hslRequestInFlight = false

    private lazy var isoTp = IsoTpSession(
        sendFrame: { [weak self] id, data in try await self?.sendCanFrame(id: id, data: data) },
        receiveFrame: { [weak self] timeout in try await self?.receiveCanFrame(matching: self?.pendingFrameRxID ?? 0, timeoutSeconds: timeout) }
    )

    enum GvretError: Error, LocalizedError {
        case notReady, disconnected, timeout
        var errorDescription: String? {
            switch self {
            case .notReady: return "Not connected to the Macchina A0 yet."
            case .disconnected: return "Macchina A0 disconnected."
            case .timeout: return "No response from the ECU (timed out)."
            }
        }
    }

    func connect(host: String, port: UInt16 = GvretProtocol.tcpPort) {
        reconnectTask?.cancel()
        reconnectTask = nil
        userInitiatedDisconnect = false
        self.host = host
        self.port = port
        parser.reset()
        receivedFrameQueues.removeAll()
        state = .connecting
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 23, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.startReceiving()
                    await self.setup()
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .disconnected
                    self.resumePendingReceive()
                    self.scheduleReconnectIfNeeded()
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        state = .disconnected
        pendingFrameContinuation?.resume(returning: nil)
        pendingFrameContinuation = nil
        pendingTimeoutTask?.cancel()
        receivedFrameQueues.removeAll()
    }

    private func setup() async {
        log("Sending binary-mode handshake (0xE7 0xE7)")
        do {
            try await rawWrite(GvretProtocol.binaryModeHandshake, label: "GVRET handshake")
        } catch {
            failConnection("GVRET handshake send failed: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Match real SavvyCAN's exact init preamble before doing anything
        // else ("Write to serial -> e7 e7 f1 c f1 6 f1 7 f1 1 f1 9" from
        // observed SavvyCAN traffic) - GET_NUM_BUSES, GET_CANBUS_PARAMS,
        // GET_DEV_INFO, TIME_SYNC, KEEPALIVE. Deviating from what the
        // reference client actually does risks hitting an uninitialized
        // code path in firmware internals this app can't see from source
        // alone, so this mirrors it exactly rather than skip straight to
        // SETUP_CANBUS as an earlier version of this code did.
        log("Sending SavvyCAN-style init preamble (GET_NUM_BUSES, GET_CANBUS_PARAMS, GET_DEV_INFO, TIME_SYNC, KEEPALIVE)")
        do {
            try await rawWrite(GvretProtocol.getNumBusesCommand(), label: "GET_NUM_BUSES")
            try await rawWrite([GvretProtocol.commandPrefix, GvretProtocol.Command.getCanbusParams.rawValue], label: "GET_CANBUS_PARAMS")
            try await rawWrite(GvretProtocol.getDevInfoCommand(), label: "GET_DEV_INFO")
            try await rawWrite([GvretProtocol.commandPrefix, GvretProtocol.Command.timeSync.rawValue], label: "TIME_SYNC")
            try await rawWrite(GvretProtocol.keepAliveCommand(), label: "KEEPALIVE")
        } catch {
            failConnection("GVRET init send failed: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Do not reconfigure CAN0 here. The A0 already reports its active CAN0
        // configuration in GET_CANBUS_PARAMS, and SavvyCAN's working connection
        // sequence does not issue SETUP_CANBUS. Reinitializing CAN0 from the
        // phone can interrupt the A0's existing receive stream.
        log("A0RET CAN0 configuration left unchanged (using reported CAN0 settings)")
        log("GVRET parser: A0RET RX enabled (F1 00 + timestamp[4] + ID[4] + len/bus + data + checksum; invalid DLC resync enabled)")
        log("Setup complete - ready")
        state = .ready
    }

    private func resumePendingReceive() {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        if let cont = pendingFrameContinuation {
            pendingFrameContinuation = nil
            cont.resume(returning: nil)
        }
    }

    private func scheduleReconnectIfNeeded() {
        guard !userInitiatedDisconnect, let host else { return }
        guard reconnectTask == nil else { return }
        log("GVRET disconnected - attempting automatic reconnect to \(host):\(port) in 1.0s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, !self.userInitiatedDisconnect else { return }
            self.reconnectTask = nil
            self.connect(host: host, port: self.port)
        }
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog.append("[\(timestamp)] \(message)")
        if debugLog.count > 500 { debugLog.removeFirst(debugLog.count - 500) }
    }

    // MARK: UdsTransport

    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double = 5.0) async throws -> Data {
        guard state == .ready else { throw GvretError.notReady }
        pendingFrameRxID = UInt32(rxID)
        pendingFrameTxID = UInt32(txID)
        log("UDS request: TX=0x\(String(txID, radix: 16, uppercase: true)) RX=0x\(String(rxID, radix: 16, uppercase: true)) payload=\(hexString([UInt8](payload)))")
        try await isoTp.send([UInt8](payload), txID: UInt32(txID), timeoutSeconds: timeoutSeconds)
        let response = try await isoTp.receive(rxID: UInt32(rxID), txID: UInt32(txID), timeoutSeconds: timeoutSeconds)
        log("UDS response: RX=0x\(String(rxID, radix: 16, uppercase: true)) payload=\(hexString(response))")
        return Data(response)
    }

    /// HSL uses the normal ISO-TP transport underneath the proprietary 0x3E
    /// application service.  The important detail is that the CAN frame seen
    /// on GVRET still contains the ISO-TP PCI byte. For example, the ECU
    /// acknowledgement arrives as:
    ///
    ///     03 7E 00 31 AA AA AA AA
    ///
    /// The `03` is the ISO-TP single-frame length, not part of the HSL
    /// response.  SimosTools' `sendRaw()/wait_frame()` path returns the
    /// de-framed UDS payload, so GET Mobile must do the same by using the
    /// existing IsoTpSession for both transmit and receive. This also allows
    /// HSL samples larger than one CAN frame to be received correctly.
    func sendHslRequest(_ payload: Data, expectedPayloadBytes: Int, timeoutSeconds: Double = 2.0) async throws -> Data {
        guard state == .ready else { throw GvretError.notReady }
        guard !hslRequestInFlight else { throw GvretHslError.requestBusy }
        hslRequestInFlight = true
        defer { hslRequestInFlight = false }
        pendingFrameRxID = UInt32(BridgeProtocol.simos18ResponseID)
        pendingFrameTxID = UInt32(BridgeProtocol.simos18RequestID)
        log("HSL ISO-TP request: TX=0x7E0 RX=0x7E8 payload=\(hexString([UInt8](payload))) expected=\(expectedPayloadBytes) bytes")

        // HSL is intentionally isolated from the normal UDS ISO-TP sender.
        // The patched HSL backend can advertise BS=2 (30 00 02) but then expects
        // the complete request to continue without another FC. Honoring that BS
        // literally makes the logger stop after the first two CFs and report a
        // timeout. Normal UDS traffic still uses the standards-compliant sender.
        try await isoTp.sendHsl([UInt8](payload), txID: UInt32(BridgeProtocol.simos18RequestID), timeoutSeconds: timeoutSeconds)
        let response = try await isoTp.receive(
            rxID: UInt32(BridgeProtocol.simos18ResponseID),
            txID: UInt32(BridgeProtocol.simos18RequestID),
            timeoutSeconds: timeoutSeconds
        )

        log("HSL ISO-TP response: \(hexString(response))")

        // Some A0/GVRET paths hand the CAN payload to this specialized HSL
        // method before the ISO-TP single-frame PCI byte has been removed.
        // A valid HSL acknowledgement can therefore arrive as:
        //   03 7E 00 31 AA AA AA AA
        // where 03 is the ISO-TP single-frame length and 7E 00 31 is the
        // actual UDS/HSL payload. Normalize that form here so HSL does not
        // depend on which layer happened to consume the PCI byte.
        var normalized = response
        if response.count >= 2, response[0] == 0x03, response[1] == 0x7E {
            normalized = Array(response.dropFirst())
            log("HSL normalized ISO-TP single-frame PCI: \(hexString(normalized))")
        }

        guard normalized.first == 0x7E else {
            throw GvretHslError.unexpectedAck(hexString(response))
        }
        return Data(normalized)
    }

    enum GvretHslError: Error, LocalizedError {
        case requestBusy
        case unexpectedAck(String)
        var errorDescription: String? {
            switch self {
            case .requestBusy:
                return "HSL request already in progress; waiting for the existing ISO-TP transaction to finish."
            case .unexpectedAck(let value): return "HSL ECU did not return the expected 0x7E acknowledgement: \(value)"
            }
        }
    }

    func waitForResponse(timeoutSeconds: Double = 5.0) async throws -> Data {
        // NRC 0x78 (response pending) retries: wait for the next full
        // ISO-TP message on the same rxID/txID pair as the original
        // request - no new request goes out, but we still need the right
        // txID in case the eventual real answer is multi-frame and Flow
        // Control needs to go back to the ECU.
        guard let rxID = pendingFrameRxID, let txID = pendingFrameTxID else { throw GvretError.notReady }
        let response = try await isoTp.receive(rxID: rxID, txID: txID, timeoutSeconds: timeoutSeconds)
        return Data(response)
    }

    // MARK: Raw CAN frame send/receive (used by IsoTpSession)

    private func sendCanFrame(id: UInt32, data: [UInt8]) async throws {
        guard connection != nil else { throw GvretError.notReady }
        log("TX CAN id=0x\(String(id, radix: 16, uppercase: true)) data=\(hexString(data))")
        let frame = GvretProtocol.CanFrame(id: id, extended: false, bus: 0, data: data)
        let bytes = GvretProtocol.buildCanFrameCommand(frame)
        try await rawWrite(bytes, label: "CAN 0x\(String(id, radix: 16, uppercase: true))")
    }

    /// Sends the exact 8-byte diagnostic frame used to isolate A0 CAN TX:
    /// CAN 0x7E0, payload 03 22 20 2A AA AA AA AA. This deliberately bypasses
    /// ISO-TP so SavvyCAN and GET Mobile can be compared byte-for-byte.
    func sendRawCanDiagnosticTest() async {
        guard state == .ready else {
            log("RAW CAN TEST: transport is not ready")
            return
        }

        let payload: [UInt8] = [0x03, 0x22, 0x20, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA]
        do {
            let frame = GvretProtocol.CanFrame(id: 0x7E0, extended: false, bus: 0, data: payload)
            let bytes = GvretProtocol.buildCanFrameCommand(frame)
            log("RAW CAN TEST: sending 0x7E0 / 8 bytes: \(hexString(payload))")
            log("RAW CAN TEST GVRET bytes: \(hexString(bytes))")
            try await rawWrite(bytes, label: "RAW CAN TEST 0x7E0")
            log("RAW CAN TEST: TCP send accepted; watch for ECU response on 0x7E8")
        } catch {
            log("RAW CAN TEST: TCP send failed: \(error.localizedDescription)")
        }
    }

    private func receiveCanFrame(matching rxID: UInt32, timeoutSeconds: Double) async throws -> [UInt8]? {
        guard connection != nil else { throw GvretError.notReady }
        guard pendingFrameContinuation == nil else { throw GvretError.notReady }

        pendingFrameRxID = rxID

        // Consume a frame that arrived before the caller installed its
        // continuation (possible when several CAN frames were delivered in
        // one TCP read).
        if var queue = receivedFrameQueues[rxID], !queue.isEmpty {
            let frame = queue.removeFirst()
            receivedFrameQueues[rxID] = queue
            log("Consumed queued CAN frame id=0x\(String(rxID, radix: 16, uppercase: true)) data=\(hexString(frame))")
            return frame
        }

        log("Waiting up to \(timeoutSeconds)s for a CAN frame with id=0x\(String(rxID, radix: 16, uppercase: true))")
        return await withCheckedContinuation { continuation in
            self.pendingFrameContinuation = continuation
            self.pendingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let cont = self.pendingFrameContinuation {
                    self.pendingFrameContinuation = nil
                    self.log("Timed out waiting for id=0x\(String(rxID, radix: 16, uppercase: true)) - no matching frame arrived in \(timeoutSeconds)s")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func rawWrite(_ bytes: [UInt8], label: String) async throws {
        guard let connection else { throw GvretError.notReady }

        log("TX GVRET [\(label)]: \(hexString(bytes))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        log("TX GVRET [\(label)]: TCP send accepted")
    }

    private func failConnection(_ message: String) {
        log(message)
        state = .failed(message)
        connection?.cancel()
        connection = nil
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.log("RX raw bytes [\(data.count)]: \(self.hexString([UInt8](data)))")
                    for byte in data {
                        if let frame = self.parser.feed(byte) {
                            self.log("RX CAN id=0x\(String(frame.id, radix: 16, uppercase: true)) data=\(self.hexString(frame.data))" +
                                     (frame.id == self.pendingFrameRxID ? " (matches what we're waiting for)" : " (not what we're waiting for - ignored)"))
                            self.handleIncomingFrame(frame)
                        }
                    }
                }
                if error == nil, !isComplete {
                    self.startReceiving()
                } else if isComplete {
                    self.log("Connection closed by remote side")
                    self.state = .disconnected
                    self.resumePendingReceive()
                    self.scheduleReconnectIfNeeded()
                } else if let error {
                    self.log("GVRET receive error: \(error.localizedDescription)")
                    self.state = .disconnected
                    self.resumePendingReceive()
                    self.scheduleReconnectIfNeeded()
                }
            }
        }
    }

    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func handleIncomingFrame(_ frame: GvretProtocol.CanFrame) {
        guard let expectedID = pendingFrameRxID, frame.id == expectedID else { return }

        if let cont = pendingFrameContinuation {
            pendingFrameContinuation = nil
            pendingTimeoutTask?.cancel()
            cont.resume(returning: frame.data)
            return
        }

        var queue = receivedFrameQueues[frame.id, default: []]
        if queue.count >= maxQueuedFramesPerID {
            queue.removeFirst()
            log("RX queue full for 0x\(String(frame.id, radix: 16, uppercase: true)); dropping oldest queued frame")
        }
        queue.append(frame.data)
        receivedFrameQueues[frame.id] = queue
        log("Queued CAN frame id=0x\(String(frame.id, radix: 16, uppercase: true)) for the next ISO-TP receive step")
    }
}
