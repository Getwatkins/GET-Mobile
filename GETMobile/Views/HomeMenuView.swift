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

    // Explicit, screen-derived sizing rather than aspect-ratio math: each
    // tile is exactly half the screen wide (so, with zero grid spacing,
    // all 4 tiles - 2 columns x 2 rows - butt up against each other and
    // both screen edges with no gaps) and a fixed fraction of the screen
    // tall, generous enough that content can never need more room than
    // it's given. That last part matters: the previous aspect-ratio-based
    // sizing computed height purely from width, and cornerRadius() clips
    // to that box - so "Diagnostics" (the longest title) could render
    // taller than the box once wrapped, and get its bottom sliced off.
    // A fixed height with real headroom means that can't happen.
    private var tileWidth: CGFloat { UIScreen.main.bounds.width / 2 }
    private var tileHeight: CGFloat { UIScreen.main.bounds.height * 0.30 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if session.isDemoMode {
                    Text("DEMO MODE — values are simulated, not from a real ECU")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(GETTheme.amber)
                }

                // Fixed-width columns matching tileWidth exactly (rather than
                // .flexible()) so there's no rounding gap between the two
                // columns or at the screen edges.
                LazyVGrid(columns: [GridItem(.fixed(tileWidth), spacing: 0), GridItem(.fixed(tileWidth), spacing: 0)], spacing: 0) {
                    tile(title: "Gauges", systemImage: "gauge.with.dots.needle.67percent", tint: GETTheme.amber) {
                        path.append(.gauges)
                    }

                    tile(title: "Logging", systemImage: "waveform.path.ecg", tint: GETTheme.gold) {
                        path.append(.logging)
                    }

                    if transport != nil, !session.isDemoMode {
                        tile(title: "Diagnostics", systemImage: "wrench.and.screwdriver", tint: GETTheme.gold) {
                            session.stopLive()
                            path.append(.diagnostics)
                        }

                        tile(title: "Flash ECU", systemImage: "bolt.fill", tint: GETTheme.warningRed) {
                            session.stopLive()
                            path.append(.flash)
                        }
                    }
                }

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
            .padding(.top, 12)
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("GET Mobile")
        .navigationBarTitleDisplayMode(.inline)
        .withTopLogo()
    }

    private func tile(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 56))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    // Forces the text to report (and get) its full needed
                    // height for however many lines it wraps to, instead of
                    // being squeezed/truncated by the layout around it.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .frame(width: tileWidth, height: tileHeight)
            .background(GETTheme.panelBackground)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.6), lineWidth: 1))
            .cornerRadius(4)
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
}
