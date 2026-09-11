# HSL Datalogger v19

## Fixes

- Prevented duplicate HSL startup transactions. SwiftUI/button taps can no longer start two overlapping ISO-TP HSL setup requests on the same GVRET connection.
- Added an HSL request-in-flight guard in `GvretWifiManager` so a second HSL transaction cannot interleave First/Consecutive Frames with an existing one.
- The gauge session now claims HSL ownership before cancelling Live polling and checks that ownership before every DID request, preventing an already-running gauge poll from competing with HSL during the handoff.
- HSL Start button is disabled while the HSL setup transaction is starting.
- The ECU response seen in the latest debug trace, `7E 00 31`, is treated as a valid HSL setup acknowledgement; the previous `7E` error was being made much more likely by overlapping ISO-TP transactions.
- Normal gauge Live remains explicitly off until the user starts it.

## Version

Marketing version: 1.0.6
Build: 7
