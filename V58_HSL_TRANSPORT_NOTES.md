GET Mobile v58 - HSL transport state-machine stability

Changes from v57:
- HSL multi-frame transmit now has an explicit WAIT_FOR_FLOW_CONTROL -> SEND_CONSECUTIVE_FRAMES state machine.
- A 0x7E8 frame is accepted as Flow Control only when ISO-TP PCI type is 0x3.
- Other 0x7E8 frames are ignored while waiting for the HSL FC.
- HSL consecutive-frame pacing floor increased to 30 ms for the Wi-Fi A0/GVRET bridge.
- Cancellation is checked before each HSL CF.
- v57 decoder crash hardening is retained.
- v56 receive/UI and ISO-TP stability changes are retained.

Recommended test:
1. Start HSL at idle.
2. Confirm setup completes.
3. Let it log 20-30 seconds.
4. Rev the engine several times.
5. Stop and restart HSL 3-5 times.
6. Export debug log if any startup timeout occurs.
