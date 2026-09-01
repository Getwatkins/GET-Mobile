import Foundation
import SwiftUI

/// One of the 6 gauges. Mirrors DidSlot in Simos18DiagnosticsControl.xaml.cs -
/// holds which catalog entry this slot is reading and its most recent value.
@MainActor
final class GaugeSlot: ObservableObject, Identifiable {
    let id = UUID()

    @Published var selectedEntry: CommonDidEntry?
    @Published var displayText: String = "--"
    @Published var numericValue: Double = .nan
    @Published var enabled: Bool = true

    var gaugeMin: Double { selectedEntry?.progMin ?? 0 }
    var gaugeMax: Double {
        guard let e = selectedEntry else { return 255 }
        return e.progMax > e.progMin ? e.progMax : e.progMin + 1
    }
    var gaugeUnit: String { selectedEntry?.unit ?? "" }
    var gaugeLabel: String { selectedEntry?.name ?? "" }

    init(defaultName: String? = nil) {
        if let name = defaultName {
            selectedEntry = CommonDidCatalog.all.first { $0.name == name }
        }
    }

    func applyResponse(_ data: Data) {
        guard let entry = selectedEntry else { return }
        let (text, numeric) = DidValueDecoder.decode(entry, from: data)
        displayText = text
        numericValue = numeric
    }

    func applyError(_ message: String) {
        displayText = message
        numericValue = .nan
    }
}

/// Orchestrates the 6 gauge slots and the live-read loop against the bridge,
/// mirroring the Windows app's live-poll thread (Simos18DiagnosticsControl's
/// btnStartLive_Click / DidPollThread).
@MainActor
final class GaugeSessionViewModel: ObservableObject {
    @Published var slots: [GaugeSlot]
    @Published var isLive = false
    @Published var isDigitalStyle = false
    @Published var lastError: String?

    private let bridge: BridgeManager
    private let uds: UdsClient
    private var liveTask: Task<Void, Never>?

    init(bridge: BridgeManager) {
        self.bridge = bridge
        self.uds = UdsClient(bridge: bridge)
        self.slots = [
            GaugeSlot(defaultName: "PUT"),
            GaugeSlot(defaultName: "Engine Speed"),
            GaugeSlot(defaultName: "MAP"),
            GaugeSlot(),
            GaugeSlot(),
            GaugeSlot(),
        ]
    }

    func readOnce() {
        Task { await pollAllSlots() }
    }

    func startLive() {
        guard liveTask == nil else { return }
        isLive = true
        liveTask = Task {
            while !Task.isCancelled {
                await pollAllSlots()
                try? await Task.sleep(nanoseconds: 150_000_000) // ~6-7Hz, gentle on the BLE link
            }
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    private func pollAllSlots() async {
        for slot in slots where slot.enabled && slot.selectedEntry != nil {
            guard let entry = slot.selectedEntry else { continue }
            do {
                let response = try await uds.readDataByIdentifier(entry.did)
                slot.applyResponse(response)
                lastError = nil
            } catch {
                slot.applyError("--")
                lastError = error.localizedDescription
            }
        }
    }
}
