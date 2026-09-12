# GET Mobile v26 - Windows Simos18 HSL reference fix

This version uses the uploaded working Windows Simos18 logger (`SimosHslLogger.cs`) as the protocol reference.

## HSL setup
The mobile logger now mirrors the Windows implementation:

- Build the complete physical PID list in catalog order.
- Each entry is encoded as ASCII `0` + ASCII decimal length digit + 32-bit address.
- Append `00` list terminator.
- Send one logical UDS request:
  `3E 02 B0 01 E7 00 <length:u16> <parameter-list>`
- Let the ISO-TP transport segment the request.
- Accept any positive response beginning with `7E` (the Windows implementation does this rather than requiring a chunk-length acknowledgement).

## HSL polling
The mobile logger now mirrors `PollOnceHsl()` in the Windows source:

`3E 04 B0 01 E7 00 FF FF`

The response is expected to begin with `7E`; bytes after that leading byte are the packed HSL data and are decoded in PID order.

## Important correction from v25
v25 incorrectly changed the setup protocol to a `3E 32` chunked scheme and required `7E 00 <chunk length>` acknowledgements. The uploaded Windows logger demonstrates that the working Simos18 implementation actually uses the `3E02` list setup and `3E04` polling sequence. v26 reverts to that known-working behavior rather than guessing from a different HSL variant.
