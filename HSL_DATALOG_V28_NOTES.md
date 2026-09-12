# GET Mobile v28 — HSL timeout actually wired up

## Root cause
The v27 notes say the HSL transaction timeout was raised to 6 seconds, and
`GvretWifiManager.sendHslRequest(...)`'s default parameter was in fact changed
to `6.0`. But that default was never reachable: `HslLoggerSession.sendHsl(...)`
is the only caller, and it explicitly passed `timeoutSeconds: 4.0` on every
call (both the one-time `3E02` setup request and every `3E04` poll). So every
real HSL transaction was still being cut off at 4 seconds, silently undoing
the v27 fix. This matches "waits, then fails to fully start" exactly: if the
ECU's patched HSL backend needs close to (or slightly more than) 4 seconds to
finish acking the setup list, it was being timed out right before it
answered.

## Fix
- `HslLoggerSession` now has a single `hslTimeoutSeconds` constant (6.0) used
  for both the `3E02` setup call and every `3E04` poll call, instead of a
  hardcoded `4.0` that shadowed `GvretWifiManager`'s default.
- Added a "Copy Log" button and made the log text selectable in the GVRET
  Diagnostic Log screen (reachable from the Gauges screen), so a failed HSL
  attempt's trace can be copied off the phone without retyping it by hand.
  The log persists after leaving the Datalog screen, so: try Start Logging,
  let it fail, tap Done, open the diagnostic log, and copy it.

## Still to verify
If it still fails after this, the log will show exactly which phase it dies
in - one of:
- `HSL ISO-TP: transmitting request and waiting for ECU Flow Control...` with
  no further HSL line after it -> timing out waiting for the ECU's Flow
  Control response to the `3E02`/`3E04` First Frame.
- `HSL ISO-TP: request transmission complete; waiting for ECU response...`
  with no further HSL line after it -> the full request went out fine, but
  the ECU never answered (or answered with something that didn't parse).
- An `HSL normalized ISO-TP...` / `unexpectedAck` line -> the ECU answered,
  but not with a leading `0x7E`.

That distinction determines the next fix (e.g. whether the multi-frame
consecutive-frame send needs to honor the ECU's announced block size after
all, rather than streaming every consecutive frame after the first Flow
Control) and shouldn't be guessed at again without the trace, given how many
prior versions (v16/v19/v27) already flip-flopped on that exact question
based on a single observed trace.
