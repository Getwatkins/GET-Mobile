import Foundation

/// One row of an HSL logger parameter file. Same columns the desktop app's
/// LogParameterCsvLoader reads (Name, Unit, Equation, Address, Length, Signed,
/// ProgMin, ProgMax, Assign To); everything else in the CSV is ignored.
///
/// This used to be defined next to a hardcoded, S50-only catalog
/// (HslPidCatalog). The catalog is gone: every address now comes from the
/// parameter file the user selects, exactly like the desktop logger.
struct HslPid: Identifiable, Hashable {
    /// Position in the file. Part of `id` so a custom file that repeats a name
    /// still produces unique SwiftUI identities.
    let index: Int
    let name: String
    let unit: String
    let equation: String
    let address: UInt32
    let length: Int
    let signed: Bool
    let min: Double
    let max: Double
    let assignment: String?
    let enabled: Bool

    var id: String { "\(index)-\(name)" }

    /// Matches desktop LogParameter.Virtual: address 0xFFFF or 0xFFFFFFFF means
    /// "never read from the ECU - value comes entirely from the equation".
    var isVirtual: Bool { address == 0xFFFF_FFFF || address == 0xFFFF }
}

/// A selectable parameter file - the iOS counterpart of one entry in the
/// desktop Simos18LoggerControl "Parameter File" dropdown.
struct HslParameterFile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let url: URL
    let isCustom: Bool
}

enum HslParameterFileError: Error, LocalizedError {
    case unreadable(String)
    case noUsableParameters(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read parameter file \"\(name)\"."
        case .noUsableParameters(let name):
            return "Parameter file \"\(name)\" didn't produce any usable parameters."
        }
    }
}

enum HslParameterFiles {
    /// The files bundled with the app are the same `parameters_3e_<box code>.csv`
    /// files the desktop app ships (one per ECU software version - addresses
    /// differ between them, so picking the wrong one reads the wrong memory).
    /// `parameters_22.csv` is deliberately not bundled: that's the desktop's
    /// mode-22 file, and mode 22 is the Standard Logger on mobile.
    private static let bundledPrefix = "parameters_3e_"

    static func bundled() -> [HslParameterFile] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: nil) ?? []
        return urls
            .filter { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(bundledPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                HslParameterFile(id: "bundled:" + $0.lastPathComponent,
                                 displayName: $0.lastPathComponent,
                                 url: $0,
                                 isCustom: false)
            }
    }

    /// Copies a user-picked .csv into the app's caches folder so it stays
    /// readable after the document picker's security scope ends (mirrors the
    /// desktop "Browse for custom .csv..." button).
    static func importCustom(from source: URL) throws -> HslParameterFile {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let dir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HslCustomParams", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)

        return HslParameterFile(id: "custom:" + source.lastPathComponent,
                                displayName: "(custom) " + source.lastPathComponent,
                                url: dest,
                                isCustom: true)
    }

    /// Port of desktop LogParameterCsvLoader.Load().
    static func load(_ file: HslParameterFile) throws -> [HslPid] {
        var text: String
        if let utf8 = try? String(contentsOf: file.url, encoding: .utf8) {
            text = utf8
        } else if let latin1 = try? String(contentsOf: file.url, encoding: .isoLatin1) {
            text = latin1
        } else {
            throw HslParameterFileError.unreadable(file.displayName)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first else {
            throw HslParameterFileError.noUsableParameters(file.displayName)
        }

        var column: [String: Int] = [:]
        for (i, h) in parseCsvLine(headerLine).enumerated() {
            column[h.trimmingCharacters(in: .whitespaces)] = i
        }
        guard column["Name"] != nil, column["Address"] != nil else {
            throw HslParameterFileError.noUsableParameters(file.displayName)
        }

        func field(_ fields: [String], _ key: String) -> String? {
            guard let i = column[key], i < fields.count else { return nil }
            return fields[i]
        }

        var result: [HslPid] = []
        for line in lines.dropFirst() {
            let fields = parseCsvLine(line)

            guard let rawName = field(fields, "Name"),
                  !rawName.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let name = rawName.trimmingCharacters(in: .whitespaces)

            let address = parseAddress(field(fields, "Address") ?? "0")
            let length = Int((field(fields, "Length") ?? "").trimmingCharacters(in: .whitespaces)) ?? 1
            let signed = (field(fields, "Signed") ?? "").trimmingCharacters(in: .whitespaces).uppercased() == "TRUE"
            let progMin = Double((field(fields, "ProgMin") ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
            let progMax = Double((field(fields, "ProgMax") ?? "").trimmingCharacters(in: .whitespaces)) ?? 0

            var equation = (field(fields, "Equation") ?? "x").trimmingCharacters(in: .whitespaces).lowercased()
            if equation.isEmpty { equation = "x" }

            // Same validity rules as the desktop loader: reserved names and
            // blanks are not valid assignment targets; a-z and underscore only.
            var assignment: String?
            let candidate = (field(fields, "Assign To") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if !candidate.isEmpty,
               !["x", "e", "hp", "tq"].contains(candidate),
               candidate.allSatisfy({ $0 == "_" || ($0 >= "a" && $0 <= "z") }) {
                assignment = candidate
            }

            let enabled = (field(fields, "Enabled") ?? "TRUE").trimmingCharacters(in: .whitespaces).uppercased() != "FALSE"

            result.append(HslPid(index: result.count,
                                 name: name,
                                 unit: (field(fields, "Unit") ?? "").trimmingCharacters(in: .whitespaces),
                                 equation: equation,
                                 address: address,
                                 length: length,
                                 signed: signed,
                                 min: progMin,
                                 max: progMax,
                                 assignment: assignment,
                                 enabled: enabled))
        }

        guard !result.isEmpty else {
            throw HslParameterFileError.noUsableParameters(file.displayName)
        }
        return result
    }

    /// Address column is a "0x..." hex string in the real files; tolerate bare hex/decimal too.
    private static func parseAddress(_ raw: String) -> UInt32 {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x") { s = String(s.dropFirst(2)) }
        if let hex = UInt32(s, radix: 16) { return hex }
        return UInt32(s) ?? 0
    }

    /// Minimal RFC4180-style line parser (quoted fields may contain commas) -
    /// same approach as the desktop loader.
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
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
