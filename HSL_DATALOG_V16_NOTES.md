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


## HSL transport fix
The GVRET HSL sender now uses a dedicated ISO-TP transmit path. It accepts the
ECU's initial Flow Control (including BS=2) and streams all Consecutive Frames
for the HSL request instead of waiting for a second FC. Normal UDS ISO-TP still
honors block size. This addresses the observed `30 00 02` followed by logger
timeouts during the large 0x3E HSL setup/read request.
