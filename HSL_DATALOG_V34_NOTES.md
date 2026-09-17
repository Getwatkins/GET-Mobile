# GET Mobile v34 — test HSL over the BLE bridge (ESP32 Bridge) instead of GVRET WiFi

## What changed everyone's understanding here
Every protocol-level theory testable without doing something unsafe to the
ECU has now been ruled out over the GVRET WiFi path: byte content, burst
size, frame pacing, session/security state. The user's Windows GET logger
(J2534 OpenPort 2.0) and SimosTools (A0 board over Bluetooth, running the
`esp32-isotp-ble-bridge`/BridgeLEG firmware) both work on this exact car.
Neither of those goes anywhere near the GVRET/WiFi protocol this app has
been using for HSL.

Pulled the actual BridgeLEG firmware source (`isotp_bridge.c`,
`ble_server.c` from Switchleg1/esp32-isotp-ble-bridge) and confirmed it has
zero special-case handling for `0x3E`/HSL - it's a generic bridge that does
full ISO-TP framing and pacing in the firmware itself, directly against the
CAN peripheral in real time, and hands the phone a plain "write a payload,
get back the reassembled response" interface. That's categorically
different from GVRET/WiFi, where every individual CAN frame is its own
round trip over WiFi/TCP before it ever reaches the board's CAN peripheral.

This app already has a complete, working implementation of that BLE
transport (`BridgeManager`, the "ESP32 Bridge" option in the connection
picker) - it's what gauges already use successfully. And
`HslLoggerSession.sendHsl()` already has a fallback path for non-GVRET
transports (`uds.sendRawRequest(request)`) that routes straight through
`BridgeManager.sendRequest`, i.e. through the firmware's own proven ISO-TP
stack. No HSL-specific code changes were needed to make this testable.

## What's new in this build
Only debug visibility, since `BridgeManager` had none of the rich
per-frame tracing `GvretWifiManager` has had all along, and flying blind on
a brand new transport would undo all the diagnostic value built up so far:
- `BridgeManager.debugLog`, logging connection state, every
  `sendRequest` (payload out, frame count, attMTU), every raw BLE notify
  received, and reassembled responses/timeouts - same spirit as the GVRET
  log.
- `BridgeDebugLogView`, wired into the Gauges screen exactly like "GVRET
  Diagnostic Log" is, but labeled "Bridge Diagnostic Log" and only shown
  when connected via ESP32 Bridge.

## What the user needs to do
The A0 board currently has the GVRET/WiFi firmware (A0RET/ESP32RET) on it -
confirmed the same physical board used for all testing so far. To test
this, it needs to be reflashed with the BridgeLEG firmware (release/
installer at https://github.com/Switchleg1/esp32-isotp-ble-bridge/releases,
same firmware SimosTools depends on), then connect via "ESP32 Bridge"
instead of "GVRET WiFi" in this app.

## Still to verify
This should very plausibly get past the setup (`3E02`) request, which is
where every test has died so far. It doesn't guarantee the poll phase
(`3E04`) works cleanly - `UdsTransport.swift`'s own doc comment notes HSL
polling isn't a normal ISO-TP response ("acknowledges with 0x7E and then
streams the configured payload as raw CAN frames"), which the generic
firmware's standard ISO-TP reassembly may or may not handle transparently.
One step at a time: confirm setup succeeds first, with a fresh Bridge
Diagnostic Log either way, before assuming poll will too.
