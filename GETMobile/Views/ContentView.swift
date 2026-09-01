import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = BridgeManager()
    @StateObject private var elm327Wifi = Elm327WifiManager()
    @StateObject private var elm327Bluetooth = Elm327BluetoothManager()
    @StateObject private var session = GaugeSessionViewModel()

    @State private var demoModeActive = false
    @State private var activeKind: ConnectionKind?

    private var isConnectedReady: Bool {
        switch activeKind {
        case .esp32Bridge: return bridge.state == .ready
        case .elm327Wifi: return elm327Wifi.state == .ready
        case .elm327Bluetooth: return elm327Bluetooth.state == .ready
        case .none: return false
        }
    }

    var body: some View {
        Group {
            if isConnectedReady || demoModeActive {
                GaugesView(session: session, demoModeActive: $demoModeActive, onDisconnect: disconnectActive)
            } else {
                TransportPickerView(
                    bridge: bridge,
                    elm327Wifi: elm327Wifi,
                    elm327Bluetooth: elm327Bluetooth,
                    onConnected: { kind, transport in
                        activeKind = kind
                        session.attach(transport: transport)
                    },
                    onPreviewDemo: {
                        session.isDemoMode = true
                        session.fillBlankSlotsForDemo()
                        session.startLive()
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
