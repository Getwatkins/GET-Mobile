import SwiftUI

/// The main "MQB Gauges" screen once connected - mirrors the Windows app's
/// gauge strip + DID slot grid, just in a single scrolling column suited to
/// a phone/tablet rather than a desktop window.
struct GaugesView: View {
    @ObservedObject var session: GaugeSessionViewModel
    @Binding var demoModeActive: Bool
    let transport: UdsTransport?
    let onDisconnect: () -> Void

    @StateObject private var flashSession = FlashSessionViewModel()
    @State private var showFlashView = false
    @State private var showGvretLog = false
    @State private var showBridgeLog = false
    @State private var showDatalog = false
    @State private var showDidLog = false
    @StateObject private var hslLogger = HslLoggerSession()
    @StateObject private var didLogger = DidLoggerSession()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if session.isDemoMode {
                    Text("DEMO MODE — values are simulated, not from a real ECU")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(GETTheme.amber)
                }

                HStack(spacing: 12) {
                    Button(action: session.readOnce) {
                        Text("Read Once").bold()
                            .frame(maxWidth: .infinity).padding(10)
                            .background(GETTheme.gold).foregroundColor(.black).cornerRadius(6)
                    }
                    Button(action: session.isLive ? session.stopLive : session.startLive) {
                        Text(session.isLive ? "Stop Live" : "Start Live").bold()
                            .frame(maxWidth: .infinity).padding(10)
                            .background(session.isLive ? GETTheme.warningRed : GETTheme.amber)
                            .foregroundColor(.black).cornerRadius(6)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 8) {
                    Text("Gauge style:").foregroundColor(.gray).font(.system(size: 13))
                    Toggle(session.isDigitalStyle ? "Digital" : "Needle", isOn: $session.isDigitalStyle)
                        .toggleStyle(.button)
                        .tint(GETTheme.amber)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(GETTheme.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.border, lineWidth: 1))
                .cornerRadius(6)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(session.slots) { slot in
                        GaugeSlotCardView(slot: slot, session: session, isDigitalStyle: session.isDigitalStyle)
                    }
                }
                .padding(.horizontal)

                if let error = session.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(GETTheme.warningRed)
                        .padding(.horizontal)
                }

                if let transport, !session.isDemoMode {
                    Button {
                        // Acquire the HSL ownership lock BEFORE presenting the logger.
                        // This closes the small SwiftUI presentation window in which
                        // another view update could restart normal gauge polling.
                        session.beginHslLogging()
                        showDatalog = true
                    } label: {
                        Label("HSL Datalogger", systemImage: "waveform.path.ecg")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(GETTheme.amber)
                            .foregroundColor(.black)
                            .cornerRadius(6)
                    }
                    .padding(.horizontal)
                    .fullScreenCover(isPresented: $showDatalog) {
                        DatalogView(logger: hslLogger, gaugeSession: session, transport: transport)
                    }

                    Button {
                        // Same ownership lock as HSL Datalogger, reused as-is: it's
                        // really "exclusive polling ownership," not HSL-specific,
                        // and this logger races on the exact same shared transport
                        // normal Live gauge polling does.
                        session.beginHslLogging()
                        showDidLog = true
                    } label: {
                        Label("Standard Logger (CSV)", systemImage: "tablecells")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.amber)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.amber, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .padding(.horizontal)
                    .fullScreenCover(isPresented: $showDidLog) {
                        DidLoggerView(logger: didLogger, gaugeSession: session, transport: transport)
                    }

                    Button {
                        session.stopLive()
                        showFlashView = true
                    } label: {
                        Label("Flash ECU", systemImage: "bolt.fill")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(GETTheme.warningRed)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .padding(.horizontal)
                    .fullScreenCover(isPresented: $showFlashView) {
                        FlashView(session: flashSession, transport: transport, onDone: { showFlashView = false })
                    }
                }

                if let gvret = transport as? GvretWifiManager {
                    Button {
                        showGvretLog = true
                    } label: {
                        Label("GVRET Diagnostic Log", systemImage: "list.bullet.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.amber)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.amber, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .padding(.horizontal)
                    .sheet(isPresented: $showGvretLog) {
                        GvretDebugLogView(manager: gvret)
                    }
                }

                if let bridge = transport as? BridgeManager {
                    Button {
                        showBridgeLog = true
                    } label: {
                        Label("Bridge Diagnostic Log", systemImage: "list.bullet.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(GETTheme.panelBackground)
                            .foregroundColor(GETTheme.amber)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.amber, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .padding(.horizontal)
                    .sheet(isPresented: $showBridgeLog) {
                        BridgeDebugLogView(manager: bridge)
                    }
                }

                Button(session.isDemoMode ? "Exit Demo Mode" : "Disconnect", role: .destructive) {
                    session.stopLive()
                    if session.isDemoMode {
                        session.isDemoMode = false
                        demoModeActive = false
                    } else {
                        onDisconnect()
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(GETTheme.background.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image("LogoBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220)
                .padding(.top, 12)
            Text("MQB Gauges")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(GETTheme.gold)
        }
    }
}
