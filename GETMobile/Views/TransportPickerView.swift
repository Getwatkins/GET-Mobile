import SwiftUI

enum ConnectionKind {
    case esp32Bridge
    case elm327Wifi
    case elm327Bluetooth
    case gvretWifi
}

/// First screen shown: pick which hardware you're connecting through. Each
/// choice pushes to its own connect screen; all three converge on the same
/// GaugesView once connected.
struct TransportPickerView: View {
    @ObservedObject var bridge: BridgeManager
    @ObservedObject var elm327Wifi: Elm327WifiManager
    @ObservedObject var elm327Bluetooth: Elm327BluetoothManager
    @ObservedObject var gvretWifi: GvretWifiManager
    var onConnected: (ConnectionKind, UdsTransport) -> Void
    var onPreviewDemo: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image("LogoBanner")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280)
                    .padding(.top, 40)

                Text("GET Mobile")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(GETTheme.gold)

                Text("Choose how you're connecting")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)

                VStack(spacing: 12) {
                    NavigationLink {
                        ConnectView(bridge: bridge) { onConnected(.esp32Bridge, bridge) }
                    } label: {
                        optionRow(icon: "cpu", title: "ESP32 Bridge",
                                  subtitle: "Macchina A0 / ISO-TP-BLE bridge")
                    }

                    NavigationLink {
                        Elm327WifiConnectView(manager: elm327Wifi) { onConnected(.elm327Wifi, elm327Wifi) }
                    } label: {
                        optionRow(icon: "wifi", title: "ELM327 WiFi",
                                  subtitle: "Standard WiFi OBD-II dongle")
                    }

                    NavigationLink {
                        Elm327BluetoothConnectView(manager: elm327Bluetooth) { onConnected(.elm327Bluetooth, elm327Bluetooth) }
                    } label: {
                        optionRow(icon: "dot.radiowaves.left.and.right", title: "ELM327 Bluetooth",
                                  subtitle: "BLE dongles only - not Classic Bluetooth")
                    }

                    NavigationLink {
                        GvretWifiConnectView(manager: gvretWifi) { onConnected(.gvretWifi, gvretWifi) }
                    } label: {
                        optionRow(icon: "antenna.radiowaves.left.and.right", title: "Macchina A0 (WiFi)",
                                  subtitle: "SavvyCAN / GVRET protocol - for a bridge stuck in WiFi mode")
                    }
                }
                .padding(.horizontal)

                Button(action: onPreviewDemo) {
                    Text("Preview Gauges (Demo Mode — no hardware needed)")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(GETTheme.panelBackground)
                        .foregroundColor(GETTheme.amber)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.amber, lineWidth: 1))
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)

                Spacer()
            }
            .background(GETTheme.background.ignoresSafeArea())
        }
    }

    private func optionRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(GETTheme.gold)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 12)).foregroundColor(.gray)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.gray)
        }
        .padding(12)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(8)
    }
}
