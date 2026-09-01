import Foundation

/// Ported from Simos18DiagnosticsControl.xaml.cs's FormatKnownValue +
/// ReadBigEndianSigned: big-endian bytes, sign-extended if the parameter
/// is signed, then run through the same equation grammar (EquationEvaluator),
/// rounded to 2 decimal places.
enum DidValueDecoder {
    static func decode(_ entry: CommonDidEntry, from data: Data) -> (text: String, numeric: Double) {
        let length = min(entry.length, data.count)
        let raw = readBigEndianSigned(data, length: length, signed: entry.signed)

        let value: Double
        if let evaluated = try? EquationEvaluator.evaluate(entry.equation, variables: ["x": Double(raw)]) {
            value = (evaluated * 100).rounded() / 100
        } else {
            value = Double(raw) // matches the C# app's bare-catch fallback
        }

        let unitSuffix = entry.unit.isEmpty ? "" : " \(entry.unit)"
        let text = "\(entry.name): \(formatNumber(value))\(unitSuffix)"
        return (text, value)
    }

    private static func readBigEndianSigned(_ data: Data, length: Int, signed: Bool) -> Int64 {
        var value: UInt64 = 0
        let bytes = [UInt8](data.prefix(length))
        for b in bytes { value = (value << 8) | UInt64(b) }

        guard signed, length < 8 else { return Int64(bitPattern: value) }

        let signBit: UInt64 = 1 << (length * 8 - 1)
        if value & signBit != 0 {
            value = value &- (1 << (length * 8))
        }
        return Int64(bitPattern: value)
    }

    private static func formatNumber(_ value: Double) -> String {
        // Matches C#'s double.ToString(InvariantCulture) closely enough for
        // display purposes: no trailing ".0" noise, but real decimals kept.
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }
}
