import Foundation

/// ISO 15765-2 (ISO-TP) - the standard way a UDS message larger than one
/// CAN frame's 8 data bytes gets split across multiple frames. Needed here
/// specifically because A0RET/GVRET (unlike the ESP32-ISOTP-BLE bridge or
/// ELM327 with CAF1) hands back raw CAN frames with no segmentation done
/// for us - this is a from-scratch implementation of a documented ISO
/// standard, not reverse-engineered.
///
/// One real assumption flagged here rather than silently baked in: outgoing
/// frames are padded to 8 bytes with 0xAA, matching the padding byte
/// convention used throughout the VW/Bosch ECU ecosystem (VW_Flash and
/// related tools consistently use 0xAA rather than 0x00) - unverified
/// against real hardware. If a real ECU turns out to care about the exact
/// padding byte (most don't - only frame length matters to the ISO-TP
/// layer itself), this is the first place to check.
enum IsoTp {
    static let paddingByte: UInt8 = 0xAA

    /// A hardware J2534 ISO-TP channel queues Consecutive Frames internally
    /// and can honor a 1-2ms STmin exactly. This app instead round-trips
    /// each frame through Swift -> TCP -> WiFi -> the A0/GVRET board's own
    /// firmware before it ever reaches the physical bus, and the firmware
    /// has to fully process one BUILD_CAN_FRAME command before it can
    /// accept the next. If that per-command handling takes longer than the
    /// gap we're leaving between frames, later frames in a burst can be
    /// dropped or corrupted before they're ever transmitted - and this
    /// would look identical regardless of how many frames are in the
    /// burst, since it's the gap that's too small, not the total count.
    /// This showed up as HSL setup silently never getting a response at
    /// all, at both 7 frames and 72 frames, despite every byte on the wire
    /// (per the debug log) being correct - the ECU's own requested STmin
    /// (commonly 2ms) is safe for a hardware dongle but may simply be
    /// faster than this WiFi bridge can sustain. A sender is always
    /// allowed to wait *longer* than the requested STmin per ISO 15765-2,
    /// so enforcing a floor here is spec-compliant, not a protocol
    /// violation - it costs at most a few hundred ms on the largest HSL
    /// requests, which is nothing against the 15s setup timeout.
    static let minimumSendIntervalSeconds: Double = 0.03

    /// A faster floor available ONLY to a caller that explicitly opts in via
    /// UdsTransport.setBulkTransferPacing (currently: just FlashBlockRunner's
    /// TransferData loop for a normal block flash - see its call site for
    /// the full reasoning and the honest caveats about this number).
    /// Deliberately NOT the default: minimumSendIntervalSeconds above stays
    /// the safe, unchanged, empirically-fixed-HSL-startup value everywhere
    /// else, including the CBOOT-patch write path (PatchBlockRunner), which
    /// is left alone on purpose.
    ///
    /// History: 5ms -> 3ms -> 2ms -> 1ms, each step only after real CAL
    /// flashes completed cleanly at the previous value on the target
    /// hardware. 1ms is close to a typical ECU-requested STmin territory -
    /// treat this as the last reasonable step down, not a new baseline to
    /// keep pushing from. The ECU's own requested STmin still wins
    /// whenever it's larger - see IsoTpSession.send.
    static let minimumFlashTransferIntervalSeconds: Double = 0.001

    enum ParsedFrame: Equatable {
        case singleFrame(data: [UInt8])
        case firstFrame(totalLength: Int, data: [UInt8])
        case consecutiveFrame(sequenceNumber: UInt8, data: [UInt8])
        case flowControl(status: UInt8, blockSize: UInt8, stMin: UInt8)
    }

    enum FlowStatus {
        static let continueToSend: UInt8 = 0
        static let wait: UInt8 = 1
        static let overflow: UInt8 = 2
    }

    /// Parses one CAN frame's data payload (up to 8 bytes) into its ISO-TP meaning.
    static func parseFrame(_ data: [UInt8]) -> ParsedFrame? {
        guard let first = data.first else { return nil }
        let pciType = (first >> 4) & 0xF

        switch pciType {
        case 0x0: // single frame
            let length = Int(first & 0xF)
            guard length > 0, data.count >= 1 + length else { return nil }
            return .singleFrame(data: Array(data[1..<(1 + length)]))

        case 0x1: // first frame
            guard data.count >= 2 else { return nil }
            let totalLength = (Int(first & 0xF) << 8) | Int(data[1])
            return .firstFrame(totalLength: totalLength, data: Array(data[2...]))

        case 0x2: // consecutive frame
            let seq = first & 0xF
            return .consecutiveFrame(sequenceNumber: seq, data: Array(data[1...]))

        case 0x3: // flow control
            guard data.count >= 3 else { return nil }
            return .flowControl(status: first & 0xF, blockSize: data[1], stMin: data[2])

        default:
            return nil
        }
    }

    /// Builds a single-frame CAN payload, or nil if the payload doesn't fit
    /// in one frame (7 usable bytes - classic/non-FD CAN, matching what
    /// GVRET/A0RET's raw-frame CAN0 actually carries).
    static func buildSingleFrame(_ payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= 7 else { return nil }
        var frame: [UInt8] = [UInt8(payload.count)]
        frame.append(contentsOf: payload)
        while frame.count < 8 { frame.append(paddingByte) }
        return frame
    }

    static func buildFirstFrame(totalLength: Int, first6Bytes: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [
            UInt8(0x10 | ((totalLength >> 8) & 0xF)),
            UInt8(totalLength & 0xFF),
        ]
        frame.append(contentsOf: first6Bytes)
        while frame.count < 8 { frame.append(paddingByte) }
        return frame
    }

    /// sequenceNumber wraps 1->15 then back to 0 (never starts a message at
    /// 0 - the first CF is always sequence 1, per ISO 15765-2).
    static func buildConsecutiveFrame(sequenceNumber: UInt8, dataChunk: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [UInt8(0x20 | (sequenceNumber & 0xF))]
        frame.append(contentsOf: dataChunk)
        while frame.count < 8 { frame.append(paddingByte) }
        return frame
    }

    static func buildFlowControl(status: UInt8 = FlowStatus.continueToSend, blockSize: UInt8 = 0, stMin: UInt8 = 0) -> [UInt8] {
        var frame: [UInt8] = [UInt8(0x30 | (status & 0xF)), blockSize, stMin]
        while frame.count < 8 { frame.append(paddingByte) }
        return frame
    }

    /// Splits a payload too large for one frame into (firstFrame,
    /// [consecutiveFrames]) - pure, no I/O, so this and buildSingleFrame are
    /// both directly unit-testable without any transport involved.
    static func segmentMultiFrame(_ payload: [UInt8]) -> (first: [UInt8], consecutive: [[UInt8]]) {
        let first6 = Array(payload.prefix(6))
        let firstFrame = buildFirstFrame(totalLength: payload.count, first6Bytes: first6)

        var consecutiveFrames: [[UInt8]] = []
        var remaining = Array(payload.dropFirst(6))
        var seq: UInt8 = 1
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(7))
            consecutiveFrames.append(buildConsecutiveFrame(sequenceNumber: seq, dataChunk: chunk))
            remaining.removeFirst(chunk.count)
            seq = (seq == 15) ? 0 : seq + 1
        }
        return (firstFrame, consecutiveFrames)
    }

    /// Converts a raw ISO-TP STmin byte into actual seconds to wait between
    /// consecutive frames, per ISO 15765-2: 0x00-0x7F = 0-127ms,
    /// 0xF1-0xF9 = 100-900 microseconds, anything else treated as 127ms
    /// (a conservative/safe fallback for a reserved/invalid value, not a
    /// literal reading of the spec's "undefined" case).
    static func stMinToSeconds(_ raw: UInt8) -> Double {
        if raw <= 0x7F { return Double(raw) / 1000.0 }
        if raw >= 0xF1, raw <= 0xF9 { return Double(raw - 0xF0) / 10000.0 }
        return 0.127
    }
}

/// Ties the pure ISO-TP framing above to an actual raw-CAN-frame send/receive
/// primitive (supplied by GvretWifiManager) to perform one full ISO-TP
/// request/response exchange, including flow control in both directions.
final class IsoTpSession {
    typealias SendFrame = (_ id: UInt32, _ data: [UInt8]) async throws -> Void
    typealias ReceiveFrame = (_ timeoutSeconds: Double) async throws -> [UInt8]? // nil = timed out

    private let sendFrame: SendFrame
    private let receiveFrame: ReceiveFrame

    init(sendFrame: @escaping SendFrame, receiveFrame: @escaping ReceiveFrame) {
        self.sendFrame = sendFrame
        self.receiveFrame = receiveFrame
    }

    enum IsoTpError: Error, LocalizedError {
        case timeout
        case flowControlOverflow
        case unexpectedFrame
        case sequenceMismatch(expected: UInt8, got: UInt8)

        var errorDescription: String? {
            switch self {
            case .timeout: return "Timed out waiting for a CAN frame."
            case .flowControlOverflow: return "ECU sent a Flow Control Overflow response."
            case .unexpectedFrame: return "Received an unexpected/malformed ISO-TP frame."
            case .sequenceMismatch(let expected, let got):
                return "ISO-TP consecutive frame out of sequence (expected \(expected), got \(got))."
            }
        }
    }

    /// Sends `payload` on `txID`, handling flow control (waiting for FC
    /// after the First Frame, respecting block size / STmin) if it doesn't
    /// fit in one frame.
    func send(_ payload: [UInt8], txID: UInt32, timeoutSeconds: Double, minimumInterval: Double = IsoTp.minimumSendIntervalSeconds) async throws {
        if let single = IsoTp.buildSingleFrame(payload) {
            try await sendFrame(txID, single)
            return
        }

        let (first, consecutive) = IsoTp.segmentMultiFrame(payload)
        try await sendFrame(txID, first)

        var remaining = consecutive[...]
        while !remaining.isEmpty {
            // Wait for Flow Control before sending the next batch.
            guard let fcData = try await receiveFrame(timeoutSeconds) else { throw IsoTpError.timeout }
            guard case .flowControl(let status, let blockSize, let stMin) = IsoTp.parseFrame(fcData) else {
                throw IsoTpError.unexpectedFrame
            }
            if status == IsoTp.FlowStatus.overflow { throw IsoTpError.flowControlOverflow }
            if status == IsoTp.FlowStatus.wait { continue } // ECU says wait - loop back and wait for the next FC

            let batchSize = blockSize == 0 ? remaining.count : Int(blockSize)
            let delay = max(IsoTp.stMinToSeconds(stMin), minimumInterval)

            // Block size 0 means the receiver grants the sender the entire
            // remaining message. A non-zero block size requires another FC
            // after that many consecutive frames. Keep the distinction exact.
            for _ in 0..<min(batchSize, remaining.count) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try await sendFrame(txID, remaining.first!)
                remaining = remaining.dropFirst()
            }
        }
    }

    /// Sends a multi-frame HSL payload using a dedicated transaction state
    /// machine. HSL traffic shares 0x7E8 with normal UDS traffic, so a frame
    /// on that ID is not automatically a Flow Control frame. We explicitly
    /// validate PCI type/status before allowing the Consecutive Frames out.
    ///
    /// The A0/GVRET bridge is substantially slower than a hardware J2534
    /// channel at accepting a burst of TCP writes. The ECU may advertise a
    /// smaller STmin (commonly 2 ms); the bridge therefore uses a conservative
    /// 30 ms floor for HSL. Waiting longer than the ECU-requested STmin is
    /// permitted by ISO-TP and materially reduces dropped CFs on this bridge.
    /// Note: a Flow Control frame `30 00 02` means BS=0 (unlimited) and
    /// STmin=2 ms. It does NOT mean BS=2.
    func sendHsl(_ payload: [UInt8], txID: UInt32, timeoutSeconds: Double) async throws {
        // V68 desktop-matched HSL ISO-TP sender marker.
        // Confirms the installed IPA includes negotiated-STmin pacing.
        if let single = IsoTp.buildSingleFrame(payload) {
            try await sendFrame(txID, single)
            return
        }

        let (first, consecutive) = IsoTp.segmentMultiFrame(payload)
        try await sendFrame(txID, first)

        var remaining = consecutive[...]
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var expectedSequence: UInt8 = 1
        var flowControlCount = 0

        while !remaining.isEmpty {
            let remainingTimeout = deadline.timeIntervalSinceNow
            guard remainingTimeout > 0 else { throw IsoTpError.timeout }

            guard let fcData = try await receiveFrame(remainingTimeout) else {
                throw IsoTpError.timeout
            }

            guard case .flowControl(let status, let blockSize, let stMin) =
                    IsoTp.parseFrame(fcData) else {
                // Ignore unrelated 0x7E8 traffic while waiting for FC.
                continue
            }

            flowControlCount += 1

            // ISO-TP FC layout is: status, block-size, STmin. For example
            // 30 00 02 = Continue-To-Send, BS=0 (unlimited), STmin=2 ms.
            // A0 therefore must send the complete remaining CF sequence for
            // that FC; waiting for another FC after two frames would be wrong.
            switch status {
            case IsoTp.FlowStatus.continueToSend:
                // IMPORTANT:
                // BS=0 means unlimited CFs under this FC.
                // BS>0 means EXACTLY that many CFs may be sent before another
                // FC is mandatory.
                let count = blockSize == 0
                    ? remaining.count
                    : min(Int(blockSize), remaining.count)

                // Match the desktop J2534 ISO-TP sender more closely: the ECU's
                // FC advertises STmin=2 ms (30 00 02). A J2534 driver paces CFs
                // internally at the negotiated rate, while the previous mobile
                // sender imposed an extra 30 ms floor on every CF. That adds a
                // large delay to setup-list transfer over raw GVRET and may cause
                // the ECU's HSL setup handler to discard the incomplete/late list.
                // TCP write completion still naturally limits how quickly the A0
                // bridge can accept each frame; do not add a second artificial floor.
                let delay = IsoTp.stMinToSeconds(stMin)

                for _ in 0..<count {
                    try Task.checkCancellation()

                    if delay > 0 {
                        try await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000.0)
                        )
                    }

                    guard let frame = remaining.first else {
                        break
                    }

                    let sequence = frame[0] & 0x0F
                    guard sequence == expectedSequence else {
                        throw IsoTpError.sequenceMismatch(
                            expected: expectedSequence,
                            got: sequence
                        )
                    }

                    try await sendFrame(txID, frame)
                    remaining = remaining.dropFirst()
                    expectedSequence = expectedSequence == 15 ? 0 : expectedSequence + 1
                }

                // With BS=2, this loop MUST come back around and receive
                // another FC before another CF is sent.
                // This is the behavior that was missing from the IPA that
                // produced the user's 21..27 burst.

            case IsoTp.FlowStatus.wait:
                continue

            case IsoTp.FlowStatus.overflow:
                throw IsoTpError.flowControlOverflow

            default:
                throw IsoTpError.unexpectedFrame
            }
        }

        // Keep the value live for diagnostics/debugger inspection and prevent
        // future optimization from making it disappear during debugging.
        _ = flowControlCount
    }

    /// Receives one full UDS message on `rxID` (as filtered by the caller's
    /// receiveFrame closure), sending Flow Control after a First Frame as needed.
    func receive(rxID: UInt32, txID: UInt32, timeoutSeconds: Double) async throws -> [UInt8] {
        guard let firstData = try await receiveFrame(timeoutSeconds) else { throw IsoTpError.timeout }

        switch IsoTp.parseFrame(firstData) {
        case .singleFrame(let data):
            return data

        case .firstFrame(let totalLength, let data):
            var collected = data
            // Send Flow Control: continue-to-send, no block-size limit, no
            // minimum separation time - we can keep up with whatever the ECU sends.
            try await sendFrame(txID, IsoTp.buildFlowControl(status: IsoTp.FlowStatus.continueToSend, blockSize: 0, stMin: 0))

            var expectedSeq: UInt8 = 1
            while collected.count < totalLength {
                guard let cfData = try await receiveFrame(timeoutSeconds) else { throw IsoTpError.timeout }
                guard case .consecutiveFrame(let seq, let chunk) = IsoTp.parseFrame(cfData) else {
                    throw IsoTpError.unexpectedFrame
                }
                guard seq == expectedSeq else { throw IsoTpError.sequenceMismatch(expected: expectedSeq, got: seq) }
                collected.append(contentsOf: chunk)
                expectedSeq = (expectedSeq == 15) ? 0 : expectedSeq + 1
            }
            return Array(collected.prefix(totalLength))

        default:
            throw IsoTpError.unexpectedFrame
        }
    }
}
