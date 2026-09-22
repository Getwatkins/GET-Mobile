import SwiftUI

/// The screen shown right after connecting (or entering demo mode) - picks
/// between the three main features instead of dumping everything onto one
/// long scrolling gauges screen. Each button pushes onto the shared nav
/// path, so the system back arrow returns here from any depth.
struct HomeMenuView: View {
    @ObservedObject var session: GaugeSessionViewModel
    @Binding var demoModeActive: Bool
    let transport: UdsTransport?
    let onDisconnect: () -> Void
    @Binding var path: [HomeRoute]

    @State private var showGvretLog = false
    @State private var showBridgeLog = false

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

                VStack(spacing: 12) {
                    homeCard(title: "Gauges", subtitle: "Live dials and readouts", systemImage: "gauge.with.dots.needle.67percent", tint: GETTheme.amber) {
                        path.append(.gauges)
                    }

                    homeCard(title: "Logging", subtitle: "HSL or standard CSV datalogging", systemImage: "waveform.path.ecg", tint: GETTheme.gold) {
                        path.append(.logging)
                    }

                    if transport != nil, !session.isDemoMode {
                        homeCard(title: "Flash ECU", subtitle: "Read/write ECU firmware", systemImage: "bolt.fill", tint: GETTheme.warningRed) {
                            session.stopLive()
                            path.append(.flash)
                        }
                    }
                }
                .padding(.horizontal)

                diagnosticsLinks

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

    private func homeCard(title: String, subtitle: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundColor(tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding(16)
            .background(GETTheme.panelBackground)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var diagnosticsLinks: some View {
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
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image("LogoBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220)
                .padding(.top, 12)
            Text("GET Mobile")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(GETTheme.gold)
        }
    }
}
