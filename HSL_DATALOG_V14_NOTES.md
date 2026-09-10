# GET Mobile v14 - HSL logger isolation/fix

## Fixes
- HSL logger no longer auto-starts when the Datalog screen opens. The gauge poller is stopped and the user explicitly starts HSL logging.
- HSL logger does not automatically fall back to the gauge polling loop when HSL startup/polling fails; the error remains visible on the Datalog screen.
- HSL setup now configures only the channels selected in the PID picker. This avoids sending the full 100-PID S50 physical list (~600-byte setup list) when only a handful of channels are requested.
- HSL polling retains the SimosTools proprietary response convention: response starts with `0x7E`, followed directly by the HSL payload. It does not require a `0x04` subfunction echo.
- Selecting/clearing channels is safe; the logger refuses to start with zero channels.
- Existing gauge and flashing behavior is preserved.

## Test
Open HSL Datalogger, verify the gauge feed is stopped, select a small set of channels (the default 8 is recommended), then press Start Logging. If setup or polling fails, the Datalog screen remains open and shows the exact error instead of returning to the gauge view.
