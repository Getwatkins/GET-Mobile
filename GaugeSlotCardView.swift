import SwiftUI

/// One gauge slot: the dial/digital readout plus its DID quick-pick,
/// mirroring one cell of the Windows app's 3-then-3 UniformGrid of DID slots.
struct GaugeSlotCardView: View {
    @ObservedObject var slot: GaugeSlot
    let isDigitalStyle: Bool

    var body: some View {
        VStack(spacing: 6) {
            GaugeView(
                value: slot.numericValue,
                minimum: slot.gaugeMin,
                maximum: slot.gaugeMax,
                label: slot.gaugeLabel.isEmpty ? "—" : slot.gaugeLabel,
                unit: slot.gaugeUnit,
                warnMin: nil,
                warnMax: nil,
                isDigitalStyle: isDigitalStyle
            )

            Picker("DID", selection: Binding(
                get: { slot.selectedEntry },
                set: { slot.selectedEntry = $0 }
            )) {
                Text("— none —").tag(CommonDidEntry?.none)
                ForEach(CommonDidCatalog.all) { entry in
                    Text(entry.displayText).tag(Optional(entry))
                }
            }
            .pickerStyle(.menu)
            .tint(GETTheme.gold)
            .font(.system(size: 12))
        }
        .padding(8)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(6)
    }
}
