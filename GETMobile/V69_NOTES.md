GET Mobile v69 (cumulative: includes v68)

Flash
- IsoTp.minimumFlashTransferIntervalSeconds 0.001 -> 0.0. Consecutive frames of the
  ECM CAL transfer are now spaced only by the STmin the ECU requests in its Flow
  Control frame. Sleep is skipped entirely when the delay is 0.
- Applies to Simos18 ECM flashing only (FlashBlockRunner useFastPacing). The CBOOT
  patch write and DSG/TCM flashing keep their conservative pacing.
- Debug log line to look for at flash start:
    "Bulk transfer pacing override active: no extra floor - frames paced by the ECU's own STmin only."
- Expectation: per-frame cost is dominated by handing each frame to the bridge
  (~3.9 ms measured in the HSL log), so 0 ms saves roughly 1 ms of ~5 ms per frame
  (~20%: about 6.2 -> 4.9 min per ~75,000-frame CAL block). Bigger gains need
  pipelined/batched sends - not done.

HSL (from v68): one automatic setup retry, frame-spacing default 2 ms, request size
shown on screen, bisect files parameters_3e_S50_test{20,28,36,44,52,60}.csv.

Not compiled locally; syntax-checked only.
