# GET Mobile v30 — pace outgoing Consecutive Frames beyond the ECU's STmin

## Where this leaves off
v29's experiment (setup list trimmed to selected channels only) came back
with the *same* result as the 72-frame full-catalog request: perfectly
correct ISO-TP framing (verified byte-for-byte again - correct First Frame,
correct count field, correct per-entry encoding), a clean Flow Control grant
(`30 00 02`), all frames transmitted with no error - then total silence for
the entire 15s window either way. That conclusively rules out burst size.

The user then confirmed something decisive: **the Windows/J2534 logger,
tested today, completes HSL logging fine on this exact car.** So this is
provably a client-side difference, not a vehicle/ECU/tune problem, and not
a framing bug (every byte we send is correct in both the 7-frame and
72-frame case).

## What's actually different from the working reference
The Windows logger hands the whole request to a J2534 hardware dongle's
`SpecificSend`, which owns ISO-TP framing and Consecutive-Frame pacing
internally in the dongle's own firmware/hardware - normally accurate to
1ms or better, with each frame queued and transmitted with no round trip
back to the host in between.

This app instead does that pacing itself in Swift: for each Consecutive
Frame, `Task.sleep(STmin)` then a full `NWConnection.send` over TCP to the
A0/GVRET board, which then has to parse that BUILD_CAN_FRAME command and
queue it for the physical bus before the next one arrives. The ECU's
requested STmin here has consistently been 2ms. A hardware dongle can
honor 2ms exactly; whether this phone -> WiFi -> A0 board round trip
reliably can, every 2ms, without the board dropping or corrupting a frame
it hasn't finished processing yet, is a different question - and unlike
burst size, a too-fast send rate would explain identical total failure at
both 7 frames and 72 frames, since the problem would be the *gap*, not the
*count*.

## Fix (experiment): enforce a pacing floor independent of STmin
Added `IsoTp.minimumSendIntervalSeconds = 0.02` (20ms) and applied it as a
floor - `max(ecuRequestedSTmin, 20ms)` - everywhere a Consecutive Frame is
paced:
- `IsoTpSession.sendHsl()` (HSL setup and poll transactions)
- `IsoTpSession.send()` (normal UDS multi-frame sends - including flash
  block transfers, which take the same code path and could in principle
  have the same problem, so this is a blanket safety margin there too, not
  just an HSL-specific hack)

Sending slower than the ECU's requested STmin is always spec-compliant
(ISO 15765-2 defines STmin as a *minimum*, not a fixed rate) - this only
ever adds latency, never violates the protocol. Worst case for the full
72-frame HSL setup list: about 1.4s of extra time, against a 15s timeout -
negligible.

## Still to verify
If HSL still gets total silence even at 20ms spacing, that's a real, useful
data point too - it would mean the bottleneck (if this is the bottleneck at
all) needs more than 20ms, which is worth knowing before trying something
larger, rather than guessing again. If it *does* start, the app v30 build
also confirms multi-frame TX pacing was the actual root cause across the
board, and the delay could potentially be tuned back down later once this
is on firmer ground.

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

## Update 2: 15s still times out with total silence - this is not a timeout problem

Got a second trace, now at the corrected 15s setup timeout. Every byte on the
wire checks out:
- The 509-byte `3E02` request was assembled with the exact right count field
  (`01 F5` = 501) and the exact right per-entry encoding (verified several
  entries against the catalog, e.g. `01 D0 00 EE 2A` = length 1, address
  `0xD000EE2A` = Accel Lat, in catalog order).
- The First Frame PCI is correct for a 509-byte payload (`11 FD`).
- The ECU's Flow Control comes back immediately: `30 00 02` = BS=0x00 (send
  everything), STmin=0x02 (2ms) - confirmed on this second trace too, so
  that reading holds.
- All 72 Consecutive Frames go out with correct sequence numbers and the
  documented padding, finishing cleanly (`HSL ISO-TP: request transmission
  complete`).
- Then nothing. Not a slow answer, not an NRC: 15 full seconds of silence on
  0x7E8 (only the unrelated ~1Hz background frame), then a clean timeout.

Waiting longer doesn't fix "the ECU never says anything at all." This rules
out "just needs more time" and points at the message not correctly/fully
arriving as a complete, valid transfer as far as the ECU's ISO-TP receiver
is concerned - most likely something about reliably delivering ~72
back-to-back Consecutive Frames through WiFi -> A0 -> CAN bus (and probably
a gateway module, on a VW/Audi platform) rather than a protocol mistake in
this app, since every byte we can see checks out.

## Fix 3 (experiment): setup list is now selected-channels-only again

`configureHsl()` now builds its parameter list from `selectedPids` (the
channels checked in the PID picker - 8 by default) instead of the complete
100-entry catalog. That cuts the setup request from 509 bytes/72 Consecutive
Frames down to roughly 49 bytes/7 frames.

This directly tests the "large burst doesn't survive the trip" theory. A
previous session's comment claimed a selected-only list "would not reliably
complete the list/read cycle" - but that's a different symptom (intermittent)
than what this trace shows (deterministic, total silence), and it predates
the timeout fix above, so it's worth re-testing clean rather than trusting
that old note. If a 7-frame request completes where a 72-frame one didn't,
that confirms the burst-size theory and the fix going forward is to keep the
setup list scoped to selected channels (or otherwise pace/chunk a larger
one) rather than always sending the full catalog. If it *still* times out
with total silence even at 7 frames, that rules burst size out entirely and
points at something else - most likely session state or security access -
which would need a fresh trace to chase down rather than another guess.
