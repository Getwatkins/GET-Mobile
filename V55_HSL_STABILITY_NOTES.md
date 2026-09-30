# GET Mobile v55 — HSL Stability Fixes

This build is focused on HSL logging stability and does not change the HSL 0x3E request format.

## Changes
- GVRET byte-stream parsing now runs off the MainActor.
- Unrelated CAN frames are filtered before they reach the UI actor; only Simos18 response ID 0x7E8 is forwarded to ISO-TP handling.
- Removed per-frame/raw-packet RX debug logging during normal operation, eliminating a major SwiftUI update/string-allocation source.
- HSL latest-value UI updates are throttled to the existing sample publish interval instead of publishing every poll.
- HSL setup timeout increased from 15s to 20s.
- HSL startup gets one controlled retry after a failed setup transaction, after releasing any stale transport wait.
- Existing sample/chart bounds and CSV recording behavior are retained.
- Existing HSL ISO-TP framing and selected-channel request behavior are retained.

## Testing recommendation
1. Connect the A0/GVRET normally.
2. Start HSL logging while the engine is idling.
3. Let it log for 30–60 seconds.
4. Rev the engine several times while logging.
5. Repeat with the normal vehicle CAN traffic/load.
6. If HSL still times out at startup, export the debug log immediately after the failed attempt; the new transport path should produce a much cleaner trace.
