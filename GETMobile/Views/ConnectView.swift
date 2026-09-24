import SwiftUI
import CoreBluetooth

/// Scan/connect screen for the ESP32 BLE-ISOTP bridge specifically. Reached
/// from TransportPickerView after choosing "ESP32 Bridge".
struct ConnectView: View {
    @ObservedObject var bridge: BridgeManager
    var onConnected: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("ESP32 Bridge")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(GETTheme.gold)
                .padding(.top, 24)

            Text("Scanning for your Macchina A0 / ISO-TP bridge")
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
        .onChange(of: bridge.state) { newValue in
            if newValue == .ready { onConnected() }
        }
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
