import Foundation
import Combine

/// Single owner of every long-lived session/transport object.
///
/// These used to be @StateObjects inside ContentView, which meant they only
/// existed while the phone's SwiftUI scene did. CarPlay runs in its own
/// UIScene (and can be launched with no phone window at all), so it needs to
/// talk to the *same* transport and sessions the phone UI uses - one ECU
/// connection, one owner. ContentView and the CarPlay scene both read this
/// singleton, so a connection made on the phone shows up in the car and vice
/// versa.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let bridge = BridgeManager()
    let elm327Wifi = Elm327WifiManager()
    let elm327Bluetooth = Elm327BluetoothManager()
    let gvretWifi = GvretWifiManager()
    let session = GaugeSessionViewModel()
    let flashSession = FlashSessionViewModel()
    let hslLogger = HslLoggerSession()
    let didLogger = DidLoggerSession()
    let diagnostics = DiagnosticsSession()

    @Published var activeKind: ConnectionKind?
    @Published var demoModeActive = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // ContentView observes only AppModel, so forward every child's
        // change notification (this matches what the nine @StateObjects
        // did before: any child change re-evaluated ContentView).
        subscribe(to: bridge)
        subscribe(to: elm327Wifi)
        subscribe(to: elm327Bluetooth)
        subscribe(to: gvretWifi)
        subscribe(to: session)
        subscribe(to: flashSession)
        subscribe(to: hslLogger)
        subscribe(to: didLogger)
        subscribe(to: diagnostics)
    }

    private func subscribe<O: ObservableObject>(to child: O) {
        child.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Connection state (shared by phone UI and CarPlay)

    var isConnectedReady: Bool {
        switch activeKind {
        case .esp32Bridge: return bridge.state == .ready
        case .elm327Wifi: return elm327Wifi.state == .ready
        case .elm327Bluetooth: return elm327Bluetooth.state == .ready
        case .gvretWifi: return gvretWifi.state == .ready
        case .none: return false
        }
    }

    /// nil in demo mode (no real hardware) or before any transport connects.
    var activeTransport: UdsTransport? {
        switch activeKind {
        case .esp32Bridge: return bridge
        case .elm327Wifi: return elm327Wifi
        case .elm327Bluetooth: return elm327Bluetooth
        case .gvretWifi: return gvretWifi
        case .none: return nil
        }
    }

    var connectionLabel: String {
        if demoModeActive { return "Demo mode" }
        guard isConnectedReady else { return "Not connected" }
        switch activeKind {
        case .esp32Bridge: return "ESP32 bridge"
        case .elm327Wifi: return "ELM327 Wi-Fi"
        case .elm327Bluetooth: return "ELM327 Bluetooth"
        case .gvretWifi: return "GVRET Wi-Fi"
        case .none: return "Not connected"
        }
    }

    func disconnectActive() {
        session.stopLive()
        diagnostics.reset()
        session.detach()
        switch activeKind {
        case .esp32Bridge: bridge.disconnect()
        case .elm327Wifi: elm327Wifi.disconnect()
        case .elm327Bluetooth: elm327Bluetooth.disconnect()
        case .gvretWifi: gvretWifi.disconnect()
        case .none: break
        }
        activeKind = nil
        demoModeActive = false
        session.isDemoMode = false
    }
}
