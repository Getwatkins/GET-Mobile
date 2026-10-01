# GET Mobile v59 - HSL State Recovery

Based on the v58 test log and earlier full HSL trace.

Changes retained from v57/v58:
- HSL decoder crash hardening.
- GVRET/CAN UI-load reduction.
- ISO-TP Flow-Control validation before HSL consecutive frames.
- Conservative HSL CF pacing.

New v59 changes:
- Log the exact 0x7E8 frame that satisfies an active receive wait.
- HSL setup (3E02) remains the normal first step.
- If 3E02 setup times out/fails, perform exactly one 3E04 recovery read.
- If the recovery 3E04 returns a valid 0x7E response and decodes successfully, treat the ECU as already HSL-configured and continue logging without repeating setup.
- If recovery also fails, report the recovery failure.

Reason: the supplied traces show the ECU granting HSL Flow Control (30 00 02) and accepting the complete multi-frame setup request, but sometimes not returning the expected setup acknowledgement. The repeated-start symptom is consistent with the ECU retaining an HSL configuration after an interrupted app session; v59 tests that state without repeatedly transmitting 3E02.
