import SwiftUI

/// Reached from Home -> Logging. Picks between the two logging mechanisms
/// this app has (they're genuinely different underlying transports, not
/// just a display preference - see HslLoggerSession/DidLoggerSession),
/// then pushes onto the same shared nav path so back still steps out one
/// level at a time.
///
/// Tiles here are deliberately identical in size/style to HomeMenuView's -
/// same screen-derived width/height, same icon/title sizing, same corner
/// radius - so the two screens read as one consistent tile language rather
/// than Home being "the tile screen" and this being "the button list".
struct LoggingMenuView: View {
    @ObservedObject var session: GaugeSessionViewModel
    let transport: UdsTransport
    @Binding var path: [HomeRoute]

    private var tileWidth: CGFloat { UIScreen.main.bounds.width / 2 }
    private var tileHeight: CGFloat { UIScreen.main.bounds.height * 0.30 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("LOGGING")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(GETTheme.gold)
                    .padding(.top, 12)

                LazyVGrid(columns: [GridItem(.fixed(tileWidth), spacing: 0), GridItem(.fixed(tileWidth), spacing: 0)], spacing: 0) {
                    tile(title: "HSL Datalogger", systemImage: "waveform.path.ecg", tint: GETTheme.amber) {
                        // Do not acquire HSL ownership here. The HSL logger acquires
                        // exclusive ownership at the exact moment Start Logging is
                        // pressed, after DatalogView has attached to the transport.
                        path.append(.hslDatalog)
                    }

                    tile(title: "Standard Logger", systemImage: "tablecells", tint: GETTheme.gold) {
                        path.append(.standardDatalog)
                    }
                }

                subtitles
            }
        }
        .background(GETTheme.background.ignoresSafeArea())
        .navigationTitle("Logging")
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
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .frame(width: tileWidth, height: tileHeight)
            .background(GETTheme.panelBackground)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.6), lineWidth: 1))
            .cornerRadius(4)
        }
    }

    /// The old cards carried a one-line explanation of each mechanism.
    /// Dropped from the tiles themselves to match Home's icon+title-only
    /// style exactly, kept here underneath instead so that information
    /// isn't just lost.
    private var subtitles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundColor(GETTheme.amber).frame(width: 20)
                Text("HSL Datalogger - Simos HSL memory-list protocol, fast, all configured channels in one shot.")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tablecells").foregroundColor(GETTheme.gold).frame(width: 20)
                Text("Standard Logger - normal DID reads, one channel at a time, the same reliable path the gauges use.")
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.gray)
        .padding()
    }
}
