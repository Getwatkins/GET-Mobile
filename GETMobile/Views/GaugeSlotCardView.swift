import SwiftUI

/// One gauge slot. Tapping the gauge opens a dedicated, scrollable variable
/// picker. The picker works while Live polling is running; polling is paused
/// while the picker is open so the UI remains responsive, then automatically
/// resumes when the picker closes.
struct GaugeSlotCardView: View {
    @ObservedObject var slot: GaugeSlot
    @ObservedObject var session: GaugeSessionViewModel
    let isDigitalStyle: Bool

    @State private var showVariablePicker = false

    var body: some View {
        Button {
            session.beginGaugeSelection()
            showVariablePicker = true
        } label: {
            gaugeContent
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showVariablePicker, onDismiss: {
            session.endGaugeSelection()
        }) {
            VariablePickerView(slot: slot) {
                showVariablePicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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

private struct VariablePickerView: View {
    @ObservedObject var slot: GaugeSlot
    let onSelection: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Gauge variable") {
                    Button {
                        slot.selectedEntry = nil
                        slot.displayText = "--"
                        slot.numericValue = .nan
                        onSelection()
                    } label: {
                        HStack {
                            Text("— none —")
                            Spacer()
                            if slot.selectedEntry == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(GETTheme.amber)
                            }
                        }
                    }

                    ForEach(CommonDidCatalog.all) { entry in
                        Button {
                            slot.selectedEntry = entry
                            slot.displayText = "--"
                            slot.numericValue = .nan
                            onSelection()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayText)
                                        .foregroundColor(.primary)
                                    if !entry.unit.isEmpty {
                                        Text(entry.unit)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if slot.selectedEntry?.did == entry.did {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(GETTheme.amber)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(GETTheme.amber)
                }
            }
        }
    }
}
