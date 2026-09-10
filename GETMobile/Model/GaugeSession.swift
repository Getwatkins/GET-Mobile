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

    /// Generates a smoothly moving fake value inside this DID's own real
    /// gauge range, purely so Demo Mode has something to show on the dial -
    /// not a simulation of real engine behavior, just enough motion to see
    /// the needle/digital styling and color changes working.
    func applyDemoValue(entry: CommonDidEntry, elapsed: TimeInterval) {
        let mid = (entry.progMin + entry.progMax) / 2
        let amplitude = (entry.progMax - entry.progMin) / 2 * 0.7
        let phase = Double(entry.did) // offsets each gauge so they don't all move in lockstep
        let value = mid + amplitude * sin(elapsed * 0.6 + phase)
        let rounded = (value * 100).rounded() / 100
        numericValue = rounded
        let unitSuffix = entry.unit.isEmpty ? "" : " \(entry.unit)"
        displayText = "\(entry.name): \(rounded)\(unitSuffix) (demo)"
    }
}

/// Orchestrates the 6 gauge slots and the live-read loop. Doesn't know or
/// care which of the 3 transports (ESP32 bridge, ELM327 WiFi, ELM327 BLE)
/// is actually connected - whichever one succeeds gets attached after the
/// fact via `attach(transport:)`, mirroring the Windows app's live-poll
/// thread (Simos18DiagnosticsControl's btnStartLive_Click / DidPollThread).
@MainActor
final class GaugeSessionViewModel: ObservableObject {
    @Published var slots: [GaugeSlot]
    @Published var isLive = false
    @Published var isDigitalStyle = false
    @Published var lastError: String?
    @Published var isDemoMode = false

    private var uds: UdsClient?
    private var liveTask: Task<Void, Never>?
    private var demoStartTime = Date()

    /// Guards pollAllSlots() itself (not just readOnce/startLive
    /// individually) so no two poll cycles can ever run concurrently and
    /// race on the shared transport - which only allows one request in
    /// flight at a time. Without this, tapping "Read Once" more than once,
    /// or tapping it while "Start Live" is already running, causes
    /// overlapping reads that fail instantly (transport correctly refusing
    /// the second one) instead of waiting their turn - which looks exactly
    /// like every DID rapid-firing and failing instead of a clean 5-second
    /// wait per request.
    private var isPolling = false

    init() {
        self.slots = [
            GaugeSlot(defaultName: "PUT"),
            GaugeSlot(defaultName: "Engine Speed"),
            GaugeSlot(defaultName: "MAP"),
            GaugeSlot(),
            GaugeSlot(),
            GaugeSlot(),
        ]
    }

    /// Call once a transport (any of the 3) reports it's ready.
    func attach(transport: UdsTransport) {
        uds = UdsClient(transport: transport)
    }

    func detach() {
        uds = nil
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
                try? await Task.sleep(nanoseconds: 250_000_000) // 4Hz; leaves the WiFi bridge more breathing room
            }
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    /// Fills any slot that doesn't already have a DID picked with something
    /// visually interesting, purely so Demo Mode shows all 6 gauges moving
    /// instead of 3 real defaults + 3 blanks.
    func fillBlankSlotsForDemo() {
        let extras = ["AFR", "Boost/Vacuum", "Vehicle Speed"]
        var extraIndex = 0
        for slot in slots where slot.selectedEntry == nil {
            guard extraIndex < extras.count else { break }
            slot.selectedEntry = CommonDidCatalog.all.first { $0.name == extras[extraIndex] }
            extraIndex += 1
        }
    }

    private func pollAllSlots() async {
        guard !isPolling else { return } // a previous cycle is still in flight - skip rather than race it
        isPolling = true
        defer { isPolling = false }

        for slot in slots where slot.enabled && slot.selectedEntry != nil {
            guard let entry = slot.selectedEntry else { continue }

            if isDemoMode {
                slot.applyDemoValue(entry: entry, elapsed: Date().timeIntervalSince(demoStartTime))
                continue
            }

            guard let uds else { continue } // no transport attached yet - shouldn't normally happen outside demo mode

            do {
                let response = try await uds.readDataByIdentifier(entry.did)
                slot.applyResponse(response)
                lastError = nil
            } catch {
                slot.applyError("--")
                lastError = "\(entry.name) (0x\(String(entry.did, radix: 16, uppercase: true))): \(error.localizedDescription)"
            }
        }
    }
}
