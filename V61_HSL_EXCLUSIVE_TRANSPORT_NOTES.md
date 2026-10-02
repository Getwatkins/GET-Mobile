# GET Mobile v61 — HSL exclusive A0 transport

## Changes
- Added an HSL-exclusive transaction lock to `UdsTransport` with a default no-op.
- GVRET/A0 now acquires the lock before HSL startup and releases it after HSL stops/fails.
- Existing receive/write continuations are abandoned when HSL claims the transport.
- Normal UDS/gauge `sendRequest` and `waitForResponse` calls are blocked while HSL owns 0x7E0/0x7E8.
- `sendCanFrame` has a second guard so a normal ISO-TP operation already between frames cannot emit another CAN frame after HSL claims ownership.
- HSL `sendHslRequest` requires exclusive ownership.
- Existing v60 ISO-TP Flow-Control, Block Size, STmin, response reassembly, HSL recovery, and crash protections are retained.
- Gauge polling remains paused by `GaugeSessionViewModel.beginHslLogging()`, while the transport-level lock closes the asynchronous hand-off race.

## Expected HSL log
The new build should show:
- `HSL TRANSPORT LOCK ACQUIRED - normal UDS/gauge requests blocked`
- `RX HSL wait frame id=0x7E8 data=30 ...` before any first block of CFs
- with BS=2, only two CFs before the next FC
- no gauge UDS requests during HSL setup/poll
- `HSL TRANSPORT LOCK RELEASED` when HSL ends/fails.

## Validation
The modified Swift transport files pass `swiftc -parse`.
