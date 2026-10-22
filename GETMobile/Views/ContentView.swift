import SwiftUI

struct ContentView: View {
    // All sessions live in AppModel so the CarPlay scene shares them.
    @StateObject private var app = AppModel.shared

    @State private var path: [HomeRoute] = []

    private var bridge: BridgeManager { app.bridge }
    private var elm327Wifi: Elm327WifiManager { app.elm327Wifi }
    private var elm327Bluetooth: Elm327BluetoothManager { app.elm327Bluetooth }
    private var gvretWifi: GvretWifiManager { app.gvretWifi }
    private var session: GaugeSessionViewModel { app.session }
    private var flashSession: FlashSessionViewModel { app.flashSession }
    private var hslLogger: HslLoggerSession { app.hslLogger }
    private var didLogger: DidLoggerSession { app.didLogger }
    private var diagnostics: DiagnosticsSession { app.diagnostics }

    private var demoModeActive: Bool {
        get { app.demoModeActive }
        nonmutating set { app.demoModeActive = newValue }
    }
    private var activeKind: ConnectionKind? {
        get { app.activeKind }
        nonmutating set { app.activeKind = newValue }
    }
    private var isConnectedReady: Bool { app.isConnectedReady }
    private var activeTransport: UdsTransport? { app.activeTransport }

    var body: some View {
        Group {
            // Keep the active navigation stack alive while HSL owns the
            // transport. A temporary GVRET TCP reconnect must not throw the
            // user back to interface selection in the middle of HSL startup.
            let hslOwnsTransport = hslLogger.isStarting || hslLogger.isRunning || session.isHslActive
            if isConnectedReady || demoModeActive || hslOwnsTransport {
                NavigationStack(path: $path) {
                    HomeMenuView(
                        session: session,
                        demoModeActive: $app.demoModeActive,
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
        case .diagnostics:
            if let transport = activeTransport {
                DiagnosticsView(diag: diagnostics, gaugeSession: session, transport: transport)
            } else {
                EmptyView()
            }
        case .flash:
            if let transport = activeTransport {
                FlashView(session: flashSession, transport: transport, onDone: { path.removeLast() })
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
        app.disconnectActive()
        path.removeAll()
    }
}

#Preview {
    ContentView()
}
