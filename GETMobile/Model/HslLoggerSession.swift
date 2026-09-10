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
    @Published private(set) var isConfigured = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var latestValues: [String: Double] = [:]
    @Published private(set) var samples: [HslLogSample] = []
    @Published var selectedNames: Set<String> = ["Engine Speed", "MAP", "PUT", "Lambda", "Torque", "Pedal Pos", "IAT", "Coolant Temp"]
    @Published var sampleRate: Double = 10
    @Published var lastError: String?

    private weak var transport: UdsTransport?
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
        guard !isRunning, let uds else { return }
        lastError = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.configureHsl(uds: uds)
                await MainActor.run {
                    self.isConfigured = true
                    self.isRunning = true
                    self.startDate = Date()
                    self.sampleCount = 0
                    self.samples.removeAll(keepingCapacity: true)
                    self.latestValues.removeAll()
                }
                await self.pollLoop(uds: uds)
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.isRunning = false
                    self.isConfigured = false
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
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

    private func configureHsl(uds: UdsClient) async throws {
        // This is the SimosTools/VW_Flash HSL setup sequence:
        // 3E 02 + memory offset B001E700 + 16-bit byte count +
        // [0][length nibble][32-bit address] entries + 00 terminator.
        var parameterList = Data()
        for pid in pids {
            guard pid.length >= 1 && pid.length <= 4 else { continue }
            parameterList.append(0x00)
            parameterList.append(UInt8(pid.length))
            parameterList.append(UInt8((pid.address >> 24) & 0xFF))
            parameterList.append(UInt8((pid.address >> 16) & 0xFF))
            parameterList.append(UInt8((pid.address >> 8) & 0xFF))
            parameterList.append(UInt8(pid.address & 0xFF))
        }
        parameterList.append(0x00)

        let offset: UInt32 = 0xB001E700
        let count = UInt16(parameterList.count)
        var request = Data([0x3E, 0x02,
                            UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF),
                            UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF),
                            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
        request.append(parameterList)

        let response = try await uds.sendRawRequest(request)
        guard response.first == 0x7E else {
            throw HslError.invalidSetupResponse(hex(response))
        }
    }

    private func pollLoop(uds: UdsClient) async {
        let interval = UInt64(max(0.02, 1.0 / max(1.0, sampleRate)) * 1_000_000_000)
        while !Task.isCancelled {
            let started = Date()
            do {
                let request = Data([0x3E, 0x04, 0xFF, 0xFF])
                let response = try await uds.sendRawRequest(request)
                try Task.checkCancellation()
                guard response.first == 0x7E else {
                    throw HslError.invalidPollResponse(hex(response))
                }
                let payload = Data(response.dropFirst())
                let values = try decode(payload)
                let now = Date()
                samples.append(HslLogSample(timestamp: now, values: values))
                if samples.count > 20_000 { samples.removeFirst(samples.count - 20_000) }
                sampleCount = samples.count
                latestValues = values
                lastError = nil
            } catch is CancellationError {
                break
            } catch {
                lastError = error.localizedDescription
                // A transient read error should not destroy a usable log. Back off briefly.
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
            if pid.length == 4 {
                var bits: UInt32 = 0
                for (i, b) in rawBytes.enumerated() { bits |= UInt32(b) << UInt32(i * 8) }
                raw = Double(Float(bitPattern: bits))
            } else {
                var value: UInt64 = 0
                for (i, b) in rawBytes.enumerated() { value |= UInt64(b) << UInt64(i * 8) }
                if pid.signed {
                    let bits = pid.length * 8
                    let sign = UInt64(1) << UInt64(bits - 1)
                    let signedValue = (value & sign) != 0 ? Int64(value | (~UInt64(0) << UInt64(bits))) : Int64(value)
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
        var errorDescription: String? {
            switch self {
            case .invalidSetupResponse(let value): return "HSL setup failed. ECU response: \(value)"
            case .invalidPollResponse(let value): return "HSL read returned an unexpected response: \(value)"
            case .shortPollResponse(let expected, let got): return "HSL response was short: expected at least \(expected) bytes, received \(got)."
            }
        }
    }
}
