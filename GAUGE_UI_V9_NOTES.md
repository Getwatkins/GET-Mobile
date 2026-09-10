# Gauge UI v9

- Gauge grid changed from 3 columns to 2 columns so each gauge is substantially larger on iPhone.
- The entire gauge card is now a SwiftUI `Menu` label. Tap anywhere on a gauge to open the full CommonDidCatalog.
- The previous small Picker under each gauge was removed.
- The currently selected DID is shown with a checkmark.
- Selecting a different DID immediately clears the old value so the previous variable is not displayed while the new DID is being read.
- Empty slots show "Tap to select" and open the same full variable menu.
- Added a small "Tap to change" hint beneath each gauge.
- Accessibility label/hint added for the tap-to-change behavior.
