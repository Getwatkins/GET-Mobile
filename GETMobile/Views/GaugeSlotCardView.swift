import SwiftUI

/// One gauge slot. The entire gauge card is tappable: tapping it opens the
/// complete DID menu, so the user can change the displayed variable without
/// hunting for a small picker underneath the gauge.
struct GaugeSlotCardView: View {
    @ObservedObject var slot: GaugeSlot
    let isDigitalStyle: Bool

    var body: some View {
        Menu {
            Button {
                slot.selectedEntry = nil
            } label: {
                Label("— none —", systemImage: slot.selectedEntry == nil ? "checkmark" : "")
            }

            Divider()

            ForEach(CommonDidCatalog.all) { entry in
                Button {
                    slot.selectedEntry = entry
                    // Clear the old value immediately so the new gauge does not
                    // briefly display the previous DID's value while waiting
                    // for its first ECU response.
                    slot.displayText = "--"
                    slot.numericValue = .nan
                } label: {
                    if slot.selectedEntry?.did == entry.did {
                        Label(entry.displayText, systemImage: "checkmark")
                    } else {
                        Text(entry.displayText)
                    }
                }
            }
        } label: {
            gaugeContent
        }
        .menuStyle(.automatic)
        .tint(GETTheme.gold)
        .accessibilityLabel(slot.gaugeLabel.isEmpty ? "Choose gauge variable" : "Choose gauge variable, currently \(slot.gaugeLabel)")
        .accessibilityHint("Tap to choose a different ECU variable")
    }

    private var gaugeContent: some View {
        VStack(spacing: 4) {
            GaugeView(
                value: slot.numericValue,
                minimum: slot.gaugeMin,
                maximum: slot.gaugeMax,
                label: slot.gaugeLabel.isEmpty ? "Tap to select" : slot.gaugeLabel,
                unit: slot.gaugeUnit,
                warnMin: nil,
                warnMax: nil,
                isDigitalStyle: isDigitalStyle
            )

            HStack(spacing: 5) {
                Image(systemName: "hand.tap")
                Text(slot.selectedEntry == nil ? "Tap to choose variable" : "Tap to change")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(GETTheme.amber.opacity(0.9))
            .frame(maxWidth: .infinity)
        }
        .padding(6)
        .background(GETTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GETTheme.border, lineWidth: 1))
        .cornerRadius(8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
