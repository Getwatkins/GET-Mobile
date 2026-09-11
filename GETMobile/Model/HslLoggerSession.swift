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
        // Match SimosTools' MODE_3E initialization exactly.
        //
        // The HSL address table is NOT sent as one giant 3E02 request. SimosTools
        // splits the address table into chunks of at most 0x8F bytes and sends:
        //   3E 32 <B001E700 + offset> <chunkLength> <address entries...>
        // Each chunk is acknowledged with 7E 00 <chunkLength>. After the final
        // chunk, 3E 33 B001E700 persists/enables the HSL stream and is acknowledged
        // with 7E 00 FF.
        //
        // The previous implementation sent the entire table in one ISO-TP message.
        // That produced the large 0x1FD request visible in the debug log, but that
        // is not the SimosTools protocol and is why the ECU never reached the
        // streaming state.
        var addressArray = Data()
        for pid in pids {
            guard pid.length >= 1 && pid.length <= 4 else { continue }
            addressArray.append(UInt8(pid.length & 0xFF))
            addressArray.append(UInt8((pid.address >> 24) & 0xFF))
            addressArray.append(UInt8((pid.address >> 16) & 0xFF))
            addressArray.append(UInt8((pid.address >> 8) & 0xFF))
            addressArray.append(UInt8(pid.address & 0xFF))
        }
        addressArray.append(0x00)

        let chunkSize = 0x8F
        var offset = 0
        while offset < addressArray.count {
            let end = min(offset + chunkSize, addressArray.count)
            let chunk = Array(addressArray[offset..<end])
            let memoryOffset = UInt32(0xB001E700) + UInt32(offset)

            var request = Data([0x3E, 0x32,
                                UInt8((memoryOffset >> 24) & 0xFF),
                                UInt8((memoryOffset >> 16) & 0xFF),
                                UInt8((memoryOffset >> 8) & 0xFF),
                                UInt8(memoryOffset & 0xFF),
                                UInt8((chunk.count >> 8) & 0xFF),
                                UInt8(chunk.count & 0xFF)])
            request.append(contentsOf: chunk)

            let response = try await sendHsl(request, expectedPayloadBytes: 3)
            let bytes = [UInt8](response)
            guard bytes.count >= 3, bytes[0] == 0x7E, bytes[1] == 0x00,
                  bytes[2] == UInt8(chunk.count & 0xFF) else {
                throw HslError.invalidSetupResponse(hex(response))
            }

            // Keep this visible in the debug log so a failed initialization can
            // immediately identify which SimosTools chunk was rejected.
            lastError = nil
            offset = end
        }

        // Final SimosTools persist/enable command. This is what changes the ECU
        // from the address-list setup phase into the high-speed 3E data stream.
        let persist = Data([0x3E, 0x33, 0xB0, 0x01, 0xE7, 0x00])
        let finalResponse = try await sendHsl(persist, expectedPayloadBytes: 3)
        let finalBytes = [UInt8](finalResponse)
        guard finalBytes.count >= 3, finalBytes[0] == 0x7E,
              finalBytes[1] == 0x00, finalBytes[2] == 0xFF else {
            throw HslError.invalidSetupResponse(hex(finalResponse))
        }
    }

    private func pollLoop() async {
        let interval = UInt64(max(0.02, 1.0 / max(1.0, sampleRate)) * 1_000_000_000)
        while !Task.isCancelled {
            let started = Date()
            do {
                // SimosTools persists the 3E33 command and repeats it at the
                // configured logging rate. GET Mobile uses the same behavior
                // explicitly over GVRET: each request returns one packed HSL sample.
                let request = Data([0x3E, 0x33, 0xB0, 0x01, 0xE7, 0x00])
                let expectedBytes = pids.reduce(0) { $0 + $1.length }
                let response = try await sendHsl(request, expectedPayloadBytes: expectedBytes)
                try Task.checkCancellation()
                guard response.first == 0x7E else {
                    throw HslError.invalidPollResponse(hex(response))
                }
                // The SimosTools HSL backend returns 0x7E followed directly by
                // the configured memory payload (it does not echo 0x04 here).
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

    private func sendHsl(_ request: Data, expectedPayloadBytes: Int) async throws -> Data {
        if let hslTransport {
            return try await hslTransport.sendHslRequest(request, expectedPayloadBytes: expectedPayloadBytes, timeoutSeconds: 4.0)
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
