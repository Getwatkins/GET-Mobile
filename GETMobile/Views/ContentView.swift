import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = BridgeManager()
    @StateObject private var elm327Wifi = Elm327WifiManager()
    @StateObject private var elm327Bluetooth = Elm327BluetoothManager()
    @StateObject private var gvretWifi = GvretWifiManager()
    @StateObject private var session = GaugeSessionViewModel()
    @StateObject private var flashSession = FlashSessionViewModel()
    @StateObject private var hslLogger = HslLoggerSession()
    @StateObject private var didLogger = DidLoggerSession()

    @State private var demoModeActive = false
    @State private var activeKind: ConnectionKind?
    @State private var path: [HomeRoute] = []

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
            if isConnectedReady || demoModeActive {
                NavigationStack(path: $path) {
                    HomeMenuView(
                        session: session,
                        demoModeActive: $demoModeActive,
                        transport: activeTransport,
                        onDisconnect: disconnectActive,
                        path: $path
                    )
                    .navigationDestination(for: HomeRoute.self) { route in
                        destination(for: route)
                    }
                }
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

    @ViewBuilder
    private func destination(for route: HomeRoute) -> some View {
        switch route {
        case .gauges:
            GaugesOnlyView(session: session)
        case .logging:
            if let transport = activeTransport {
                LoggingMenuView(session: session, transport: transport, path: $path)
            } else {
                EmptyView()
            }
        case .flash:
            if let transport = activeTransport {
                FlashView(session: flashSession, transport: transport, onDone: { path.removeLast() })
            } else {
                EmptyView()
            }
        case .diagnostics:
            if let transport = activeTransport {
                DiagnosticsView(gaugeSession: session, transport: transport)
            } else {
                EmptyView()
            }
        case .hslDatalog:
            if let transport = activeTransport {
                DatalogView(logger: hslLogger, gaugeSession: session, transport: transport)
            } else {
                EmptyView()
            }
        case .standardDatalog:
            if let transport = activeTransport {
                DidLoggerView(logger: didLogger, gaugeSession: session, transport: transport)
            } else {
                EmptyView()
            }
        }
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
        path.removeAll()
    }
}

#Preview {
    ContentView()
}
