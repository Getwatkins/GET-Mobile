import SwiftUI
import UIKit

/// Live diagnostic log for the "ESP32 Bridge" (BridgeLEG, BLE) transport -
/// same purpose as GvretDebugLogView, for the same reason: a Start Logging
/// attempt over this transport needs to be diagnosable from real traffic,
/// not guessed at.
struct BridgeDebugLogView: View {
    @ObservedObject var manager: BridgeManager
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
                    .textSelection(.enabled)
                }
                .onChange(of: manager.debugLog.count) { _ in
                    if let last = manager.debugLog.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .background(GETTheme.background.ignoresSafeArea())
            .navigationTitle("Bridge Diagnostic Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy Log") {
                        UIPasteboard.general.string = manager.debugLog.joined(separator: "\n")
                    }
                    .disabled(manager.debugLog.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
