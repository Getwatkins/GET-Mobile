GET Mobile v66 — HSL now works like the desktop logger (parameter file + 100 ms poll delay)

What changed
------------
1. HSL parameter file picker (new).
   The HSL Datalogger screen has a "Parameter File" menu listing the same
   parameters_3e_<box code>.csv files the desktop app ships (A05, H6G, LB6,
   O20, O30, S50), plus "Import custom .csv..." (desktop's "Browse for custom
   .csv..."). Nothing is pre-selected and Start Logging stays disabled until a
   file is chosen. The choice is kept while the app is running.

2. Why this matters: the old mobile HSL catalog was hardcoded to the S50
   addresses only (compare Airmass 0xD00097B4 in v65 vs 0xD0009768 in O30).
   On any other ECU software version the logger was reading the wrong memory.

3. The ECU list is now the whole file, like desktop.
   3E02 setup sends EVERY polled row of the selected file, in file order
   (68 entries / 349-byte request for the bundled files; verified byte-identical
   to the desktop SimosHslLogger.SetupHsl() output for all six files).
   The PIDs picker now only filters what is displayed/exported. It no longer
   changes what is sent to the ECU.

4. Poll delay = 100 ms (new control, replaces the 5/10/15/20 Hz "Rate" picker).
   Same meaning as desktop "Poll Delay (ms)": a pause after each completed
   poll. Default 100, adjustable 0-1000 in 10 ms steps.

5. Removed the v64 "known-good 14-parameter fallback" setup. It used S50
   addresses regardless of ECU version and re-sent 3E02. Setup is now one
   attempt, like desktop. To use a short list, import a trimmed custom .csv.

6. Robustness: a NaN/Inf float in a channel that isn't on screen no longer
   aborts the whole poll (it matters now that the list is 68 channels).

Files
-----
 new     Model/HslParameterFiles.swift   (HslPid type, file model, CSV loader)
 new     Resources/HslParams/parameters_3e_*.csv   (6 files, copied from desktop)
 edited  Model/HslLoggerSession.swift
 edited  Views/DatalogView.swift
 removed Model/HslPidCatalog.swift       (S50-only hardcoded catalog)
 Transport / ISO-TP / GVRET code is untouched.

How to confirm the right build is installed (phone debug log)
-------------------------------------------------------------
After HSL TRANSPORT LOCK ACQUIRED, the setup line should read:
    HSL ISO-TP START: ... payloadBytes=349 expectedResponseBytes=0
    HSL ISO-TP payload: 3E 02 B0 01 E7 00 01 55 ...
and each poll:
    HSL ISO-TP START: ... payloadBytes=8 expectedResponseBytes=123
If payloadBytes is much smaller than 349, the old build is installed.
(Setup now sends ~49 consecutive frames; with the 30 ms pacing floor expect
roughly 1.5 s before the ack. The setup timeout is 15 s.)

Not verified
------------
Written and syntax-checked on Linux (tree-sitter parse of all 73 Swift files,
0 errors); there is no Swift compiler or Xcode here, so it has NOT been
type-checked or run against an ECU. Build it through the normal GitHub/XcodeGen
workflow. If XcodeGen is configured with an explicit resources list instead of
`sources: path: GETMobile`, add Resources/HslParams/*.csv to it.
