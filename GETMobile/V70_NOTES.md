GET Mobile v70 - fast flash pacing now actually applies

Root cause: BLE/UdsTransport.swift declared setBulkTransferPacing only in the
protocol EXTENSION (no-op default), not as a protocol REQUIREMENT. UdsClient
calls it through the UdsTransport existential, so Swift bound the call to the
no-op and GvretWifiManager.setBulkTransferPacing was never reached. The
"bulk transfer pacing override" (1 ms in v65, 0 ms in v69) therefore never took
effect: every ECM flash ran at the 30 ms default floor (~39 ms/frame measured
with ~7 ms bridge send time). This bug is in the original v65 file.

Fix: add `func setBulkTransferPacing(_ intervalSeconds: Double?)` as a protocol
requirement. Extension default stays for ELM327 transports.

How to confirm on the phone (debug log at flash start):
  "Bulk transfer pacing override active: no extra floor - frames paced by the ECU's own STmin only."
and consecutive frames should be ~8 ms apart instead of ~39 ms.

Expected: ~8 ms/frame (bridge send latency dominates) -> ~10 min per ~75,000 frames
instead of ~49 min. Applies to Simos18 ECM CAL flashing (FlashBlockRunner) only.
Patch write (PatchBlockRunner) and DSG keep their conservative pacing.

Not compiled locally; syntax-checked only.
