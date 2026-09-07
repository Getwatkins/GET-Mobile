import Foundation
import Network

/// Talks to a Macchina A0 running A0RET firmware in WiFi mode (the same
/// protocol SavvyCAN uses) over a plain TCP socket. Unlike the other 3
/// transports, this one has to do its own ISO-TP segmentation (see
/// IsoTp.swift) since A0RET only relays raw CAN frames.
@MainActor
final class GvretWifiManager: NSObject, ObservableObject, UdsTransport {
    @Published private(set) var state: BridgeConnectionState = .disconnected

    private var connection: NWConnection?
    private let parser = GvretProtocol.FrameParser()

    /// Frames matching whatever ID the caller is currently waiting for are
    /// delivered here; anything else observed on the bus is just dropped -
    /// this app only cares about the one ECU conversation at a time.
    private var pendingFrameContinuation: CheckedContinuation<[UInt8]?, Never>?
    private var pendingFrameRxID: UInt32?
    private var pendingTimeoutTask: Task<Void, Never>?

    /// The txID of the request currently in flight - needed so that
    /// waitForResponse (used for NRC 0x78 "response pending" retries, where
    /// no new request goes out) can still correctly send Flow Control back
    /// to the ECU on the right ID if the eventual real answer turns out to
    /// be multi-frame. Without this, a 0x78-then-multiframe-response
    /// sequence would send FC on the wrong CAN ID and stall.
    private var pendingFrameTxID: UInt32?

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
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .disconnected
        pendingFrameContinuation?.resume(returning: nil)
        pendingFrameContinuation = nil
        pendingTimeoutTask?.cancel()
    }

    private func setup() async {
        rawWrite(GvretProtocol.binaryModeHandshake)
        try? await Task.sleep(nanoseconds: 200_000_000)
        rawWrite(GvretProtocol.setupCanbusCommand(bus0Speed: 500_000, bus0Enabled: true))
        try? await Task.sleep(nanoseconds: 300_000_000) // let the firmware actually bring CAN0 up before we start using it
        state = .ready
    }

    // MARK: UdsTransport

    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double = 5.0) async throws -> Data {
        guard state == .ready else { throw GvretError.notReady }
        pendingFrameRxID = UInt32(rxID)
        pendingFrameTxID = UInt32(txID)
        try await isoTp.send([UInt8](payload), txID: UInt32(txID), timeoutSeconds: timeoutSeconds)
        let response = try await isoTp.receive(rxID: UInt32(rxID), txID: UInt32(txID), timeoutSeconds: timeoutSeconds)
        return Data(response)
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
        let frame = GvretProtocol.CanFrame(id: id, extended: false, bus: 0, data: data)
        rawWrite(GvretProtocol.buildCanFrameCommand(frame))
    }

    private func receiveCanFrame(matching rxID: UInt32, timeoutSeconds: Double) async throws -> [UInt8]? {
        guard connection != nil else { throw GvretError.notReady }
        guard pendingFrameContinuation == nil else { throw GvretError.notReady }

        pendingFrameRxID = rxID
        return await withCheckedContinuation { continuation in
            self.pendingFrameContinuation = continuation
            self.pendingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let cont = self.pendingFrameContinuation {
                    self.pendingFrameContinuation = nil
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func rawWrite(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    for byte in data {
                        if let frame = self.parser.feed(byte) {
                            self.handleIncomingFrame(frame)
                        }
                    }
                }
                if error == nil, !isComplete {
                    self.startReceiving()
                } else if isComplete {
                    self.state = .disconnected
                }
            }
        }
    }

    private func handleIncomingFrame(_ frame: GvretProtocol.CanFrame) {
        guard let expectedID = pendingFrameRxID, frame.id == expectedID else { return }
        guard let cont = pendingFrameContinuation else { return }
        pendingFrameContinuation = nil
        pendingTimeoutTask?.cancel()
        cont.resume(returning: frame.data)
    }
}
