# GET Mobile v43 — square home tiles, section branding, HSL stability

- Home screen main actions are now square 2-column tiles.
- Added the GET logo banner to the top of the major app sections and connection screens.
- HSL raw samples remain available for CSV export, but the SwiftUI chart now receives a throttled snapshot instead of forcing a full chart rebuild at every 10–20 Hz sample.
- Added an ISO-TP response-length guard so malformed first-frame lengths cannot drive an unbounded receive loop.
- Existing HSL transport/ECU protocol behavior was otherwise left intact; this build is intended to isolate UI/runtime instability without changing the established HSL wire sequence.
