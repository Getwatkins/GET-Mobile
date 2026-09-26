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

                Button(action: session.isLive ? session.stopLive : session.startLive) {
                    Text(session.isLive ? "Stop Live" : "Start Live").bold()
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(session.isLive ? GETTheme.warningRed : GETTheme.amber)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                // No .frame(maxWidth: .infinity) here and no wrapping HStack -
                // a plain child is centered by the VStack's default alignment.

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
        .withTopLogo()
        .onDisappear {
            // Navigating away no longer means "the user tapped Stop Live" the
            // way it implicitly did when this was one long scrolling screen -
            // Gauges is now its own destination the user can leave mid-poll.
            // Stop here so a live cycle can't keep running in the background
            // and racing the next thing they open (Logging/Flash already
            // guard against this via isHslActive, but this closes the gap
            // sooner instead of relying on that alone).
            session.stopLive()
        }
    }
}
