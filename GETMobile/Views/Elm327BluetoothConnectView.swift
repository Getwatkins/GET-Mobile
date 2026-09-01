import SwiftUI

/// Connect screen for ELM327 Bluetooth dongles - scan/connect list, same
/// shape as the ESP32 bridge screen, but with an upfront compatibility
/// warning since this only works for BLE (not Classic Bluetooth) dongles.
struct Elm327BluetoothConnectView: View {
    @ObservedObject var manager: Elm327BluetoothManager
    var onConnected: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("ELM327 Bluetooth")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(GETTheme.gold)
                .padding(.top, 24)

            Text("Only works with BLE dongles (often labeled \"Bluetooth 4.0/LE\" or \"iOS compatible\"). Classic Bluetooth ELM327 dongles cannot connect to any third-party iPhone app - that's an Apple restriction, not something this app can work around.")
                .font(.system(size: 12))
                .foregroundColor(GETTheme.amber)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            statusView

            List(manager.discoveredPeripherals, id: \.identifier) { peripheral in
                Button {
                    manager.connect(to: peripheral)
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundColor(GETTheme.gold)
                        Text(peripheral.name ?? "Unknown device")
                            .foregroundColor(.white)
                        Spacer()
                    }
                }
                .listRowBackground(GETTheme.panelBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button {
                manager.startScan()
            } label: {
                Text(manager.state == .scanning ? "Scanning…" : "Scan for dongle")
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
        .onAppear { manager.startScan() }
        .onChange(of: manager.state) { newValue in
            if newValue == .ready { onConnected() }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch manager.state {
        case .connecting:
            Label("Connecting…", systemImage: "hourglass").foregroundColor(GETTheme.amber)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundColor(GETTheme.warningRed)
        default:
            EmptyView()
        }
    }
}
