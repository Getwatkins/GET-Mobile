import SwiftUI

/// GET Mobile's color palette. Pulled directly from the Windows app's
/// App.xaml resource dictionary so the two apps look like the same product:
///   ForegroundColor  #FFFFE000  (gold/yellow)
///   BackgroundColor  #FF000000  (black)
///   BorderColor      Black
///   HighlightColor   #FFCC8700  (amber)
///   Warning (red)    #FFFF4040  (from GaugeControl.xaml.cs's inWarnZone color)
enum GETTheme {
    static let background = Color.black
    static let panelBackground = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)
    static let border = Color(white: 0.16)
    static let gold = Color(red: 0xFF / 255, green: 0xE0 / 255, blue: 0x00 / 255)
    static let amber = Color(red: 0xCC / 255, green: 0x87 / 255, blue: 0x00 / 255)
    static let warningRed = Color(red: 1.0, green: 0x40 / 255, blue: 0x40 / 255)
    static let valueWhite = Color.white

    /// Monospaced digit font for gauge/DID numeric readouts, mirroring the
    /// WPF app's use of Consolas throughout GaugeControl/Simos18DiagnosticsControl.
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
