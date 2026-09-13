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

## Update: user-supplied debug log analyzed

Got a real trace of a failed start. It shows, in order:
1. `3E02` setup request built from the full 100-parameter physical catalog
   (500 bytes of parameter list + terminator -> 509-byte request -> 72
   Consecutive Frames after the First Frame).
2. The ECU's Flow Control comes back immediately and cleanly: `30 00 02`,
   i.e. status=continue-to-send, **BlockSize=0x00 (send the whole thing, no
   further FC needed)**, STmin=0x02 (2ms). Not BS=2 as the v16 notes
   guessed - BS is the byte *after* the status byte, so `30 00 02` is BS=00 /
   STmin=02. So the "stream every CF after the first FC" behavior added in
   v16/v27 is correct for this FC and is NOT the bug - it's honoring exactly
   what the ECU asked for.
3. All 72 Consecutive Frames go out cleanly with the requested 2ms spacing,
   no Flow Control Overflow, no NRC.
4. Then: silence. The only traffic on the bus for the next 6 seconds is an
   unrelated ~1Hz broadcast frame (a different, constant ID/payload each
   time - background bus traffic, correctly ignored). Nothing at all arrives
   on 0x7E8, and the transaction times out completely with zero bytes
   received - not a malformed response, not an NRC, just nothing.

That "clean transmit, then total silence for the entire window" pattern -
combined with the setup list being 100 parameters, noticeably larger than a
single poll - points at the timeout being too short for this specific
transaction, not a framing/protocol bug. The v27 "6 second" timeout (which,
per the bug above, wasn't even really 6s - see the fix above) was being
spent entirely on a request that may just need more than that to get
processed on the ECU side once received in full.

## Fix 2: separate, longer timeout for the one-time setup transaction
- `configureHsl()`'s `3E02` request now gets its own `hslSetupTimeoutSeconds
  = 15.0`, instead of sharing the same timeout as every `3E04` poll.
- Each `3E04` poll keeps a short `hslPollTimeoutSeconds = 4.0`, since polls
  are much smaller (only the selected channels' worth of return data) and a
  single dropped poll should be skipped quickly, not stall the whole
  30fps-ish logging loop for 15 seconds.

## Still to verify
If setup still times out even at 15s with total silence (not just "close"),
that would point away from "just needs more time" and toward the ECU
actually dropping/rejecting the full 100-parameter list outright once fully
received - at which point the next thing to try is cutting the setup list
down to only the channels actually selected in the PID picker (v14/v19 tried
this before switching back to the full catalog for other reasons - worth
re-testing specifically against this failure mode with a fresh trace, not
assumed from an older one).
