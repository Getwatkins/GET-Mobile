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
    /// Channels shown in the UI / written to the exported CSV. This is a DISPLAY
    /// filter only: the ECU's HSL list is always every polled row of the selected
    /// parameter file (see start()), exactly like the desktop logger.
    @Published var selectedNames: Set<String> = []
    /// Pause after each completed poll, in ms - the desktop logger's "Poll Delay (ms)"
    /// box (Thread.Sleep(pollDelayMs) after every PollOnce), default 100.
    @Published var pollDelayMs: Int = 100
    @Published var lastError: String?

    /// Parameter files the user can pick from: the bundled parameters_3e_<box code>.csv
    /// set (same files as the desktop app) plus any custom .csv imported this session.
    @Published private(set) var parameterFiles: [HslParameterFile] = HslParameterFiles.bundled()
    /// Nothing is selected by default on purpose - the right file depends on the
    /// ECU's software version, and the wrong one reads the wrong memory addresses.
    @Published private(set) var selectedFile: HslParameterFile?
    /// Every row of the selected file, in file order (physical and calculated).
    @Published private(set) var parameters: [HslPid] = []

    private weak var transport: UdsTransport?
    private weak var hslTransport: HslRawTransport?
    private var uds: UdsClient?
    private var task: Task<Void, Never>?
    /// The polled (non-virtual) rows actually sent to the ECU, in file order.
    /// Response bytes are decoded positionally against exactly this list.
    private var pids: [HslPid] = []
    private var variables: [String: Double] = [:]
    private var rawVariables: [String: Double] = [:]

    /// Every `samples.append` is a `@Published` change that drives a full Swift
    /// Charts re-render, which is expensive enough that doing it many times a
    /// second backed up the main thread and eventually got the app killed as
    /// unresponsive. Recording continues at whatever rate the poll loop achieves;
    /// only the *publish* of new samples (what makes the chart re-render) is
    /// capped to `samplesPublishInterval`.
    private var pendingSamples: [HslLogSample] = []
    private var lastSamplesFlush = Date.distantPast
    private var lastLatestValuesPublish = Date.distantPast
    private let samplesPublishInterval: TimeInterval = 0.2
    private var logFileURL: URL?

    var selectedPids: [HslPid] {
        parameters.filter { selectedNames.contains($0.name) }
    }

    // MARK: Parameter file selection

    /// Names pre-checked after a file is chosen (only those the file contains).
    private static let preferredDefaultNames = [
        "Engine Speed", "MAP", "PUT", "Lambda", "Torque", "Pedal Pos", "IAT", "Coolant Temp"
    ]

    func selectParameterFile(_ file: HslParameterFile) {
        guard !isRunning, !isStarting else { return }
        do {
            let loaded = try HslParameterFiles.load(file)
            clear()
            parameters = loaded
            selectedFile = file
            let physicalNames = loaded.filter { !$0.isVirtual }.map(\.name)
            var chosen = Set(Self.preferredDefaultNames.filter { physicalNames.contains($0) })
            if chosen.isEmpty { chosen = Set(physicalNames.prefix(8)) }
            selectedNames = chosen
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importParameterFile(from url: URL) {
        guard !isRunning, !isStarting else { return }
        do {
            let file = try HslParameterFiles.importCustom(from: url)
            if let i = parameterFiles.firstIndex(where: { $0.id == file.id }) {
                parameterFiles[i] = file
            } else {
                parameterFiles.append(file)
            }
            selectParameterFile(file)
        } catch {
            lastError = "Could not import parameter file: \(error.localizedDescription)"
        }
    }

    func selectAllChannels() { selectedNames = Set(parameters.map(\.name)) }
    func selectNoChannels() { selectedNames = [] }

    var duration: TimeInterval {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    func attach(transport: UdsTransport) {
        // DatalogView is created after LoggingMenuView acquires HSL ownership.
        // Do NOT call stop() here: stop() releases the shared GVRET HSL lock,
        // which races the ownership acquired immediately before navigation and
        // can make the first/next logger start lose its transport mid-session.
        // Only stop if a genuinely different transport is being attached.
        if let current = self.transport, current !== transport {
            self.stop()
        }
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
        guard selectedFile != nil, !parameters.isEmpty else {
            lastError = HslError.noParameterFile.localizedDescription
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
            // HSL must own the shared 0x7E0/0x7E8 transaction path for the
            // entire setup + polling session. GVRET uses a real exclusive
            // lock; other transports receive the protocol default no-op.
            await self.transport?.beginHslExclusive()
            do {
                // Mirror the desktop SimosHslLogger: the ECU's HSL list is EVERY
                // polled (non-virtual) row of the selected parameter file, in file
                // order, sent in one 3E02 setup request. Response bytes are then
                // decoded positionally against this same list. The channel picker
                // only filters what is displayed/exported - it never changes this.
                self.pids = self.parameters.filter { !$0.isVirtual && $0.length >= 1 && $0.length <= 4 }
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
            await self.transport?.endHslExclusive()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        isStarting = false
        isConfigured = false

        // Cancellation alone does not interrupt an ISO-TP receive continuation.
        // Release it synchronously while this @MainActor session still owns the
        // transport, then release the HSL lock. The old implementation queued
        // both operations in a detached Task; a fast Stop -> Start could therefore
        // run the new HSL transaction before the old cleanup task, leaving the new
        // request blocked or causing the lock to be released underneath it.
        transport?.abandonPendingOperation()
        transport?.endHslExclusive()
    }
    func clear() {
        samples.removeAll()
        pendingSamples.removeAll()
        lastSamplesFlush = .distantPast
        latestValues.removeAll()
        lastLatestValuesPublish = .distantPast
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
        // One 3E02 setup request, one attempt - same as the desktop logger. There is
        // deliberately no fallback list and no retry loop: re-sending 3E02 can leave a
        // patched ECU in an ambiguous HSL state, and a hardcoded fallback list would
        // use addresses that only match one ECU software version.
        guard !pids.isEmpty else { throw HslError.noChannels }
        try await sendHslSetup(for: pids)
    }

    private func sendHslSetup(for setupPids: [HslPid]) async throws {
        var parameterList = Data()
        for pid in setupPids {
            parameterList.append(UInt8(pid.length & 0x0F))
            parameterList.append(UInt8((pid.address >> 24) & 0xFF))
            parameterList.append(UInt8((pid.address >> 16) & 0xFF))
            parameterList.append(UInt8((pid.address >> 8) & 0xFF))
            parameterList.append(UInt8(pid.address & 0xFF))
        }
        parameterList.append(0x00)

        let offset: UInt32 = 0xB001E700
        let count = UInt16(parameterList.count)
        var request = Data([
            0x3E, 0x02,
            UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF),
            UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)
        ])
        request.append(parameterList)

        print("HSL setup [\(selectedFile?.displayName ?? "?"), \(setupPids.count) params, \(parameterList.count) list bytes]: \(hex(request))")
        let response = try await sendHsl(request, expectedPayloadBytes: 0, timeoutSeconds: hslSetupTimeoutSeconds)
        guard response.first == 0x7E else {
            throw HslError.invalidSetupResponse(hex(response))
        }
        print("HSL setup acknowledged: \(hex(response))")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                let request = Data([0x3E, 0x04,
                                    UInt8((0xB001E700 >> 24) & 0xFF), UInt8((0xB001E700 >> 16) & 0xFF),
                                    UInt8((0xB001E700 >> 8) & 0xFF), UInt8(0xB001E700 & 0xFF),
                                    0xFF, 0xFF])
                let expectedBytes = pids.reduce(0) { $0 + $1.length }
                let response = try await sendHsl(request, expectedPayloadBytes: expectedBytes, timeoutSeconds: hslPollTimeoutSeconds)
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
                pendingSamples.append(HslLogSample(timestamp: now, values: values))
                latestValues = values
                lastError = nil
                // Flush into the published `samples` (and therefore the
                // chart) at most every samplesPublishInterval, not on every
                // single poll - see the comment on these properties above.
                if now.timeIntervalSince(lastSamplesFlush) >= samplesPublishInterval {
                    samples.append(contentsOf: pendingSamples)
                    pendingSamples.removeAll(keepingCapacity: true)
                    if samples.count > 20_000 { samples.removeFirst(samples.count - 20_000) }
                    sampleCount = samples.count
                    lastSamplesFlush = now
                }
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
                continue
            } catch {
                lastError = error.localizedDescription
                // A transient transport error should not destroy a usable log. Back off briefly.
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            // Desktop behavior: pause pollDelayMs AFTER each completed poll
            // (Thread.Sleep(pollDelayMs) in Simos18LoggerControl.PollLoop).
            let delayMs = max(0, pollDelayMs)
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }
        // Flush anything recorded since the last publish - otherwise the
        // final fraction-of-a-second of samples would be silently dropped
        // from both the chart and CSV export just because the loop ended
        // before the next scheduled flush.
        if !pendingSamples.isEmpty {
            samples.append(contentsOf: pendingSamples)
            pendingSamples.removeAll(keepingCapacity: true)
            if samples.count > 20_000 { samples.removeFirst(samples.count - 20_000) }
            sampleCount = samples.count
        }
        isRunning = false
    }

    /// The one-time 3E02 setup transaction sends the whole parameter file's polled
    /// list (68 entries / ~350 request bytes for the bundled files) and the ECU has
    /// to build its memory-read list before it can ack - noticeably slower than any
    /// single 3E04 poll. Give the setup phase much more room than a poll needs, since
    /// a slow-but-eventually-successful ack is a very different failure than a
    /// wedged connection.
    private let hslSetupTimeoutSeconds: Double = 15.0
    /// Each 3E04 poll only reads back the already-built list - much
    /// smaller/faster than setup - so it keeps a short timeout so a single
    /// dropped poll doesn't stall the whole logging loop for 15s.
    private let hslPollTimeoutSeconds: Double = 4.0

    private func sendHsl(_ request: Data, expectedPayloadBytes: Int, timeoutSeconds: Double) async throws -> Data {
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
            if pid.length == 4 {
                // HSL uses IEEE-754 single precision for 4-byte float PIDs.
                // Decode the bit pattern without any trapping integer conversion.
                var bits: UInt32 = 0
                for (i, b) in rawBytes.enumerated() {
                    bits |= UInt32(b) << UInt32(i * 8)
                }
                let floatValue = Float(bitPattern: bits)
                // The ECU list is now the whole parameter file, not just the handful of
                // channels on screen. One garbage float (NaN/inf) in a channel nobody is
                // looking at must not throw away the entire poll, so skip just that
                // channel; the stream position has already advanced past it.
                guard floatValue.isFinite else { continue }
                raw = Double(floatValue)
            } else {
                var value: UInt64 = 0
                for (i, b) in rawBytes.enumerated() {
                    value |= UInt64(b) << UInt64(i * 8)
                }
                if pid.signed {
                    // IMPORTANT: never use Int64(unsignedValue) after manual
                    // sign extension. That initializer traps when the high bit
                    // is set. Use a bit-pattern conversion instead. This is a
                    // likely cause of the EXC_BREAKPOINT reported in
                    // HslLoggerSession.decode() when a value crosses through a
                    // negative signed range during an engine rev.
                    let bitCount = pid.length * 8
                    let signedValue: Int64
                    if bitCount == 64 {
                        signedValue = Int64(bitPattern: value)
                    } else {
                        let signBit = UInt64(1) << UInt64(bitCount - 1)
                        if (value & signBit) != 0 {
                            let mask = ~UInt64(0) << UInt64(bitCount)
                            signedValue = Int64(bitPattern: value | mask)
                        } else {
                            signedValue = Int64(value)
                        }
                    }
                    raw = Double(signedValue)
                } else {
                    raw = Double(value)
                }
            }
            rawVariables[pid.name.lowercased()] = raw
            if let assignment = pid.assignment { variables[assignment.lowercased()] = raw }
            do {
                let scaled = try EquationEvaluator.evaluate(pid.equation, variables: variables.merging(["x": raw]) { _, new in new })
                guard scaled.isFinite else {
                    throw HslError.invalidNumericValue(pid: pid.name, reason: "equation produced NaN/infinity")
                }
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
            for pid in parameters where pid.isVirtual {
                if pid.equation == "hp" || pid.equation == "tq" || pid.equation == "speed_zero_sixty" || pid.equation == "speed_sixty_onethirty" || pid.equation == "dist_zero_sixty" || pid.equation == "dist_emile" || pid.equation == "dist_qmile" {
                    continue
                }
                if let value = try? EquationEvaluator.evaluate(pid.equation, variables: resolved), value.isFinite {
                    resolved[pid.name.lowercased()] = value
                }
            }
        }

        if let tq = resolved["tq_eng"] ?? resolved["tq"], let rpm = resolved["rpm"] {
            resolved["tq"] = tq
            resolved["hp"] = tq * rpm / 7127.0
        }
        for pid in parameters where pid.isVirtual {
            if let value = resolved[pid.name.lowercased()] { variables[pid.name.lowercased()] = value }
        }

        var output: [String: Double] = [:]
        for pid in parameters where selectedNames.contains(pid.name) {
            if let value = variables[pid.name.lowercased()], value.isFinite {
                output[pid.name] = value
            }
        }
        guard !output.isEmpty else {
            throw HslError.invalidPollResponse("HSL decoder produced no valid values from \(bytes.count) bytes")
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
        case invalidNumericValue(pid: String, reason: String)
        case noChannels
        case noParameterFile
        case noTransport
        case transportNotExclusive
        var errorDescription: String? {
            switch self {
            case .invalidSetupResponse(let value): return "HSL setup failed. ECU response: \(value)"
            case .invalidPollResponse(let value): return "HSL read returned an unexpected response: \(value)"
            case .shortPollResponse(let expected, let got): return "HSL response was short: expected at least \(expected) bytes, received \(got)."
            case .invalidNumericValue(let pid, let reason): return "HSL decode rejected \(pid): \(reason)."
            case .noChannels: return "Select at least one HSL channel before starting the logger."
            case .noParameterFile: return "Select an HSL parameter file (the one matching your ECU software version) before starting the logger."
            case .noTransport: return "HSL logging is not available on the current transport."
            case .transportNotExclusive:
                return "HSL transport is not exclusively owned."
            }
        }
    }
}
