# GVRET WiFi diagnostic changes

## What changed

- Corrected `GET_CANBUS_PARAMS` stream length from 9 to 10 bytes. A0RET sends 1 flag byte + 4-byte CAN0 speed + 1 pad byte + 4-byte CAN1 speed.
- GVRET TCP writes now await `NWConnection`'s `contentProcessed` completion and surface send errors in the diagnostic log.
- Every GVRET transmit is logged as the exact raw byte sequence sent to the A0.
- Added **CAN TX Test** to the GVRET diagnostic log. It sends exactly:
  - CAN ID: `0x7E0`
  - DLC: `8`
  - Data: `03 22 20 2A AA AA AA AA`
  - Expected ECU response ID: `0x7E8`

## A/B test

Use SavvyCAN and GET Mobile separately. Both should send the same CAN payload. If SavvyCAN receives a `0x7E8` response while GET Mobile does not, continue debugging the app's GVRET path. If neither receives a response, investigate the A0 CAN TX path, CAN wiring/termination, ECU power/wake state, and CAN bitrate first.

The GVRET framing used here follows the public A0RET firmware and SavvyCAN implementation.


## v5 GVRET fixes

- `SETUP_CANBUS (F1 05)` now includes the required trailing terminator byte. The
  previous implementation sent only 10 bytes instead of the 11-byte command
  used by SavvyCAN/A0RET, which can leave the A0's command parser waiting for
  one more byte and consume the next CAN command incorrectly.
- `KEEPALIVE/validation (F1 09)` is treated as having no reply body. A0RET
  resets its validation state on this command but does not send a two-byte
  `0xDE 0xAD` response. The old parser could therefore remain in a skip state
  and swallow the beginning of the next incoming CAN frame.
