import SwiftUI

/// Connect screen for a Macchina A0 running A0RET firmware in WiFi mode
/// (the SavvyCAN GVRET protocol). Same shape as the ELM327 WiFi screen -
/// host/port entry, since there's no scanning involved.
struct GvretWifiConnectView: View {
    @ObservedObject var manager: GvretWifiManager
    var onConnected: () -> Void

    @State private var host: String = "192.168.4.1"
    @State private var portText: String = "23"

    var body: some View {
        VStack(spacing: 20) {
            Text("Macchina A0 (WiFi)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(GETTheme.gold)
                .padding(.top, 24)

            Text("Connect your phone to the A0's WiFi network first (default SSID is usually printed on the device or in its settings), then enter its address below.")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            statusView

            VStack(alignment: .leading, spacing: 12) {
                labeledField(title: "Host / IP address", text: $host)
                labeledField(title: "Port", text: $portText)
                    .keyboardType(.numberPad)
            }
            .padding(.horizontal)

            Text("192.168.4.1:23 is the default for a Macchina A0 in its own WiFi access-point mode - change the host if you've configured it to join your home WiFi instead.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .padding(.horizontal)

            Button {
                let port = UInt16(portText) ?? GvretProtocol.tcpPort
                manager.connect(host: host, port: port)
            } label: {
                Text(manager.state == .connecting ? "Connecting…" : "Connect")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(GETTheme.gold)
                    .foregroundColor(.black)
                    .cornerRadius(8)
            }
            .padding(.horizontal)

            Spacer()
        }
        .background(GETTheme.background.ignoresSafeArea())
        .onChange(of: manager.state) { newValue in
            if newValue == .ready { onConnected() }
        }
    }

    private func labeledField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundColor(.gray)
            TextField(title, text: text)
                .padding(10)
                .background(GETTheme.panelBackground)
                .foregroundColor(.white)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.border, lineWidth: 1))
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
