# GET Mobile v15 — HSL logger fix

## Root cause
The HSL poll request was incomplete. SimosTools/VW_Flash sends `3E 04` followed by the HSL memory offset `B001E700` and `FFFF`. GET Mobile v14 incorrectly sent only `3E 04 FF FF`, which the ECU interpreted as an invalid TesterPresent-style request and correctly rejected with `7F 3E 13` (incorrect message length/format).

## Fixes
- HSL poll request is now exactly `3E 04 B0 01 E7 00 FF FF`.
- A protocol-level `7F 3E xx` poll response stops the logger instead of repeatedly sending the rejected request.
- DatalogView no longer restarts the gauge polling loop from `onDisappear`; this prevents a PID picker/share sheet or transient view transition from starting the normal gauge workload while HSL is active. Gauges resume only when the user taps Done.
- Existing HSL setup remains `3E 02 B0 01 E7 00 <length> <parameter-list>`.

## Reference
VW_Flash `lib/simos_hsl.py` constructs the HSL poll as `3e04 + memoryOffset + FFFF` and sends it as a raw transport request.
