GET Mobile v67

1. App looked "zoomed in" / not fitting the screen
   project.yml now declares a launch screen (INFOPLIST_KEY_UILaunchScreen_Generation)
   and the supported orientations. Without these iOS runs the app in a legacy
   compatibility mode. Xcode has warned about exactly this in every build log
   ("A launch configuration or launch storyboard or xib must be provided").

2. HSL setup still got no reply (v66 log, S50 file, 68 params, 349 bytes)
   What the log proved: payload identical to the desktop's; ECU answered the
   First Frame with Flow Control 30 00 02; all 49 Consecutive Frames went out in
   order (~45 ms apart); then total silence for 15 s.
   v67 adds tools to find out why instead of guessing:
   - "Frame Spacing (ms)" picker on the HSL screen: 2 / 5 / 10 / 30 (default) / 50.
     Gap between Consecutive Frames of the setup request (never below the ECU's STmin).
   - New log line after sending, e.g.
       HSL ISO-TP TX summary: frames=50 elapsed=2231 ms, ECU STmin=2 ms,
       spacing floor=30 ms, longest gap between consecutive frames=71 ms
   - Debug log timestamps now have milliseconds.
   - New bundled file parameters_3e_S50_core14.csv: the 14 parameters from the
     earlier known-good GET Flasher/GVRET trace (same S50 addresses), 79-byte request.
   Marker to confirm the right build: "HSL ISO-TP ENGINE: V67-SPACING".

Files changed: GVRET/IsoTp.swift, GVRET/GvretWifiManager.swift, BLE/UdsTransport.swift,
Model/HslLoggerSession.swift, Views/DatalogView.swift, project.yml (repo root),
Resources/HslParams/parameters_3e_S50_core14.csv (new).
Not compiled locally (no Swift toolchain); syntax-checked only.
