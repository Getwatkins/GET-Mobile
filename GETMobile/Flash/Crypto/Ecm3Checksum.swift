import Foundation

/// Port of Communication/Simos18/Crypto/Ecm3Checksum.cs: the ECM3
/// CAL-monitoring checksum. A separate 64-bit summation checksum some Simos
/// ECUs actively verify against CAL at runtime, independent of the per-block
/// CRC32 in BlockChecksum.
///
/// The address locations to sum are found one of two ways:
///   - If both ASW1 and CAL are available: read the checksummed address
///     ranges out of ASW1 (or, on newer ECUs, out of CAL itself if present
///     there) - see locateEcm3WithAsw1.
///   - If only CAL is available: look up pre-recorded addresses from the
///     bundled box_codes.csv database, keyed by the CAL's embedded software
///     version string - see loadEcm3Location.
enum Ecm3Checksum {
    enum Ecm3Error: Error, LocalizedError {
        case couldNotLocateAddresses
        var errorDescription: String? {
            "Could not locate ECM3 checksum addresses (still negative after early-ECU retry). This CAL/ASW1 pairing may use a format this port doesn't recognize."
        }
    }

    /// Mirrors locate_ecm3_with_asw1(). Returns relative byte offsets into
    /// the CAL block's data, alternating [start, end, start, end, ...] for
    /// each checksummed area.
    static func locateEcm3WithAsw1(
        ecm3CalMonitorChecksum: Int,
        ecm3CalMonitorAddressesEarly: Int,
        ecm3CalMonitorAddresses: Int,
        ecm3CalMonitorOffsetUncached: Int64,
        ecm3CalMonitorOffsetCached: Int64,
        asw1Bytes: [UInt8],
        calBytes: [UInt8],
        calBaseAddress: UInt32,
        isEarly: Bool = false
    ) throws -> [Int64] {
        let checksumLocationCal = ecm3CalMonitorChecksum

        let checksumAreaCount = readUInt32LE(calBytes, checksumLocationCal + 16)
        let calAddress = readUInt32LE(calBytes, checksumLocationCal + 24)

        let checksumAddressLocation: Int
        let dataBinaryEcm3Addresses: [UInt8]

        if calAddress > 0 {
            checksumAddressLocation = checksumLocationCal + 24
            dataBinaryEcm3Addresses = calBytes
        } else {
            checksumAddressLocation = isEarly ? ecm3CalMonitorAddressesEarly : ecm3CalMonitorAddresses
            dataBinaryEcm3Addresses = asw1Bytes
        }

        var addresses: [Int64] = []
        for i in 0..<Int(checksumAreaCount * 2) {
            let address = readUInt32LE(dataBinaryEcm3Addresses, checksumAddressLocation + (i * 4))
            var offset = Int64(address) + ecm3CalMonitorOffsetUncached - Int64(calBaseAddress)
            if offset < 0 {
                offset = Int64(address) + ecm3CalMonitorOffsetCached - Int64(calBaseAddress)
            }
            addresses.append(offset)
        }

        if let first = addresses.first, first < 0 {
            if isEarly {
                // Python recurses into is_early=True unconditionally whenever
                // addresses[0] < 0, with no check for "already tried that" -
                // if the early variant is also negative, it recurses forever
                // until Python's (catchable) RecursionError kills it. Swift
                // has no equivalent safety net for unbounded recursion, so
                // this throws a normal, catchable error instead once the
                // early retry has already been tried and still doesn't resolve.
                throw Ecm3Error.couldNotLocateAddresses
            }
            return try locateEcm3WithAsw1(
                ecm3CalMonitorChecksum: ecm3CalMonitorChecksum,
                ecm3CalMonitorAddressesEarly: ecm3CalMonitorAddressesEarly,
                ecm3CalMonitorAddresses: ecm3CalMonitorAddresses,
                ecm3CalMonitorOffsetUncached: ecm3CalMonitorOffsetUncached,
                ecm3CalMonitorOffsetCached: ecm3CalMonitorOffsetCached,
                asw1Bytes: asw1Bytes, calBytes: calBytes, calBaseAddress: calBaseAddress, isEarly: true)
        }

        return addresses
    }

    /// Mirrors load_ecm3_location(): reads the CAL's software version string, then looks it up in the CSV database.
    static func loadEcm3Location(calBytes: [UInt8], softwareVersionLocationCal: (start: Int, end: Int), boxCodesCsvPath: String) -> [Int64]? {
        let length = softwareVersionLocationCal.end - softwareVersionLocationCal.start
        let slice = calBytes[softwareVersionLocationCal.start..<(softwareVersionLocationCal.start + length)]
        let calVersion = String(decoding: slice, as: UTF8.self)
        return loadEcm3FromCsv(calVersion: calVersion, boxCodesCsvPath: boxCodesCsvPath)
    }

    /// Mirrors load_ecm3_from_csv(): looks up the first row whose cal_version matches.
    static func loadEcm3FromCsv(calVersion: String, boxCodesCsvPath: String) -> [Int64]? {
        for row in readCsvRows(path: boxCodesCsvPath) {
            if let version = row["cal_version"], version == calVersion {
                guard let start = Int64(row["ecm3_address_start"] ?? ""),
                      let end = Int64(row["ecm3_address_end"] ?? "") else { return nil }
                return [start, end]
            }
        }
        return nil
    }

    /// Mirrors validate_ecm3(). addresses alternates [start, end, start, end, ...]
    /// byte offsets into calBytes to sum as little-endian 32-bit words. The
    /// checksum is stored as a 64-bit big-half/little-half pair of 32-bit
    /// little-endian words (not a single 64-bit little-endian value) -
    /// preserved exactly since that's what the embedded format actually is.
    static func validateEcm3(
        addresses: [Int64],
        dataBinaryCal: [UInt8],
        ecm3CalMonitorChecksum: Int,
        shouldFix: Bool = false
    ) -> (state: ChecksumState, data: [UInt8]) {
        var checksumLocationCal = ecm3CalMonitorChecksum

        var checksum = UInt64(readUInt32LE(dataBinaryCal, checksumLocationCal + 8)) << 32
        checksum += UInt64(readUInt32LE(dataBinaryCal, checksumLocationCal + 12))

        var i = 0
        while i < addresses.count {
            let startAddress = addresses[i]
            let endAddress = addresses[i + 1]
            var j = startAddress
            while j < endAddress {
                let addValue = readUInt32LE(dataBinaryCal, Int(j))
                checksum &+= UInt64(addValue) // realistic block sizes never approach 2^64, so no wraparound-mismatch risk vs. Python's unbounded int
                j += 4
            }
            i += 2
        }

        // "Oldschool" ECM3 calculation has the checksum in a different place.
        if dataBinaryCal[checksumLocationCal + 56] > 0 {
            checksumLocationCal += 56
        }

        var checksumCurrent = UInt64(readUInt32LE(dataBinaryCal, checksumLocationCal)) << 32
        checksumCurrent += UInt64(readUInt32LE(dataBinaryCal, checksumLocationCal + 4))

        if checksumCurrent == checksum {
            return (.validChecksum, dataBinaryCal)
        } else {
            if shouldFix {
                var result = dataBinaryCal
                writeUInt32LE(&result, checksumLocationCal, UInt32(checksum >> 32))
                writeUInt32LE(&result, checksumLocationCal + 4, UInt32(checksum & 0xFFFFFFFF))
                return (.fixedChecksum, result)
            } else {
                return (.invalidChecksum, dataBinaryCal)
            }
        }
    }

    /// Minimal RFC4180-style CSV reader (handles quoted fields containing commas).
    private static func readCsvRows(path: String) -> [[String: String]] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }
        let headers = parseCsvLine(lines.removeFirst())

        var rows: [[String: String]] = []
        for line in lines {
            if line.isEmpty { continue }
            let fields = parseCsvLine(line)
            var row: [String: String] = [:]
            for i in 0..<min(headers.count, fields.count) {
                row[headers[i]] = fields[i]
            }
            rows.append(row)
        }
        return rows
    }

    private static func parseCsvLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    private static func readUInt32LE(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
