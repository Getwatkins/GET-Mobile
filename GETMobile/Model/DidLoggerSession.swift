import Foundation
import SwiftUI

struct DidLogSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let values: [String: Double]
}

/// A CSV datalogger built entirely on the same mechanism the gauges already
/// use successfully - sequential UDS 0x22 (ReadDataByIdentifier) requests,
/// one per selected channel, via CommonDidCatalog - instead of the Simos
/// HSL (0x3E) memory-list protocol that GVRET WiFi has never once gotten a
/// response from. Slower per-channel than HSL claims to be (each channel is
/// its own request/response round trip, same as a gauge read), but it's the
/// same path that's worked reliably every single time throughout this whole
/// investigation - just recording readings over time and exporting them
/// instead of only showing the latest one on a dial.
@MainActor
final class DidLoggerSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var latestValues: [String: Double] = [:]
    @Published private(set) var samples: [DidLogSample] = []
    @Published var selectedNames: Set<String> = ["Engine Speed", "MAP", "PUT", "Lambda", "Torque", "Pedal Pos", "IAT", "Coolant Temp"]
    @Published var lastError: String?

    private weak var transport: UdsTransport?
    private var uds: UdsClient?
    private var task: Task<Void, Never>?
    private var logFileURL: URL?

    var selectedEntries: [CommonDidEntry] {
        CommonDidCatalog.all.filter { selectedNames.contains($0.name) }
    }

    var duration: TimeInterval {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    func attach(transport: UdsTransport) {
        self.stop()
        self.transport = transport
        self.uds = UdsClient(transport: transport)
        self.uds?.requestTimeoutSeconds = 3
    }

    func detach() {
        stop()
        uds = nil
        transport = nil
    }

    func start() {
        guard !isRunning, !isStarting, let uds else { return }
        guard !selectedEntries.isEmpty else {
            lastError = "Select at least one channel."
            return
        }
        isStarting = true
        lastError = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isRunning = true
                self.isStarting = false
                self.startDate = Date()
                self.sampleCount = 0
                self.samples.removeAll(keepingCapacity: true)
                self.latestValues.removeAll()
            }
            await self.pollLoop(uds: uds)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        isStarting = false
    }

    func clear() {
        samples.removeAll()
        latestValues.removeAll()
        sampleCount = 0
        startDate = nil
        lastError = nil
    }

    func exportCSV() throws -> URL {
        let entries = selectedEntries
        let columns = entries.map(\.name)
        var csv = "Time,Elapsed (s)" + columns.map { ",\(csvEscape($0))" }.joined() + "\n"
        let start = startDate ?? samples.first?.timestamp ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for sample in samples {
            let elapsed = sample.timestamp.timeIntervalSince(start)
            var row = "\(csvEscape(formatter.string(from: sample.timestamp))),\(String(format: "%.3f", elapsed))"
            for entry in entries {
                if let value = sample.values[entry.name] {
                    row += ",\(String(format: "%.6f", value))"
                } else {
                    row += ","
                }
            }
            csv += row + "\n"
        }
        let name = "GETMobile_DIDLog_\(timestampFileName(start)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        logFileURL = url
        return url
    }

    /// One full pass over every selected channel is one CSV row. Each
    /// channel is its own complete request/response round trip - the exact
    /// same pattern GaugeSessionViewModel.pollAllSlots() already uses
    /// successfully, just recording every reading instead of only the most
    /// recent one. No artificial delay needed between channels: each read
    /// already waits for its own response before the next one starts, so
    /// there's no multi-frame burst for the WiFi bridge to choke on - the
    /// exact failure mode that's plagued the HSL path all along simply
    /// doesn't apply here.
    private func pollLoop(uds: UdsClient) async {
        while !Task.isCancelled {
            var row: [String: Double] = [:]
            for entry in selectedEntries {
                guard !Task.isCancelled else { return }
                do {
                    let response = try await uds.readDataByIdentifier(entry.did)
                    let (_, numeric) = DidValueDecoder.decode(entry, from: response)
                    if numeric.isFinite {
                        row[entry.name] = numeric
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "\(entry.name) (0x\(String(entry.did, radix: 16, uppercase: true))): \(error.localizedDescription)"
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let sample = DidLogSample(timestamp: Date(), values: row)
            await MainActor.run {
                self.samples.append(sample)
                self.sampleCount = self.samples.count
                self.latestValues = row
            }
        }
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func timestampFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
