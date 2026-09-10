# GET Mobile v16 — HSL raw-stream and gauge isolation fix

## Root cause
The SimosTools HSL backend is not a normal ISO-TP response. `sendRaw()` sends the 3E request and `wait_frame()` returns the ECU's raw `0x7E` acknowledgement; the HSL sample bytes are then handled by the backend as raw data. GET Mobile was routing the exchange through the normal ISO-TP receiver, so it accepted only the `0x7E` acknowledgement and immediately reported `7E` as the HSL result.

## Fixes
- Added `HslRawTransport`.
- GVRET now has a dedicated HSL path: send the 3E request normally, consume the `0x7E` acknowledgement, then collect raw 0x7E8 CAN frames until the selected PID byte count is satisfied.
- Added per-frame HSL diagnostics to the GVRET log.
- Added a hard `isHslActive` ownership lock to `GaugeSessionViewModel`; normal gauge polling cannot restart while HSL owns the connection.
- Datalog view only resumes gauges when the user explicitly taps Done.

## Reference
The public VW_Flash `simos_hsl.py` HSL backend sends `3E04 + B001E700 + FFFF`, expects a response beginning with `7E`, then parses the returned bytes after that first byte.
