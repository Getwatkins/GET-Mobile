# GET Mobile v38 — fix a real DID-catalog id collision; "capped at 10" still unreproduced

## Fixed
`CommonDidEntry.id` was `did` (the 2-byte identifier). Two pairs of catalog
entries deliberately share a `did` on purpose - AFR reads the same raw
value as Lambda (just displayed as a ratio instead of lambda), and
Boost/Vacuum reads the same raw value as MAP (just displayed relative to
atmospheric instead of absolute). SwiftUI's `ForEach`/`List` requires
unique ids, so these two pairs could render/behave oddly. Changed `id` to
use `name` instead (verified unique across all 50 entries) so every row is
distinct.

## Not found (yet)
Went looking for a hardcoded "10" channel-selection cap - in
`DidLoggerSession`, `DidLoggerView`/`DidChannelPicker`, `CommonDidCatalog`,
and the transport layers (`UdsClient`, `GvretWifiManager`,
`BridgeManager`) - and there isn't one. `selectedNames` is a plain
`Set<String>`, `selectedEntries` and the picker list have no `.prefix`/
truncation anywhere, and "Select All" just assigns
`Set(CommonDidCatalog.all.map(\.name))` directly. The id-collision fix
above is a real, separate bug, but only accounts for 2 entries, not a cap
at 10 out of 50.

Need to see the actual behavior to fix this correctly rather than guessing
blind a second time: does the "Selected channels (N)" count at the bottom
of the logger screen say something other than 50 after tapping "Select
All"? Does the picker itself show fewer than 50 checkmarks lit up? Or do
all 50 show selected/checked, but only ~10 of them ever get real values
once logging starts (which would point at unsupported DIDs timing out
during polling, not a selection bug at all)?
