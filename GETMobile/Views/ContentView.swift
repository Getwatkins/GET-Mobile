import SwiftUI

struct ContentView: View {
    @StateObject private var bridge: BridgeManager
    @StateObject private var session: GaugeSessionViewModel

    init() {
        let bridge = BridgeManager()
        _bridge = StateObject(wrappedValue: bridge)
        _session = StateObject(wrappedValue: GaugeSessionViewModel(bridge: bridge))
    }

    var body: some View {
        Group {
            if bridge.state == .ready {
                GaugesView(bridge: bridge, session: session)
            } else {
                ConnectView(bridge: bridge)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
