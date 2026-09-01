import Foundation

/// A decoded ble_header_t (8 bytes, little-endian - ESP32 is little-endian):
///   uint8  hdID
///   uint8  cmdFlags
///   uint16 rxID
///   uint16 txID
///   uint16 cmdSize   (payload length AFTER the header, not including it)
struct BridgeHeader {
    var hdID: UInt8
    var cmdFlags: UInt8
    var rxID: UInt16
    var txID: UInt16
    var cmdSize: UInt16

    static let byteSize = 8

    init(hdID: UInt8, cmdFlags: UInt8, rxID: UInt16, txID: UInt16, cmdSize: UInt16) {
        self.hdID = hdID; self.cmdFlags = cmdFlags; self.rxID = rxID; self.txID = txID; self.cmdSize = cmdSize
    }

    /// Parses the first 8 bytes of `data` as a ble_header_t. Caller must
    /// ensure data.count >= 8.
    init(parsing data: Data) {
        let bytes = [UInt8](data)
        hdID = bytes[0]
        cmdFlags = bytes[1]
        rxID = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        txID = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        cmdSize = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
    }

    /// Serializes to the 8-byte wire form.
    var encoded: Data {
        var d = Data(capacity: 8)
        d.append(hdID)
        d.append(cmdFlags)
        d.append(UInt8(rxID & 0xFF)); d.append(UInt8((rxID >> 8) & 0xFF))
        d.append(UInt8(txID & 0xFF)); d.append(UInt8((txID >> 8) & 0xFF))
        d.append(UInt8(cmdSize & 0xFF)); d.append(UInt8((cmdSize >> 8) & 0xFF))
        return d
    }
}

/// Builds the list of BLE writes needed to send one request, fragmenting
/// exactly the way the firmware's own send path does (ble_server.c
/// send_task): if header+payload fits in one ATT write, send it whole;
/// otherwise send a first frame (header + partial payload, flagSplitPacket
/// set) followed by [0xF2][chunk_num] continuation frames.
enum BridgeFrameEncoder {
    static func buildFrames(rxID: UInt16, txID: UInt16, cmdFlags: UInt8, payload: Data, attMTU: Int) -> [Data] {
        let attCapacity = max(attMTU - 3, BridgeHeader.byteSize + 1) // ATT payload budget, mirrors firmware's `spp_mtu_size - 3`
        let headerSize = BridgeHeader.byteSize

        if headerSize + payload.count <= attCapacity {
            let header = BridgeHeader(hdID: BridgeProtocol.headerID, cmdFlags: cmdFlags,
                                       rxID: rxID, txID: txID, cmdSize: UInt16(payload.count))
            return [header.encoded + payload]
        }

        var frames: [Data] = []
        let firstPayloadLen = attCapacity - headerSize
        let header = BridgeHeader(hdID: BridgeProtocol.headerID, cmdFlags: cmdFlags | BridgeProtocol.flagSplitPacket,
                                   rxID: rxID, txID: txID, cmdSize: UInt16(payload.count))
        frames.append(header.encoded + payload.prefix(firstPayloadLen))

        var pos = firstPayloadLen
        var chunkNum: UInt8 = 1
        let chunkCapacity = attCapacity - 2
        while pos < payload.count {
            let len = min(chunkCapacity, payload.count - pos)
            var chunk = Data([BridgeProtocol.partialID, chunkNum])
            chunk.append(payload[payload.startIndex.advanced(by: pos)..<payload.startIndex.advanced(by: pos + len)])
            frames.append(chunk)
            pos += len
            chunkNum = chunkNum &+ 1
        }
        return frames
    }
}

/// Reassembles incoming notifications from the Data Notify (0xABF2) or
/// Command Notify (0xABF4) characteristic, mirroring isotp_bridge.c's
/// packet_received/split_* state machine exactly: a fresh frame starts with
/// hdID 0xF1; if flagSplitPacket is set, continuation frames follow, each
/// beginning with [0xF2][chunk_num] where chunk_num counts up from 1.
/// A gap or out-of-order chunk drops the whole in-progress message, same as
/// the firmware does - there is no retry in this protocol.
final class BridgeFrameReassembler {
    private var pendingHeader: BridgeHeader?
    private var pendingPayload = Data()
    private var expectedChunkNum: UInt8 = 1

    /// Feed one raw notification payload in. Returns the completed
    /// (header, payload) pair once a full message has been reassembled,
    /// or nil if more chunks are still expected / the chunk was invalid.
    func feed(_ data: Data) -> (header: BridgeHeader, payload: Data)? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)

        if bytes[0] == BridgeProtocol.partialID, pendingHeader != nil {
            guard data.count >= 2, bytes[1] == expectedChunkNum else {
                pendingHeader = nil; pendingPayload.removeAll(); return nil // out of order - drop, matches firmware
            }
            pendingPayload.append(data.suffix(from: data.startIndex.advanced(by: 2)))
            expectedChunkNum = expectedChunkNum &+ 1

            guard let header = pendingHeader else { return nil }
            if pendingPayload.count == Int(header.cmdSize) {
                pendingHeader = nil
                let result = (header, pendingPayload)
                pendingPayload = Data()
                return result
            } else if pendingPayload.count > Int(header.cmdSize) {
                pendingHeader = nil; pendingPayload.removeAll() // oversized - drop, matches firmware
            }
            return nil
        }

        guard data.count >= BridgeHeader.byteSize else { return nil }
        let header = BridgeHeader(parsing: data)
        guard header.hdID == BridgeProtocol.headerID else { return nil }
        let payloadSoFar = data.suffix(from: data.startIndex.advanced(by: BridgeHeader.byteSize))

        if header.cmdFlags & BridgeProtocol.flagSplitPacket != 0 {
            pendingHeader = header
            pendingPayload = Data(payloadSoFar)
            expectedChunkNum = 1
            return nil
        } else {
            return (header, Data(payloadSoFar))
        }
    }
}
