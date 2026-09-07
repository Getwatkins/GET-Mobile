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
    /// processIncomingByte's IDLE/GET_COMMAND/frame-body state machine, but
    /// only for the one reply type this app actually needs to read back:
    /// incoming CAN frames (frame type 0). Other reply types (dev info,
    /// canbus params, keepalive ack, etc.) are recognized and skipped
    /// rather than decoded, since nothing here currently needs them beyond
    /// initial setup acknowledgement.
    final class FrameParser {
        private enum State { case idle, gotPrefix, frameBody }
        private var state: State = .idle
        private var commandByte: UInt8 = 0
        private var body: [UInt8] = []
        private var expectedBodyLength = 0

        /// Feed one incoming byte. Returns a decoded CanFrame whenever a
        /// complete "incoming canbus frame" (command byte 0) message finishes.
        func feed(_ byte: UInt8) -> CanFrame? {
            switch state {
            case .idle:
                if byte == GvretProtocol.commandPrefix {
                    state = .gotPrefix
                }
                // Any other byte (including a stray 0xE7 echo) is plain
                // text-console output in this mode and is ignored - we
                // never operate in LAWICEL/text mode from this client.
                return nil

            case .gotPrefix:
                commandByte = byte
                if commandByte == 0 {
                    // Incoming CAN frame: 4 timestamp + 4 id + 1 lenbus + data(len) + 1 checksum
                    body = []
                    expectedBodyLength = 4 + 4 + 1 // up to and including the length/bus byte; data+checksum length is data-dependent, resolved once we've read the length byte
                    state = .frameBody
                } else {
                    // Not a frame - these replies are fixed/short and not
                    // needed by this client; drop back to idle immediately
                    // rather than trying to track every reply's exact length.
                    state = .idle
                }
                return nil

            case .frameBody:
                body.append(byte)
                // Once we have the 9 header bytes (4 timestamp + 4 id + 1 lenbus),
                // we know the total remaining length (data + 1 checksum byte).
                if body.count == 9 {
                    let lenBus = body[8]
                    let dataLen = Int(lenBus & 0xF)
                    expectedBodyLength = 9 + dataLen + 1
                }
                if body.count >= expectedBodyLength, expectedBodyLength > 9 {
                    let frame = Self.decodeFrameBody(body)
                    state = .idle
                    return frame
                }
                if body.count > 64 { // safety valve against a corrupt/never-terminating stream
                    state = .idle
                }
                return nil
            }
        }

        private static func decodeFrameBody(_ body: [UInt8]) -> CanFrame {
            // body[0..3] = timestamp (unused here), body[4..7] = CAN ID (LE, bit31 = extended)
            var id = UInt32(body[4]) | (UInt32(body[5]) << 8) | (UInt32(body[6]) << 16) | (UInt32(body[7]) << 24)
            let extended = (id & 0x80000000) != 0
            id &= 0x7FFFFFFF
            let lenBus = body[8]
            let length = Int(lenBus & 0xF)
            let bus = (lenBus >> 4) & 0x3
            let data = Array(body[9..<(9 + length)])
            return CanFrame(id: id, extended: extended, bus: bus, data: data)
        }
    }
}
