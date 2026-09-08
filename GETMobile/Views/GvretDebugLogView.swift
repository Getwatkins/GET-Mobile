import SwiftUI

/// Live diagnostic log for the GVRET WiFi transport - every command sent
/// and every CAN frame observed (matching what we're waiting for or not),
/// so a connection problem can be diagnosed from real wire traffic instead
/// of guessing.
struct GvretDebugLogView: View {
    @ObservedObject var manager: GvretWifiManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(manager.debugLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: manager.debugLog.count) { _ in
                    if let last = manager.debugLog.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(GETTheme.background.ignoresSafeArea())
            .navigationTitle("GVRET Diagnostic Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
