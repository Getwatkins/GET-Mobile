import SwiftUI

/// Reached from Home -> Logging. Picks between the two logging mechanisms
/// this app has (they're genuinely different underlying transports, not
/// just a display preference - see HslLoggerSession/DidLoggerSession),
/// then pushes onto the same shared nav path so back still steps out one
/// level at a time.
struct LoggingMenuView: View {
    @ObservedObject var session: GaugeSessionViewModel
    let transport: UdsTransport
    @Binding var path: [HomeRoute]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("LOGGING")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(GETTheme.gold)
                    .padding(.top, 16)

                card(
                    title: "HSL Datalogger",
                    subtitle: "Simos HSL memory-list protocol - fast, all configured channels in one shot",
                    systemImage: "waveform.path.ecg",
                    tint: GETTheme.amber
                ) {
                    // Acquire the ownership lock BEFORE navigating, same as
                    // before: closes the small window where another view
                    // update could restart normal gauge polling.
                    session.beginHslLogging()
                    path.append(.hslDatalog)
                }

                card(
                    title: "Standard Logger (CSV)",
                    subtitle: "Normal DID reads, one channel at a time - the same reliable path the gauges use",
                    systemImage: "tablecells",
                    tint: GETTheme.gold
                ) {
                    session.beginHslLogging()
                    path.append(.standardDatalog)
                }
            }
            .padding()
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Logging")
        .navigationBarTitleDisplayMode(.inline)
        .withTopLogo()
    }

    private func card(title: String, subtitle: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundColor(tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
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
}
