import CoreBluetooth

/// Talks to an ELM327 Bluetooth dongle over BLE.
///
/// Read this before wiring up hardware: iOS's CoreBluetooth framework can
/// only talk to Bluetooth **Low Energy** devices. Most cheap ELM327
/// Bluetooth dongles use classic Bluetooth (SPP) instead, which iOS
/// third-party apps cannot access at all without Apple's MFi certification -
/// no code fix is possible for that case, it's a hard platform restriction.
/// This transport only has a chance of working if your dongle is
/// specifically a BLE ("Bluetooth 4.0/LE", often advertised as
/// "iOS compatible") variant.
///
/// Unlike the ESP32 bridge (one documented protocol, verified from its own
/// firmware source) or ELM327-WiFi (plain TCP, no ambiguity), there is no
/// single standard for how BLE ELM327 clones expose their serial link over
/// GATT. This tries the two schemes that cover the large majority of clones:
///   - Nordic UART Service (many CC2541/nRF-based boards)
///   - "HM-10 style" (0xFFE0/0xFFE1 - many cheap generic BLE-serial modules)
/// If your specific dongle uses neither, it won't connect - that's a sign
/// we need its exact service/characteristic UUIDs to add a third scheme.
@MainActor
final class Elm327BluetoothManager: NSObject, ObservableObject, UdsTransport {
    @Published private(set) var state: BridgeConnectionState = .disconnected
    @Published private(set) var discoveredPeripherals: [CBPeripheral] = []

    // Nordic UART Service
    private static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let nusRxWrite  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // phone writes here
    private static let nusTxNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // dongle notifies here

    // "HM-10 style" - single characteristic used for both directions
    private static let hm10Service = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    private static let hm10Char    = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var lineBuffer = Data()
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
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

    func startScan() {
        guard central.state == .poweredOn else { return }
        discoveredPeripherals.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [Self.nusService, Self.hm10Service], options: nil)
    }

    func stopScan() { central.stopScan() }

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        state = .connecting
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        cleanup()
    }

    private func cleanup() {
        peripheral = nil; writeChar = nil; notifyChar = nil
        state = .disconnected
        pendingContinuation?.resume(throwing: Elm327Error.disconnected)
        pendingContinuation = nil
        pendingTimeoutTask?.cancel()
    }

    // MARK: UdsTransport

    func sendRequest(rxID: UInt16, txID: UInt16, payload: Data, timeoutSeconds: Double = 2.0) async throws -> Data {
        guard state == .ready else { throw Elm327Error.notReady }
        let raw = try await sendLine(Elm327Protocol.requestLine(for: payload), timeoutSeconds: timeoutSeconds)
        guard let data = Elm327Protocol.extractUdsResponse(from: raw) else { throw Elm327Error.malformedResponse }
        return data
    }

    private func sendLine(_ line: String, timeoutSeconds: Double) async throws -> String {
        guard let writeChar, let p = peripheral else { throw Elm327Error.notReady }
        guard pendingContinuation == nil else { throw Elm327Error.notReady }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            let data = Data(line.utf8)
            let mtu = p.maximumWriteValueLength(for: .withoutResponse)
            // BLE UART modules generally expect the same MTU-chunking any
            // BLE write does - chunk defensively rather than assume the
            // whole command fits in one write.
            var offset = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                p.writeValue(data.subdata(in: offset..<end), for: writeChar, type: .withoutResponse)
                offset = end
            }
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

    private func runSetupSequence() async {
        for cmd in Elm327Protocol.setupCommands {
            _ = try? await sendLine(Elm327Protocol.command(cmd), timeoutSeconds: 3.0)
            if cmd == "ATZ" { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        state = .ready
    }
}

extension Elm327BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { state = .disconnected }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusService, Self.hm10Service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Failed to connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanup()
    }
}

extension Elm327BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            state = .failed("No recognized BLE-UART service found on this device - it may use classic Bluetooth (not supported) or a scheme this app doesn't know yet.")
            return
        }
        for service in services {
            if service.uuid == Self.nusService {
                peripheral.discoverCharacteristics([Self.nusRxWrite, Self.nusTxNotify], for: service)
            } else if service.uuid == Self.hm10Service {
                peripheral.discoverCharacteristics([Self.hm10Char], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case Self.nusRxWrite:
                writeChar = c
            case Self.nusTxNotify:
                notifyChar = c
                peripheral.setNotifyValue(true, for: c)
            case Self.hm10Char:
                // HM-10 style modules use one characteristic for both directions.
                writeChar = c
                notifyChar = c
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
        if writeChar != nil, notifyChar != nil {
            Task { await runSetupSequence() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        lineBuffer.append(data)
        if let promptIdx = lineBuffer.firstIndex(of: UInt8(ascii: ">")) {
            let responseData = lineBuffer.prefix(upTo: promptIdx)
            lineBuffer.removeSubrange(...promptIdx)
            let text = String(data: responseData, encoding: .ascii) ?? ""
            pendingTimeoutTask?.cancel()
            if let cont = pendingContinuation {
                pendingContinuation = nil
                cont.resume(returning: text)
            }
        }
    }
}
