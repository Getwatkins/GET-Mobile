GET Mobile v63 — HSL ISO-TP verified Block-Size sender

IMPORTANT BUILD CHECK:
The v63 HSL path logs:
    HSL ISO-TP ENGINE: V63-BS2-CORRECTED

If that exact line does NOT appear in the phone's debug log immediately
after HSL TRANSPORT LOCK ACQUIRED, the IPA was not built from this source.

The corrected sender honors ECU Flow Control:
    30 00 02
    CF1
    CF2
    WAIT FOR NEXT FC
    CF3
    CF4
    WAIT FOR NEXT FC
    ...

A non-zero Block Size is a hard limit. The sender also validates CF sequence
numbers and honors STmin with the existing safe 30 ms minimum pacing.

The previous phone log:
    30 00 02
    21
    22
    23
    24
    25
    26
    27

cannot be produced by this v63 HSL sender. That pattern proves the installed
IPA was running the previous sender implementation.

Build v63 from THIS package and test once. The first few HSL lines will tell
us immediately whether the corrected code is actually installed.
