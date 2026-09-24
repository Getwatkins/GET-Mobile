import SwiftUI

/// Connect screen for ELM327 WiFi dongles - just a host/port + connect
/// button, since there's no scanning involved (you join the dongle's WiFi
/// network, or it joins yours, outside the app first).
struct Elm327WifiConnectView: View {
    @ObservedObject var manager: Elm327WifiManager
    var onConnected: () -> Void

    @State private var host: String = "192.168.0.10"
    @State private var portText: String = "35000"

    var body: some View {
        VStack(spacing: 20) {
            Text("ELM327 WiFi")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(GETTheme.gold)
                .padding(.top, 24)

            Text("Connect your phone to the dongle's WiFi network first (or make sure it's joined yours), then enter its address below.")
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

            Text("192.168.0.10:35000 is the default for most WiFi ELM327 dongles - change it only if yours uses something different.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .padding(.horizontal)

            Button {
                let port = UInt16(portText) ?? 35000
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
