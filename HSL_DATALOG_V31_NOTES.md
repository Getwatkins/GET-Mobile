# GET Mobile v31 — try an extended diagnostic session before HSL setup

## Recap: v29 ruled out burst size
v29 trimmed the setup list to the selected channels only (7 Consecutive
Frames instead of 72). Same result as the full catalog: perfectly correct
ISO-TP framing (verified byte-for-byte - correct First Frame, correct count
field, correct per-entry encoding), a clean Flow Control grant (`30 00 02`),
every frame transmitted with no error - then total silence for the entire
15s window either way. That ruled out burst size as the cause.

The user then confirmed something decisive: **the Windows/J2534 logger,
tested today, completes HSL logging fine on this exact car.** So this is
provably a client-side difference, not a vehicle/ECU/tune/firmware problem.

## Recap: v30 ruled out frame pacing/timing
The Windows logger hands the whole request to a J2534 hardware dongle,
which paces Consecutive Frames internally in hardware/firmware, typically
accurate to ~1ms. This app instead paces frames itself in Swift, with a
full network round trip to the A0/GVRET board per frame. v30 added a 20ms
floor beneath whatever STmin the ECU requests (2ms, consistently), on the
theory that this WiFi round trip might not reliably sustain the ECU's
requested rate.

The next trace confirmed the floor is working - the 7 frames now visibly
spread across close to a full second of wall clock, instead of landing in
the same one-second log bucket. Result: identical total silence for the
full 15s. That rules out frame pacing too.

## Where this leaves things
Three separate traces (72-frame/2ms, 7-frame/2ms, 7-frame/20ms-floor) all
show the same shape: the request assembles and transmits with zero framing
errors, the ECU's transport layer accepts it cleanly with a single Flow
Control, and then nothing - no data, no NRC, nothing - for the entire
timeout window.

That specific combination - transport layer says "got it, here's your Flow
Control," application layer says nothing back, ever - is the textbook
signature of a request that reached a service handler gated behind a
precondition this app isn't satisfying, most commonly session state. A UDS
server's transport layer generally acks incoming ISO-TP traffic regardless
of what service it turns out to contain; it's only once the message is
fully assembled and handed to the actual service dispatcher that a
session/security gate would apply, and a manufacturer-specific service the
ECU only honors outside the default session could easily just drop the
request there rather than build a proper NRC.

## Fix (experiment): request extended diagnostic session first
`configureHsl()` now sends a best-effort `10 03` (DiagnosticSessionControl,
extended session) via `UdsClient.changeSession()` - already a proven code
path, since flashing uses this exact call today - immediately before
building and sending the `3E02` HSL setup request.

The reference Windows logger's `SimosHslLogger.cs` explicitly never does
this, matching VW_Flash's Python. But that class is only the logging piece
of a larger Windows application, and there's no visibility into whether
something *else* in that app - run once at startup, or when the ECU family
is selected, outside this one file - already leaves the ECU in an extended
session by the time its HSL logger runs. Given byte content, burst size,
and frame pacing have all now been directly tested and ruled out, and
session gating is the standard explanation for "clean protocol handshake,
silent app-layer drop," this is the best-supported remaining experiment.

This is deliberately non-fatal (`try?`) - a rejection here doesn't block
the HSL attempt that follows, and either way it shows up in the GVRET debug
log as a normal UDS request/response, so the trace will say plainly whether
the ECU accepted, rejected, or ignored it.

## Still to verify
If HSL still times out identically even with the session request sent
first, that rules out plain session-gating too, and the next step really
needs a side-by-side wire capture of a successful Windows-tool run (SavvyCAN,
a bus analyzer, or the Windows app's own trace output if it has one) rather
than another guess from this side alone.
