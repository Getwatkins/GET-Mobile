import SwiftUI
import CoreBluetooth

/// Scan/connect screen shown before a bridge is connected. Kept intentionally
/// simple - list of nearby bridges advertising the ISO-TP service, tap to connect.
struct ConnectView: View {
    @ObservedObject var bridge: BridgeManager

    var body: some View {
        VStack(spacing: 20) {
            Image("LogoBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280)
                .padding(.top, 40)

            Text("GET Mobile")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(GETTheme.gold)

            Text("Connect to your ESP32 BLE bridge")
                .font(.system(size: 14))
                .foregroundColor(.gray)

            statusView

            List(bridge.discoveredPeripherals, id: \.identifier) { peripheral in
                Button {
                    bridge.connect(to: peripheral)
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundColor(GETTheme.gold)
                        Text(peripheral.name ?? "Unknown bridge")
                            .foregroundColor(.white)
                        Spacer()
                    }
                }
                .listRowBackground(GETTheme.panelBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button {
                bridge.startScan()
            } label: {
                Text(bridge.state == .scanning ? "Scanning…" : "Scan for bridge")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(GETTheme.gold)
                    .foregroundColor(.black)
                    .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(GETTheme.background.ignoresSafeArea())
        .onAppear { bridge.startScan() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch bridge.state {
        case .connecting:
            Label("Connecting…", systemImage: "hourglass").foregroundColor(GETTheme.amber)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundColor(GETTheme.warningRed)
        default:
            EmptyView()
        }
    }
}
