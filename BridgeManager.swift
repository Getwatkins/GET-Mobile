import CoreBluetooth
import Combine

enum BridgeConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case ready          // connected, characteristics discovered, notifications subscribed
    case failed(String)
}

/// Talks to one esp32-isotp-ble-bridge device over CoreBluetooth. This is
/// the mobile equivalent of the Windows app's J2534 UdsClient - it doesn't
/// know anything about individual DIDs, just "send these bytes to this CAN
/// ID, give me back the bytes the ECU replied with."
///
/// Pinned to the main actor: CBCentralManager's delegate queue is set to
/// .main below, so all CoreBluetooth callbacks already land on the main
/// thread - @MainActor just makes that explicit for the compiler and
/// matches the MainActor-isolated view models that call into this.
@MainActor
final class BridgeManager: NSObject, ObservableObject, UdsTransport {
    @Published private(set) var state: BridgeConnectionState = .disconnected
    @Published private(set) var discoveredNames: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataReceiveChar: CBCharacteristic?
    private var dataNotifyChar: CBCharacteristic?
    private var commandReceiveChar: CBCharacteristic?
    private var commandNotifyChar: CBCharacteristic?

    private var attMTU: Int = 20 // conservative default until negotiated (BLE 4.x minimum payload)
    private let reassembler = BridgeFrameReassembler()

    /// Requests awaiting a matching response, keyed by the rxID they expect
    /// a reply on. Simos18 reads are strictly request/response (one
    /// outstanding read at a time in this app), so this is intentionally simple.
    private var pendingContinuation: CheckedContinuation<Data, Error>?
    private var pendingTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Scanning / connecting

    func startScan() {
        guard central.state == .poweredOn else { return }
        discoveredNames.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [BridgeProtocol.serviceUUID], options: nil)
    }

    func stopScan() {
        central.stopScan()
    }

    /// Connects to the first bridge seen advertising the service UUID.
    /// Real usage will want to let the person pick from `discoveredNames`
    /// if more than one bridge is nearby; wired up simply here to start.
    private var seenPeripherals: [CBPeripheral] = []

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        state = .connecting
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        cleanupAfterDisconnect()
    }

    private func cleanupAfterDisconnect() {
        peripheral = nil
        dataReceiveChar = nil; dataNotifyChar = nil
        commandReceiveChar = nil; commandNotifyChar = nil
        state = .disconnected
        pendingContinuation?.resume(throwing: BridgeError.disconnected)
        pendingContinuation = nil
        pendingTimeoutTask?.cancel()
    }

    // MARK: Sending a UDS request and awaiting the response

    enum BridgeError: Error, LocalizedError {
        case notReady
        case disconnected
        case timeout
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "Not connected to a bridge yet."
            case .disconnected: return "Bridge disconnected."
            case .timeout: return "No response from the ECU (timed out)."
            case .malformedResponse: return "Bridge sent back something unexpected."
            }
        }
    }

    /// Sends `payload` (e.g. a UDS request like [0x22, DIDhi, DIDlo]) on
    /// `txID` and waits for the reassembled reply expected on `rxID`.
    /// Only one request is allowed in flight at a time - matches how the
    /// existing Windows app's UdsClient works (one blocking request/response
    /// per DID read).
    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double = 2.0) async throws -> Data {
        guard state == .ready, let char = dataReceiveChar, let p = peripheral else {
            throw BridgeError.notReady
        }
        guard pendingContinuation == nil else {
            throw BridgeError.notReady // a request is already in flight
        }

        let frames = BridgeFrameEncoder.buildFrames(rxID: rxID, txID: txID, cmdFlags: 0, payload: payload, attMTU: attMTU)
        for frame in frames {
            p.writeValue(frame, for: char, type: .withoutResponse)
        }

        return try await waitForResponse(timeoutSeconds: timeoutSeconds)
    }

    /// Waits for the next reassembled response without writing anything -
    /// used for ISO 14229 NRC 0x78 ("response pending") retries, where
    /// resending the request could make the ECU restart a slow in-progress
    /// operation instead of just continuing to wait for it.
    func waitForResponse(timeoutSeconds: Double = 2.0) async throws -> Data {
        guard state == .ready else { throw BridgeError.notReady }
        guard pendingContinuation == nil else { throw BridgeError.notReady }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            self.pendingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let cont = self.pendingContinuation {
                    self.pendingContinuation = nil
                    cont.resume(throwing: BridgeError.timeout)
                }
            }
        }
    }

    /// Best-effort password send on connect (see BridgeProtocol.defaultPassword
    /// doc comment - harmless no-op on firmware builds without password
    /// enforcement compiled in).
    private func sendDefaultPassword() {
        guard let char = commandReceiveChar, let p = peripheral else { return }
        let payload = Data(BridgeProtocol.defaultPassword.utf8)
        let frames = BridgeFrameEncoder.buildFrames(rxID: 0xFFFF, txID: 0xFFFF,
                                                     cmdFlags: BridgeProtocol.flagSettings | BridgeProtocol.flagSettingsGet,
                                                     payload: payload, attMTU: attMTU)
        for frame in frames { p.writeValue(frame, for: char, type: .withoutResponse) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BridgeManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { state = .disconnected }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !seenPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            seenPeripherals.append(peripheral)
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown bridge"
            discoveredNames.append(name)
        }
    }

    /// Exposes the raw peripherals for the UI layer to offer as a picker.
    var discoveredPeripherals: [CBPeripheral] { seenPeripherals }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BridgeProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanupAfterDisconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BridgeManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BridgeProtocol.serviceUUID }) else {
            state = .failed("Bridge service not found"); return
        }
        peripheral.discoverCharacteristics(
            [BridgeProtocol.dataReceiveUUID, BridgeProtocol.dataNotifyUUID,
             BridgeProtocol.commandReceiveUUID, BridgeProtocol.commandNotifyUUID],
            for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BridgeProtocol.dataReceiveUUID: dataReceiveChar = c
            case BridgeProtocol.dataNotifyUUID:
                dataNotifyChar = c
                peripheral.setNotifyValue(true, for: c)
            case BridgeProtocol.commandReceiveUUID: commandReceiveChar = c
            case BridgeProtocol.commandNotifyUUID:
                commandNotifyChar = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        attMTU = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3 // CoreBluetooth reports payload capacity; +3 to get back to "ATT MTU" terms matching the firmware's own accounting
        if dataReceiveChar != nil && dataNotifyChar != nil {
            state = .ready
            sendDefaultPassword()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        guard characteristic.uuid == BridgeProtocol.dataNotifyUUID else { return } // command-notify (password ack etc.) not wired to the read path

        if let (_, payload) = reassembler.feed(data) {
            pendingTimeoutTask?.cancel()
            if let cont = pendingContinuation {
                pendingContinuation = nil
                cont.resume(returning: payload)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Data Receive char is Write-Without-Response (firmware: char_prop_read_write = WRITE_NR|READ),
        // so this normally won't fire for our writes - present for completeness/future use.
    }
}
