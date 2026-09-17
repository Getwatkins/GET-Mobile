# GET Mobile v35 — A0 stuck on WiFi firmware: ELM327 Bluetooth as a no-reflash option

## Why
The user's A0 won't connect to their laptop, so reflashing it to BridgeLEG
(v34's plan) isn't currently possible. The same firmware already on the
board (ESP32RET/A0RET) supports a second mode with zero reflash needed:
ELM327 Bluetooth emulation (Macchina's own docs: "A0RET allows A0 to work
with SavvyCAN via Wi-Fi... connect to ELM327-A0 [over Bluetooth]" - it's the
same firmware, just a different radio/protocol front-end). GET Mobile
already has an `Elm327BluetoothManager` transport for this, currently
unused/untested against real hardware per its own doc comment.

## Real bug found and fixed while checking this path
`Elm327Protocol.extractUdsResponse` only recognized responses starting with
`0x62` (ReadDataByIdentifier) or `0x7F` (negative response) as valid -
meaning a `0x7E...` HSL/TesterPresent ack or a `0x50...` session-control
response would have been silently treated as unparseable, regardless of
whether the adapter/ECU exchange itself worked. Added `0x7E` and `0x50` to
the recognized set. This was a real gap independent of anything about A0
firmware or wire timing - worth fixing regardless of which transport ends
up being used.

## Honesty about where this stands
Unlike the BLE bridge path (proven via SimosTools) or GVRET WiFi (exhaustively
tested this whole session), ELM327 emulation has never been tested against
real hardware in this app. Real ELM327 chips and clones vary a lot in how
well they handle CAN auto-formatting for *outbound* multi-frame requests
(the `ATCAF1` setting), which is exactly what the HSL setup request needs -
some handle it fine, some don't. This is worth trying specifically because
it requires no hardware changes, not because it's known to work.
