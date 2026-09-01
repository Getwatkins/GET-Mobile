import SwiftUI

/// The main "MQB Gauges" screen once connected - mirrors the Windows app's
/// gauge strip + DID slot grid, just in a single scrolling column suited to
/// a phone/tablet rather than a desktop window.
struct GaugesView: View {
    @ObservedObject var session: GaugeSessionViewModel
    @Binding var demoModeActive: Bool
    let onDisconnect: () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

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

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(session.slots) { slot in
                        GaugeSlotCardView(slot: slot, isDigitalStyle: session.isDigitalStyle)
                    }
                }
                .padding(.horizontal)

                if let error = session.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(GETTheme.warningRed)
                        .padding(.horizontal)
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
