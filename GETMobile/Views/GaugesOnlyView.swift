import SwiftUI

/// Just the gauge grid + live-polling controls now - HSL/Standard logging,
/// flashing, and diagnostics moved out to their own sections reachable from
/// the home hub instead of being crammed onto this one scrolling screen.
struct GaugesOnlyView: View {
    @ObservedObject var session: GaugeSessionViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

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
            }
            .padding(.bottom, 24)
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Gauges")
        .navigationBarTitleDisplayMode(.inline)
    }
}
