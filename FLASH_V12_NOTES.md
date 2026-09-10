# GET Mobile v12 - flashing transport fix

## Fix
The GVRET WiFi transport now queues matching CAN frames that arrive before the next ISO-TP receive continuation is installed. A single TCP read can contain multiple complete CAN frames; the previous implementation could deliver the ISO-TP First Frame and then drop Consecutive Frame #1 when both arrived in the same TCP callback. This is especially visible with multi-frame UDS responses such as VIN (0xF190).

## Flash safety behavior
The unlock sequence now refuses to proceed to RoutineControl 0x0203 if the VIN read fails. It also reads DID 0xF186 (Active Diagnostic Session) after VIN as a session-state sanity check. This prevents the app from continuing into a programming operation when the diagnostic session/ISO-TP receive path has not been proven healthy.

## Expected flash log
- VIN read succeeded
- Active diagnostic session DID 0xF186: 03 (extended diagnostic)
- Checking programming precondition, routine 0x0203...
- positive RoutineControl response

If VIN still fails, the new behavior stops before any programming-precondition routine is sent, rather than continuing in an unknown session state.
