# GET Mobile v57 - HSL Crash Hardening

Built from the v56 HSL stability project.

## Changes
- Retains v56 GVRET/CAN receive-load reduction and ISO-TP Flow Control filtering.
- Hardens HSL numeric decoding in `HslLoggerSession.decode()`.
- Avoids trapping `Int64` conversions when signed HSL values have the high bit set; uses bit-pattern conversion for sign extension.
- Rejects non-finite 4-byte floating-point HSL values instead of allowing invalid values into the logger.
- Rejects non-finite equation results and only publishes finite derived values.
- Preserves the existing HSL request format and PID catalog.

## Test focus
1. Start HSL at idle.
2. Rev the engine repeatedly while logging.
3. Let it run for at least 60 seconds.
4. Stop/restart HSL several times.
5. If it fails, export the debug log and the new iOS analytics/crash report.
