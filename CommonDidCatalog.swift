import Foundation

/// One quick-pick catalog entry - a named, readable Simos18 DID with its
/// scaling equation, unit, and a sane gauge range. Ported directly from
/// Communication/Simos18/CommonDidCatalog.cs + parameters_22.csv so the
/// iOS app's picker list matches the Windows app's exactly.
struct CommonDidEntry: Identifiable, Hashable {
    let name: String
    let unit: String
    let equation: String
    let did: UInt16
    let length: Int
    let signed: Bool
    let progMin: Double
    let progMax: Double

    var id: UInt16 { did }

    /// "PUT - 0x202a (kpa)", matching CommonDidEntry.DisplayText in the C# app.
    var displayText: String {
        let hex = String(format: "%04x", did)
        return unit.isEmpty ? "\(name) - 0x\(hex)" : "\(name) - 0x\(hex) (\(unit))"
    }
}

enum CommonDidCatalog {
    /// Every named, non-virtual (real 2-byte DID) row from parameters_22.csv,
    /// plus the AFR/Boost-Vacuum entries derived from Lambda/MAP - identical
    /// set to what the Windows app's CommonDidCatalog.All builds, sorted by name.
    static let all: [CommonDidEntry] = {
        (csvEntries + derivedEntries).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func findByDid(_ did: UInt16) -> CommonDidEntry? {
        all.first { $0.did == did }
    }

    // MARK: parameters_22.csv, transcribed row-for-row (virtual/0xffff rows -
    // Airmass, Boost, Calc HP, Calc TQ, Fuel Trim - excluded, same as the
    // Windows app's `.Where(p => !p.Virtual)`, since those depend on other
    // live parameters rather than a single ad-hoc DID read).
    private static let csvEntries: [CommonDidEntry] = [
        CommonDidEntry(name: "Airflow",         unit: "kg/hr",  equation: "x",              did: 0x2032, length: 2, signed: false, progMin: 0,     progMax: 2000),
        CommonDidEntry(name: "Ambient Press",   unit: "kpa",    equation: "x / 120.60176665439", did: 0x13ca, length: 2, signed: false, progMin: 50, progMax: 120),
        CommonDidEntry(name: "Ambient Temp",    unit: "°C",     equation: "x / 128",        did: 0x1004, length: 1, signed: true,  progMin: -40,   progMax: 50),
        CommonDidEntry(name: "Battery Voltage", unit: "V",      equation: "x * 0.1015625",  did: 0x14a6, length: 1, signed: false, progMin: 0,     progMax: 2),
        CommonDidEntry(name: "Cooling Fan",     unit: "%",      equation: "x * 0.390625",   did: 0x101e, length: 1, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Coolant Temp",    unit: "°C",     equation: "x - 40",         did: 0x11cd, length: 1, signed: false, progMin: -50,   progMax: 120),
        CommonDidEntry(name: "CPU Load",        unit: "%",      equation: "x * 0.09765625", did: 0x14ec, length: 2, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Cruise",          unit: "",       equation: "x",              did: 0x203c, length: 2, signed: false, progMin: 0,     progMax: 1),
        CommonDidEntry(name: "Engine Speed",    unit: "rpm",    equation: "x / 4",          did: 0xf40c, length: 2, signed: false, progMin: 0,     progMax: 7000),
        CommonDidEntry(name: "Eth Content",     unit: "%",      equation: "x / 2.55",       did: 0xf452, length: 1, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Exhaust Cam Pos", unit: "°",      equation: "(x / 10) - 24",  did: 0x201a, length: 2, signed: true,  progMin: -10,   progMax: 10),
        CommonDidEntry(name: "FP DI",           unit: "bar",    equation: "x / 10",         did: 0x2027, length: 2, signed: false, progMin: 0,     progMax: 250),
        CommonDidEntry(name: "FP DI SP",        unit: "bar",    equation: "x / 10",         did: 0x293b, length: 2, signed: false, progMin: 0,     progMax: 250),
        CommonDidEntry(name: "FP MPI",          unit: "bar",    equation: "x / 1000",       did: 0x2025, length: 2, signed: false, progMin: 0,     progMax: 15),
        CommonDidEntry(name: "FP MPI SP",       unit: "bar",    equation: "x / 1000",       did: 0x2932, length: 2, signed: false, progMin: 0,     progMax: 15),
        CommonDidEntry(name: "HPFP Eff Vol",    unit: "%",      equation: "x / 100",        did: 0x209a, length: 2, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Gear",            unit: "",       equation: "x",              did: 0x210f, length: 2, signed: false, progMin: 0,     progMax: 6),
        CommonDidEntry(name: "IAT",             unit: "°C",     equation: "x * 0.75 - 48",  did: 0x1001, length: 1, signed: false, progMin: -40,   progMax: 55),
        CommonDidEntry(name: "Ign Avg",         unit: "°",      equation: "x / 100",        did: 0x2004, length: 2, signed: true,  progMin: -10,   progMax: 10),
        CommonDidEntry(name: "Inj PW DI",       unit: "ms",     equation: "x / 250",        did: 0x13a0, length: 2, signed: false, progMin: 0,     progMax: 190000),
        CommonDidEntry(name: "Inj PW MPI",      unit: "ms",     equation: "x / 250",        did: 0x13ac, length: 2, signed: false, progMin: 0,     progMax: 190000),
        CommonDidEntry(name: "Int Cam Pos",     unit: "°",      equation: "30 - (x / 10)",  did: 0x201e, length: 2, signed: true,  progMin: -10,   progMax: 10),
        CommonDidEntry(name: "Knock Cyl 1",     unit: "°",      equation: "x / 100",        did: 0x200a, length: 2, signed: true,  progMin: 0,     progMax: -5),
        CommonDidEntry(name: "Knock Cyl 2",     unit: "°",      equation: "x / 100",        did: 0x200b, length: 2, signed: true,  progMin: 0,     progMax: -5),
        CommonDidEntry(name: "Knock Cyl 3",     unit: "°",      equation: "x / 100",        did: 0x200c, length: 2, signed: true,  progMin: 0,     progMax: -5),
        CommonDidEntry(name: "Knock Cyl 4",     unit: "°",      equation: "x / 100",        did: 0x200d, length: 2, signed: true,  progMin: 0,     progMax: -5),
        CommonDidEntry(name: "Lambda",          unit: "l",      equation: "x / 1024",       did: 0x10c0, length: 2, signed: false, progMin: 0,     progMax: 2),
        CommonDidEntry(name: "Lambda SP",       unit: "l",      equation: "x / 32768",      did: 0xf444, length: 2, signed: false, progMin: 0,     progMax: 2),
        CommonDidEntry(name: "LPFP Duty",       unit: "%",      equation: "x / 100",        did: 0x2028, length: 2, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "LTFT",            unit: "%",      equation: "x / 1.28 - 100", did: 0xf407, length: 1, signed: false, progMin: -25,   progMax: 25),
        CommonDidEntry(name: "MAP",             unit: "kpa",    equation: "x / 10",         did: 0x39c0, length: 2, signed: false, progMin: 0,     progMax: 300),
        CommonDidEntry(name: "MAP SP",          unit: "kpa",    equation: "x / 10",         did: 0x39c1, length: 2, signed: false, progMin: 0,     progMax: 300),
        CommonDidEntry(name: "Misfires",        unit: "",       equation: "x",              did: 0x2904, length: 2, signed: false, progMin: 0,     progMax: 20),
        CommonDidEntry(name: "Oil Temp",        unit: "°C",     equation: "(x - 2731.4) / 10", did: 0x202f, length: 2, signed: false, progMin: -50, progMax: 130),
        CommonDidEntry(name: "Pedal Pos",       unit: "%",      equation: "x / 10.24",      did: 0x1070, length: 2, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Port Flap Pos",   unit: "",       equation: "x",              did: 0x295c, length: 1, signed: false, progMin: 0,     progMax: 1),
        CommonDidEntry(name: "PUT",             unit: "kpa",    equation: "x / 10",         did: 0x202a, length: 2, signed: false, progMin: 0,     progMax: 300),
        CommonDidEntry(name: "PUT SP",          unit: "kpa",    equation: "x / 10",         did: 0x2029, length: 2, signed: false, progMin: 0,     progMax: 300),
        CommonDidEntry(name: "STFT",            unit: "%",      equation: "x / 1.28 - 100", did: 0xf406, length: 1, signed: false, progMin: -25,   progMax: 25),
        CommonDidEntry(name: "Torque",          unit: "Nm",     equation: "x / 10",         did: 0x437c, length: 2, signed: true,  progMin: -50,   progMax: 450),
        CommonDidEntry(name: "Torque Req",      unit: "Nm",     equation: "x / 10",         did: 0x4380, length: 2, signed: true,  progMin: 0,     progMax: 500),
        CommonDidEntry(name: "TPS",             unit: "%",      equation: "x / 10",         did: 0x20ba, length: 2, signed: true,  progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Turbo Speed",     unit: "rpm",    equation: "x / 163.84",     did: 0x1040, length: 2, signed: false, progMin: 0,     progMax: 190),
        CommonDidEntry(name: "Turbo Air Temp",  unit: "°C",     equation: "x * 0.005859375 + 144", did: 0x1041, length: 2, signed: true, progMin: -40, progMax: 55),
        CommonDidEntry(name: "Valve Lift Pos",  unit: "",       equation: "x",              did: 0x167c, length: 1, signed: false, progMin: 0,     progMax: 1),
        CommonDidEntry(name: "Vehicle Speed",   unit: "km/hr",  equation: "x / 100",        did: 0x2033, length: 2, signed: false, progMin: 0,     progMax: 220),
        CommonDidEntry(name: "Wastegate",       unit: "%",      equation: "100 - x / 100",  did: 0x39a2, length: 2, signed: false, progMin: 0,     progMax: 100),
        CommonDidEntry(name: "Wastegate SP",    unit: "%",      equation: "100 - x / 100",  did: 0x39a3, length: 2, signed: false, progMin: 0,     progMax: 100),
    ]

    // MARK: Derived entries (not real ECU registers - math on top of
    // Lambda/MAP), identical to CommonDidCatalog.cs's BuildDerivedEntries().
    private static let derivedEntries: [CommonDidEntry] = [
        CommonDidEntry(name: "AFR", unit: ":1", equation: "(x / 1024) * 14.7",
                        did: 0x10c0, length: 2, signed: false, progMin: 0, progMax: 29.4),
        CommonDidEntry(name: "Boost/Vacuum", unit: "psi", equation: "((x / 10) * 0.1450777202) - 14",
                        did: 0x39c0, length: 2, signed: false, progMin: -14, progMax: 30),
    ]
}
