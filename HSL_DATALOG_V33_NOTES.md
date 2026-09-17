# GET Mobile v33 — revert session control and security access

## Why
The security-access attempt in v32 came back with a clean, specific
answer: `subFunctionNotSupported` for level 0x11 while in extended
session. Read plainly, that means this ECU only recognizes that security
level from *programming* session - the same session flashing uses.

The user has confirmed that's a hard no: switching to programming session
while the engine is running risks stalling it or bricking the ECU. That
closes this path entirely, regardless of whether it would have technically
resolved the NRC.

More importantly, it should never have been necessary in the first place:
`SimosHslLogger.cs`'s own comments are explicit that VW_Flash's Python
"never opens a UDS session or requests security access before logging."
The user has a currently-working Windows GET logger and SimosTools setup
on this exact car - proof that neither session control nor security access
is actually required for HSL to work here. v31/v32 chased a theory that
the proven-working reference directly contradicts.

## Revert
`configureHsl()` no longer sends `10 03` or attempts security access. Back
to exactly the reference sequence: build the `3E02` request, send it,
nothing else. Kept from earlier versions since they're independently
justified and don't touch session/security state at all:
- v28's timeout fix (the real 4.0-vs-6.0 mismatch)
- v29's setup list scoped to selected channels
- v30's 20ms minimum frame-pacing floor
- v32's Knock Cyl 1-4 address fix (from cross-checking the user's own
  working parameter CSV)

## Where this actually leaves the investigation
Every app-level protocol theory that's safe to test has now been tested
and ruled out: byte content (verified repeatedly, byte-for-byte), burst
size (72 frames vs 7 frames - identical result), frame pacing (2ms vs
20ms - identical result), and now session/security state (the one avenue
that produced a different result at all - a real NRC instead of silence -
turns out to require something explicitly unsafe to do, and unnecessary
per the reference).

The open question this raises: the Windows GET logger and SimosTools work
on this exact car, over some real interface, sending what should be an
equivalent request. This app talks to the ECU through a Macchina A0 board
over WiFi using the GVRET/SavvyCAN protocol. Every low-level check so far
says this app's own request is byte-correct and well-formed. What hasn't
been ruled out yet is the A0/GVRET bridge itself - whether it reliably
gets a multi-frame client-to-ECU burst onto the physical bus the same way
a dedicated interface does. Whether that's even a real candidate depends
entirely on whether the working Windows tools go through the same A0
hardware or a different interface entirely - that's the key thing to find
out before guessing at anything else.
