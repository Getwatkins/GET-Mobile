import Foundation
import Network

/// Talks to an ELM327 WiFi dongle over a plain TCP socket. This is the
/// simplest and most reliable of the three transports - WiFi OBD dongles
/// just open a TCP server (almost universally on 192.168.0.10:35000, though
/// some clones default elsewhere), and there's no MFi/Bluetooth restriction
/// of any kind to worry about here.
@MainActor
final class Elm327WifiManager: NSObject, ObservableObject, UdsTransport {
    @Published private(set) var state: BridgeConnectionState = .disconnected

    private var connection: NWConnection?
    private var lineBuffer = Data()
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingTimeoutTask: Task<Void, Never>?

    func connect(host: String, port: UInt16) {
        state = .connecting
        let params = NWParameters.tcp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 35000, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.startReceiving()
                    await self.runSetupSequence()
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
        pendingContinuation?.resume(throwing: Elm327Error.disconnected)
        pendingContinuation = nil
        pendingTimeoutTask?.cancel()
    }

    enum Elm327Error: Error, LocalizedError {
        case notReady, disconnected, timeout, malformedResponse
        var errorDescription: String? {
            switch self {
            case .notReady: return "Not connected to the ELM327 dongle yet."
            case .disconnected: return "ELM327 dongle disconnected."
            case .timeout: return "No response from the adapter (timed out)."
            case .malformedResponse: return "Couldn't parse the adapter's response."
            }
        }
    }

    private func runSetupSequence() async {
        for cmd in Elm327Protocol.setupCommands {
            _ = try? await sendLine(Elm327Protocol.command(cmd), timeoutSeconds: 3.0)
            if cmd == "ATZ" { try? await Task.sleep(nanoseconds: 1_000_000_000) } // ELM327 needs a moment after reset
        }
        state = .ready
    }

    /// UdsTransport conformance - builds the hex request line, sends it, and
    /// extracts the UDS payload from whatever comes back. rxID/txID aren't
    /// used per-call here since ATSH/ATCRA are fixed once at setup (both are
    /// always 0x7E0/0x7E8 for Simos18 in this app), but kept in the
    /// signature to match the shared UdsTransport protocol.
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double = 2.0) async throws -> Data {
        guard state == .ready else { throw Elm327Error.notReady }
        let raw = try await sendLine(Elm327Protocol.requestLine(for: payload), timeoutSeconds: timeoutSeconds)
        guard let data = Elm327Protocol.extractUdsResponse(from: raw) else { throw Elm327Error.malformedResponse }
        return data
    }

    private func sendLine(_ line: String, timeoutSeconds: Double) async throws -> String {
        guard let connection else { throw Elm327Error.notReady }
        guard pendingContinuation == nil else { throw Elm327Error.notReady }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            connection.send(content: line.data(using: .ascii), completion: .contentProcessed { _ in })
            self.pendingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let cont = self.pendingContinuation {
                    self.pendingContinuation = nil
                    cont.resume(throwing: Elm327Error.timeout)
                }
            }
        }
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.lineBuffer.append(data)
                    // ELM327 signals "done with this response" via the '>' prompt character.
                    if let promptIdx = self.lineBuffer.firstIndex(of: UInt8(ascii: ">")) {
                        let responseData = self.lineBuffer.prefix(upTo: promptIdx)
                        self.lineBuffer.removeSubrange(...promptIdx)
                        let text = String(data: responseData, encoding: .ascii) ?? ""
                        self.pendingTimeoutTask?.cancel()
                        if let cont = self.pendingContinuation {
                            self.pendingContinuation = nil
                            cont.resume(returning: text)
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
}
