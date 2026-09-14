# GET Mobile v32 — security access before HSL setup

## Fix: SA2 seed/key unlock, scoped to just the handshake
`configureHsl()` now follows the extended-session request (v31) with a
security access (seed/key) exchange, using `UdsClient.unlockSecurityAccess()`
- the same call this app's flash path (`UnlockSequence.swift`) already uses
and depends on - with the Simos 18.1-18.6 SA2 script (`Simos18ModuleInfo.sa2Script`),
confirmed as the right ECU family.

This deliberately does NOT do the rest of what `UnlockSequence.swift` does
for flashing: no switch to programming session, no workshop-log write
(`0xF15A`). Just the seed/key handshake, staying in extended session
throughout. Both this and the session request are wrapped in `try?` -
non-fatal, and `unlockSecurityAccess` already no-ops safely if the ECU
reports it's already unlocked (all-zero seed), so this is safe to run on
every HSL start.

Reasoning: v31 proved the ECU, transport, and session handling are all
healthy (`10 03` got a clean positive response, `50 03 00 32 01 F4`), and
HSL still got total silence right after. That specific pattern - clean
session change, then a manufacturer service still silently ignored - is
what you'd expect if `0x3E` requires the same security unlock this app's
own flashing code already depends on, since HSL is a `0x3E` service
installed by the same community patch as the flash-side `0x3E` services.

## Catalog cross-check against the user's actual working parameter file
Cross-referenced `HslPidCatalog.swift` against `parameters_3e_S50.csv` (the
exact list the user's Windows logger uses). All 8 default/selected channels
(Coolant Temp, Engine Speed, IAT, Lambda, MAP, Pedal Pos, PUT, Torque) -
the ones actually being tested in every trace so far - already matched
exactly, address and length. So the current run of failures was never an
address bug in the parameters being tested.

Did find one real, previously-unnoticed bug while cross-checking, unrelated
to the current failure but worth fixing anyway: Knock Cyl 1-4 were at
`0xD0019888`-`0xD001988B` in the catalog; the working CSV has them at
`0xD0019884`-`0xD0019887`. Fixed to match. These aren't in the default
selection, so this wouldn't have affected any trace so far, but would have
sent wrong data if someone selected those channels.

One other real difference, left alone for now since it's unrelated to
today's bug and not obviously wrong either way: the CSV has a single
"Misfires" counter at `0xD0014504`; this catalog instead has four
per-cylinder `Misfire Cyl 1-4` entries plus a `Misfire Sum`, at different
addresses (`0xD00144C6`-`0xD00144CA`, `0xD0014508`). Different breakdown of
the same underlying data, not a typo - not touching this without more
certainty about which is right, since it doesn't matter for the bug at
hand.

## Still to verify
If HSL starts now, that confirms security access was the actual gate all
along. If it's still totally silent even with both extended session and a
successful (or already-unlocked) security access, that's a very strong
signal this needs a real wire-level comparison against a successful
Windows-tool run rather than another guess from this side.
