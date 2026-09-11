import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = BridgeManager()
    @StateObject private var elm327Wifi = Elm327WifiManager()
    @StateObject private var elm327Bluetooth = Elm327BluetoothManager()
    @StateObject private var gvretWifi = GvretWifiManager()
    @StateObject private var session = GaugeSessionViewModel()

    @State private var demoModeActive = false
    @State private var activeKind: ConnectionKind?

    private var isConnectedReady: Bool {
        switch activeKind {
        case .esp32Bridge: return bridge.state == .ready
        case .elm327Wifi: return elm327Wifi.state == .ready
        case .elm327Bluetooth: return elm327Bluetooth.state == .ready
        case .gvretWifi: return gvretWifi.state == .ready
        case .none: return false
        }
    }

    /// nil in demo mode (there's no real hardware to flash against) or
    /// before any transport has connected.
    private var activeTransport: UdsTransport? {
        switch activeKind {
        case .esp32Bridge: return bridge
        case .elm327Wifi: return elm327Wifi
        case .elm327Bluetooth: return elm327Bluetooth
        case .gvretWifi: return gvretWifi
        case .none: return nil
        }
    }

    var body: some View {
        Group {
            if isConnectedReady || demoModeActive || activeKind != nil {
                GaugesView(session: session, demoModeActive: $demoModeActive, transport: activeTransport, onDisconnect: disconnectActive)
            } else {
                TransportPickerView(
                    bridge: bridge,
                    elm327Wifi: elm327Wifi,
                    elm327Bluetooth: elm327Bluetooth,
                    gvretWifi: gvretWifi,
                    onConnected: { kind, transport in
                        activeKind = kind
                        session.isDemoMode = false
                        session.attach(transport: transport)
                        // Do not auto-start live polling. Keep the transport idle after
                        // connection so HSL logging and flashing can exclusively own the
                        // ECU session. The user can tap Start Live when desired.
                        session.stopLive()
                    },
                    onPreviewDemo: {
                        session.isDemoMode = true
                        session.fillBlankSlotsForDemo()
                        session.stopLive()
                        demoModeActive = true
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func disconnectActive() {
        session.stopLive()
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

#Preview {
    ContentView()
}
