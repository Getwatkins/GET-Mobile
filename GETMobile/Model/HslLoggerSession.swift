import Foundation
import SwiftUI

struct HslLogSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let values: [String: Double]
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

    func start() {
        // Guard the whole startup transaction synchronously. SwiftUI can deliver
        // two taps before the first async Task reaches configureHsl(), which
        // otherwise starts two ISO-TP exchanges on the same GVRET connection.
        guard !isRunning, !isStarting, let uds else { return }
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
                // SimosTools does NOT configure only the channels currently shown in
                // the UI. It builds one HSL parameter list from the complete physical
                // parameter file, then each 3E04 read returns that complete packed
                // memory image. The UI selection is only a presentation/filtering
                // choice. Limiting the setup list to selected PIDs produced valid
                // ISO-TP traffic (including the ECU flow-control response) but the
                // patched HSL backend would not reliably complete the list/read cycle.
                // Keep the exact catalog order here so the byte layout matches the
                // SimosTools parameter-list contract.
                self.pids = self.allPids.filter { !$0.isVirtual && $0.length >= 1 && $0.length <= 4 }
                guard !self.pids.isEmpty else { throw HslError.noChannels }
                try await self.configureHsl()
                await MainActor.run {
                    self.isConfigured = true
                    self.isRunning = true
                    self.isStarting = false
                    self.startDate = Date()
                    self.sampleCount = 0
                    self.samples.removeAll(keepingCapacity: true)
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
        latestValues.removeAll()
        sampleCount = 0
        startDate = nil
        lastError = nil
    }

    func exportCSV() throws -> URL {
        let columns = selectedPids.map(\.name)
        var csv = "Time,Elapsed (s)" + columns.map { ",\(csvEscape($0))" }.joined() + "\n"
        let start = startDate ?? samples.first?.timestamp ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for sample in samples {
            let elapsed = sample.timestamp.timeIntervalSince(start)
            var row = "\(csvEscape(formatter.string(from: sample.timestamp))),\(String(format: "%.3f", elapsed))"
            for pid in selectedPids {
                if let value = sample.values[pid.name] {
                    row += ",\(String(format: "%.6f", value))"
                } else {
                    row += ","
                }
            }
            csv += row + "\n"
        }
        let name = "GETMobile_HSL_\(timestampFileName(start)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        logFileURL = url
        return url
    }

    private func configureHsl() async throws {
        // Match the working Windows Simos18 logger exactly.  SimosHslLogger.cs
        // builds one 3E02 request containing the complete physical parameter
        // list at B001E700.  The ECU/J2534 ISO-TP layer handles segmentation
        // and the ECU returns a 0x7E acknowledgement when the list is accepted.
        var paramList = Data()
        for pid in pids {
            guard pid.length >= 1 && pid.length <= 9 else { continue }
            // Windows logger format: ASCII "0", ASCII decimal length digit,
            // then the 32-bit address. For a 2-byte PID this is "02" + address.
            paramList.append(0x30)
            paramList.append(0x30 + UInt8(pid.length))
            paramList.append(UInt8((pid.address >> 24) & 0xFF))
            paramList.append(UInt8((pid.address >> 16) & 0xFF))
            paramList.append(UInt8((pid.address >> 8) & 0xFF))
            paramList.append(UInt8(pid.address & 0xFF))
        }
        paramList.append(0x00)

        let byteCount = paramList.count
        var request = Data([0x3E, 0x02,
                            0xB0, 0x01, 0xE7, 0x00,
                            UInt8((byteCount >> 8) & 0xFF),
                            UInt8(byteCount & 0xFF)])
        request.append(paramList)

        logHsl("HSL setup (Windows-compatible 3E02): bytes=\(byteCount) params=\(pids.count)")
        let response = try await sendHsl(request, expectedPayloadBytes: 1, timeoutSeconds: 6.0)
        let bytes = [UInt8](response)
        guard bytes.first == 0x7E else {
            throw HslError.invalidSetupResponse(hex(response))
        }
        logHsl("HSL setup accepted: \(hex(response))")
    }

    private func pollLoop() async {
        let interval = UInt64(max(0.02, 1.0 / max(1.0, sampleRate)) * 1_000_000_000)
        while !Task.isCancelled {
            let started = Date()
            do {
                // Match the working Windows Simos18 logger: after the 3E02
                // list is installed, poll with 3E04 + B001E700 + FFFF.
                let request = Data([0x3E, 0x04, 0xB0, 0x01, 0xE7, 0x00, 0xFF, 0xFF])
                let expectedBytes = pids.reduce(0) { $0 + $1.length }
                let response = try await sendHsl(request, expectedPayloadBytes: expectedBytes, timeoutSeconds: 3.0)
                try Task.checkCancellation()
                guard response.first == 0x7E else {
                    throw HslError.invalidPollResponse(hex(response))
                }
                // Working Windows logger parses the packed HSL bytes immediately
                // after the leading 0x7E acknowledgement byte.
                let payload = Data(response.dropFirst())
                if payload.isEmpty {
                    throw HslError.invalidPollResponse(hex(response))
                }
                let values = try decode(payload)
                let now = Date()
                samples.append(HslLogSample(timestamp: now, values: values))
                if samples.count > 20_000 { samples.removeFirst(samples.count - 20_000) }
                sampleCount = samples.count
                latestValues = values
                lastError = nil
            } catch is CancellationError {
                break
            } catch let error as HslError {
                lastError = error.localizedDescription
                // A protocol-level HSL rejection is not transient. Stop rather than
                // hammering the ECU with the same malformed/unsupported request.
                if case .invalidPollResponse = error {
                    isRunning = false
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                lastError = error.localizedDescription
                // A transient transport error should not destroy a usable log. Back off briefly.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let elapsed = Date().timeIntervalSince(started)
            let target = Double(interval) / 1_000_000_000.0
            if elapsed < target {
                try? await Task.sleep(nanoseconds: UInt64((target - elapsed) * 1_000_000_000.0))
            }
        }
        isRunning = false
    }

    private func logHsl(_ message: String) {
        // Keep HSL diagnostics visible without requiring the view model to own
        // another logger.  The error field is reserved for actual failures.
        print("[GETMobile HSL] \(message)")
    }

    private func sendHsl(_ request: Data, expectedPayloadBytes: Int, timeoutSeconds: Double = 4.0) async throws -> Data {
        if let hslTransport {
            return try await hslTransport.sendHslRequest(request, expectedPayloadBytes: expectedPayloadBytes, timeoutSeconds: timeoutSeconds)
        }
        guard let uds else { throw HslError.noTransport }
        // Non-GVRET transports can use their normal ISO-TP implementation.
        return try await uds.sendRawRequest(request)
    }

    private func decode(_ payload: Data) throws -> [String: Double] {
        let bytes = [UInt8](payload)
        var offset = 0
        rawVariables.removeAll(keepingCapacity: true)
        variables.removeAll(keepingCapacity: true)

        for pid in pids {
            guard offset + pid.length <= bytes.count else {
                throw HslError.shortPollResponse(expectedAtLeast: offset + pid.length, got: bytes.count)
            }
            let rawBytes = Array(bytes[offset..<(offset + pid.length)])
            offset += pid.length
            let raw: Double
            // SimosTools' MODE_3E decoder consumes the packed HSL values in
            // big-endian byte order (the 2-byte path explicitly builds d1<<8|d2,
            // and the 4-byte path reconstructs the IEEE-754 bits the same way).
            if pid.length == 4 {
                var bits: UInt32 = 0
                for b in rawBytes {
                    bits = (bits << 8) | UInt32(b)
                }
                raw = Double(Float(bitPattern: bits))
            } else {
                var value: UInt64 = 0
                for b in rawBytes {
                    value = (value << 8) | UInt64(b)
                }
                if pid.signed {
                    let bits = pid.length * 8
                    let sign = UInt64(1) << UInt64(bits - 1)
                    let signedValue = (value & sign) != 0
                        ? Int64(bitPattern: value | (~UInt64(0) << UInt64(bits)))
                        : Int64(value)
                    raw = Double(signedValue)
                } else {
                    raw = Double(value)
                }
            }
            rawVariables[pid.name.lowercased()] = raw
            if let assignment = pid.assignment { variables[assignment.lowercased()] = raw }
            do {
                let scaled = try EquationEvaluator.evaluate(pid.equation, variables: variables.merging(["x": raw]) { _, new in new })
                variables[pid.name.lowercased()] = scaled
                if let assignment = pid.assignment { variables[assignment.lowercased()] = scaled }
            } catch {
                variables[pid.name.lowercased()] = raw
                if let assignment = pid.assignment { variables[assignment.lowercased()] = raw }
            }
        }

        // Resolve virtual/derived entries after the physical list is decoded.
        var resolved = variables
        for _ in 0..<3 {
            for pid in allPids where pid.isVirtual {
                if pid.equation == "hp" || pid.equation == "tq" || pid.equation == "speed_zero_sixty" || pid.equation == "speed_sixty_onethirty" || pid.equation == "dist_zero_sixty" || pid.equation == "dist_emile" || pid.equation == "dist_qmile" {
                    continue
                }
                if let value = try? EquationEvaluator.evaluate(pid.equation, variables: resolved) {
                    resolved[pid.name.lowercased()] = value
                }
            }
        }

        if let tq = resolved["tq_eng"] ?? resolved["tq"], let rpm = resolved["rpm"] {
            resolved["tq"] = tq
            resolved["hp"] = tq * rpm / 7127.0
        }
        for pid in allPids where pid.isVirtual {
            if let value = resolved[pid.name.lowercased()] { variables[pid.name.lowercased()] = value }
        }

        var output: [String: Double] = [:]
        for pid in allPids where selectedNames.contains(pid.name) {
            if let value = variables[pid.name.lowercased()] {
                output[pid.name] = value
            }
        }
        return output
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func timestampFileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private func hex(_ data: Data) -> String {
        [UInt8](data).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    enum HslError: Error, LocalizedError {
        case invalidSetupResponse(String)
        case invalidPollResponse(String)
        case shortPollResponse(expectedAtLeast: Int, got: Int)
        case noChannels
        case noTransport
        var errorDescription: String? {
            switch self {
            case .invalidSetupResponse(let value): return "HSL setup failed. ECU response: \(value)"
            case .invalidPollResponse(let value): return "HSL read returned an unexpected response: \(value)"
            case .shortPollResponse(let expected, let got): return "HSL response was short: expected at least \(expected) bytes, received \(got)."
            case .noChannels: return "Select at least one HSL channel before starting the logger."
            case .noTransport: return "HSL logging is not available on the current transport."
            }
        }
    }
}
