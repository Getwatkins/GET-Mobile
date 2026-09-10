import Foundation

/// GVRET binary protocol constants and framing, traced byte-for-byte from
/// the actual A0RET firmware source (collin80/A0RET, gvret_comm.cpp/.h) -
/// the same protocol SavvyCAN speaks to a Macchina A0 in WiFi mode. Unlike
/// the ESP32-ISOTP-BLE bridge or ELM327 (with CAF1 auto-formatting), this
/// firmware only passes raw CAN frames - no ISO-TP segmentation happens on
/// the device. See IsoTp.swift for the segmentation layer built on top.
enum GvretProtocol {
    static let tcpPort: UInt16 = 23

    /// Sending these two bytes switches the firmware into binary comm mode
    /// (useBinarySerialComm = true) - confirmed both from firmware source
    /// and from real SavvyCAN traffic logs ("Write to serial -> e7 e7 ...").
    static let binaryModeHandshake: [UInt8] = [0xE7, 0xE7]

    static let commandPrefix: UInt8 = 0xF1

    enum Command: UInt8 {
        case buildCanFrame = 0
        case timeSync = 1
        case digInputs = 2
        case anaInputs = 3
        case setDigOut = 4
        case setupCanbus = 5
        case getCanbusParams = 6
        case getDevInfo = 7
        case setSwMode = 8
        case keepAlive = 9
        case setSystype = 10
        case echoCanFrame = 11
        case getNumBuses = 12
        case getExtBuses = 13
        case setExtBuses = 14
    }

    /// A single raw CAN frame, as sent to or received from the device.
    struct CanFrame {
        var id: UInt32
        var extended: Bool
        var bus: UInt8
        var data: [UInt8]
    }

    /// Mirrors GET_COMMAND=SETUP_CANBUS's bit layout for build_int exactly:
    /// bit31 signals "enabled/listen-only flags below are valid", bit30 =
    /// enabled, bit29 = listen-only, low 20 bits = speed (capped at 1,000,000).
    static func setupCanbusPayload(bus0Speed: UInt32, bus0Enabled: Bool, bus1Speed: UInt32 = 0, bus1Enabled: Bool = false) -> [UInt8] {
        func encode(_ speed: UInt32, _ enabled: Bool) -> UInt32 {
            guard enabled else { return 0 }
            var value: UInt32 = min(speed, 1_000_000)
            value |= 0x80000000 // enabled/listen-only flags valid
            value |= 0x40000000 // enabled = true
            // bit 0x20000000 (listen-only) intentionally left clear - we need to transmit, not just sniff
            return value
        }

        let b0 = encode(bus0Speed, bus0Enabled)
        let b1 = encode(bus1Speed, bus1Enabled)

        var payload: [UInt8] = []
        payload.append(UInt8(b0 & 0xFF)); payload.append(UInt8((b0 >> 8) & 0xFF))
        payload.append(UInt8((b0 >> 16) & 0xFF)); payload.append(UInt8((b0 >> 24) & 0xFF))
        payload.append(UInt8(b1 & 0xFF)); payload.append(UInt8((b1 >> 8) & 0xFF))
        payload.append(UInt8((b1 >> 16) & 0xFF)); payload.append(UInt8((b1 >> 24) & 0xFF))
        return payload
    }

    static func setupCanbusCommand(bus0Speed: UInt32, bus0Enabled: Bool) -> [UInt8] {
        [commandPrefix, Command.setupCanbus.rawValue] + setupCanbusPayload(bus0Speed: bus0Speed, bus0Enabled: bus0Enabled)
    }

    /// Mirrors BUILD_CAN_FRAME's exact byte layout (gvret_comm.cpp case
    /// BUILD_CAN_FRAME): 4 ID bytes (LE, bit31 = extended flag) + 1 bus byte
    /// + 1 length byte + N data bytes + 1 terminator byte (unchecked by the
    /// firmware - any value works, it just needs to be present to advance
    /// the state machine to the send).
    static func buildCanFrameCommand(_ frame: CanFrame) -> [UInt8] {
        var id = frame.id & 0x7FFFFFFF
        if frame.extended { id |= 0x80000000 }

        var bytes: [UInt8] = [commandPrefix, Command.buildCanFrame.rawValue]
        bytes.append(UInt8(id & 0xFF))
        bytes.append(UInt8((id >> 8) & 0xFF))
        bytes.append(UInt8((id >> 16) & 0xFF))
        bytes.append(UInt8((id >> 24) & 0xFF))
        bytes.append(frame.bus & 0x3)
        bytes.append(UInt8(min(frame.data.count, 8)))
        bytes.append(contentsOf: frame.data.prefix(8))
        bytes.append(0x00) // terminator/checksum byte - unchecked by firmware
        return bytes
    }

    static func keepAliveCommand() -> [UInt8] { [commandPrefix, Command.keepAlive.rawValue] }
    static func getDevInfoCommand() -> [UInt8] { [commandPrefix, Command.getDevInfo.rawValue] }
    static func getNumBusesCommand() -> [UInt8] { [commandPrefix, Command.getNumBuses.rawValue] }

    /// Streaming parser for incoming bytes from the device - mirrors
    /// processIncomingByte's IDLE/GET_COMMAND/frame-body state machine.
    /// Every reply type this client's setup sequence can trigger has a
    /// specific, known length (confirmed against the firmware's actual
    /// reply-building code, not guessed) and must be fully consumed even
    /// though this client doesn't use the contents - skipping the wrong
    /// number of bytes here desyncs the whole stream from that point
    /// forward, since the next byte(s) of a longer-than-expected reply
    /// would otherwise be misread as the start of the next message.
    final class FrameParser {
        func reset() {
            state = .idle
            commandByte = 0
            body.removeAll(keepingCapacity: true)
            expectedBodyLength = 0
            skipRemaining = 0
        }

        private enum State { case idle, gotPrefix, frameBody, skipBody }
        private var state: State = .idle
        private var commandByte: UInt8 = 0
        private var body: [UInt8] = []
        private var expectedBodyLength = 0
        private var skipRemaining = 0

        // Reply lengths after F1 <command>. These are the bytes emitted by
        // A0RET for the commands used during initialization. CAN traffic can
        // arrive interleaved with these replies, so the parser must be able to
        // resynchronize when an arbitrary F1 00 occurs inside another frame.
        private static let knownReplyBodyLengths: [UInt8: Int] = [
            1: 4,   // TIME_SYNC
            6: 10,  // GET_CANBUS_PARAMS
            7: 6,   // GET_DEV_INFO
            9: 2,   // KEEPALIVE: DE AD
            12: 1,  // GET_NUMBUSES
            13: 15  // GET_EXT_BUSES
        ]

        func feed(_ byte: UInt8) -> CanFrame? {
            switch state {
            case .idle:
                if byte == GvretProtocol.commandPrefix { state = .gotPrefix }
                return nil

            case .gotPrefix:
                commandByte = byte
                if commandByte == 0 {
                    body.removeAll(keepingCapacity: true)
                    expectedBodyLength = 0
                    state = .frameBody
                } else if let length = Self.knownReplyBodyLengths[commandByte] {
                    if length == 0 { state = .idle }
                    else { skipRemaining = length; state = .skipBody }
                } else {
                    state = .idle
                }
                return nil

            case .skipBody:
                skipRemaining -= 1
                if skipRemaining <= 0 { state = .idle }
                return nil

            case .frameBody:
                body.append(byte)

                // timestamp[0..3], CAN ID[4..7], len/bus[8]
                if body.count == 9 {
                    let lenBus = body[8]
                    let dataLength = Int(lenBus & 0x0F)

                    // A valid classic CAN frame can only have 0...8 data bytes.
                    // This check is essential for stream resynchronization:
                    // arbitrary CAN payload/timestamp bytes may contain F1 00,
                    // which otherwise looks like a new GVRET frame prefix.
                    if dataLength > 8 {
                        if resynchronizeToEmbeddedFramePrefix() {
                            return finishIfComplete()
                        }
                        state = .idle
                        return nil
                    }

                    expectedBodyLength = 9 + dataLength + 1 // + checksum
                }

                if expectedBodyLength > 0 && body.count == expectedBodyLength {
                    let frame = Self.decodeFrameBody(body)
                    state = .idle
                    return frame
                }

                if body.count > 18 {
                    state = .idle
                }
                return nil
            }
        }

        /// If an F1 00 appeared inside a false candidate, promote the embedded
        /// F1 00 to the real frame prefix. This is needed because GVRET has no
        /// escaping; CAN timestamps/IDs/data are arbitrary bytes.
        private func resynchronizeToEmbeddedFramePrefix() -> Bool {
            guard body.count >= 2 else { return false }
            for i in 0..<(body.count - 1) where body[i] == 0xF1 && body[i + 1] == 0x00 {
                body = Array(body[(i + 2)...])
                expectedBodyLength = 0

                if body.count >= 9 {
                    let dataLength = Int(body[8] & 0x0F)
                    guard dataLength <= 8 else { return false }
                    expectedBodyLength = 9 + dataLength + 1
                }
                return true
            }
            return false
        }

        private func finishIfComplete() -> CanFrame? {
            guard expectedBodyLength > 0, body.count == expectedBodyLength else { return nil }
            let frame = Self.decodeFrameBody(body)
            state = .idle
            return frame
        }

        private static func decodeFrameBody(_ body: [UInt8]) -> CanFrame {
            precondition(body.count >= 10)
            let timestamp = UInt32(body[0]) |
                            (UInt32(body[1]) << 8) |
                            (UInt32(body[2]) << 16) |
                            (UInt32(body[3]) << 24)
            _ = timestamp

            var id = UInt32(body[4]) |
                      (UInt32(body[5]) << 8) |
                      (UInt32(body[6]) << 16) |
                      (UInt32(body[7]) << 24)
            let extended = (id & 0x80000000) != 0
            id &= 0x7FFFFFFF

            let lenBus = body[8]
            let length = Int(lenBus & 0x0F)
            let bus = (lenBus >> 4) & 0x0F
            let data = length > 0 ? Array(body[9..<(9 + length)]) : []
            return CanFrame(id: id, extended: extended, bus: bus, data: data)
        }
    }
}
