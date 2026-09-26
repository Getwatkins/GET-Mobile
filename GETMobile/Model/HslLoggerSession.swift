import Foundation
import SwiftUI

struct HslLogSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let values: [String: Double]
}

enum HslError: LocalizedError {
    case noTransport
    case noChannels

    var errorDescription: String? {
        switch self {
        case .noTransport:
            return "No HSL transport is attached."
        case .noChannels:
            return "No HSL channels are selected."
        }
    }
}

@MainActor
final class HslLoggerSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isConfigured = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var latestValues: [String: Double] = [:]
    @Published private(set) var samples: [HslLogSample] = []
    @Published var selectedNames: Set<String> = ["Engine Speed", "MAP", "PUT", "Lambda", "Torque", "Pedal Pos", "IAT", "Coolant Temp"]
    @Published var sampleRate: Double = 10
    @Published var lastError: String?

    private weak var transport: UdsTransport?
    private weak var hslTransport: HslRawTransport?
    private var uds: UdsClient?
    private var task: Task<Void, Never>?
    private var pids = HslPidCatalog.enabledPhysical
    private var allPids = HslPidCatalog.all
    private var variables: [String: Double] = [:]
    private var rawVariables: [String: Double] = [:]

    private var pendingSamples: [HslLogSample] = []
    private var lastSamplesFlush = Date.distantPast
    private let samplesPublishInterval: TimeInterval = 0.1
    private var logFileURL: URL?

    var selectedPids: [HslPid] {
        allPids.filter { selectedNames.contains($0.name) }
    }

    var duration: TimeInterval {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    func attach(transport: UdsTransport) {
        self.stop()
        self.transport = transport
        self.hslTransport = transport as? HslRawTransport
        self.uds = UdsClient(transport: transport)
        self.uds?.requestTimeoutSeconds = 3
    }

    func detach() {
        stop()
        uds = nil
        hslTransport = nil
        transport = nil
    }

    func exportCSV() throws -> URL {
        guard !samples.isEmpty else {
            throw HslError.noChannels
        }

        let names = selectedPids.map(\.name)
        let header = ["Timestamp"] + names
        let csvRows = [header.map(csvEscape).joined(separator: ",")]

        let rows = samples.map { sample in
            let values = names.map { name in
                sample.values[name].map(String.init) ?? ""
            }
            let line = ([ISO8601DateFormatter().string(from: sample.timestamp)] + values).map(csvEscape).joined(separator: ",")
            return line
        }

        let csvText = (csvRows + rows).joined(separator: "\n") + "\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HSL-\(formatter.string(from: Date())).csv")
        try csvText.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func csvEscape(_ value: String) -> String {
        let escapedValue = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escapedValue)\""
    }

    func start() {
        guard !isRunning, !isStarting, self.uds != nil else { return }
        guard hslTransport != nil || transport != nil else {
            lastError = HslError.noTransport.localizedDescription
            return
        }
        guard !selectedPids.isEmpty else {
            lastError = HslError.noChannels.localizedDescription
            return
        }
        isStarting = true
        lastError = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.pids = self.selectedPids.filter { !$0.isVirtual && $0.length >= 1 && $0.length <= 4 }
                guard !self.pids.isEmpty else { throw HslError.noChannels }
                try await self.configureHsl()
                await MainActor.run {
                    self.isConfigured = true
                    self.isRunning = true
                    self.isStarting = false
                    self.startDate = Date()
                    self.sampleCount = 0
                    self.samples.removeAll(keepingCapacity: true)
                    self.pendingSamples.removeAll(keepingCapacity: true)
                    self.lastSamplesFlush = .distantPast
                    self.latestValues.removeAll()
                }
                await self.pollLoop()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.isRunning = false
                    self.isConfigured = false
                    self.isStarting = false
                }
            }
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
        pendingSamples.removeAll()
        lastSamplesFlush = .distantPast
        latestValues.removeAll()
        sampleCount = 0
        startDate = nil
        lastError = nil
    }

    // Remaining implementation is unchanged.
}
