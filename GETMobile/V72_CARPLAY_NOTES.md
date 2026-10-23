GET Mobile v72 - new icons + CarPlay

Icons
- Gauges / Logging / Diagnostics / Flash tiles now use custom artwork
  (Assets.xcassets/IconGauge, IconLog, IconDiag, IconFlash). Gold bezel gauge,
  waveform screen, OBD-II port with pulse, ECU chip with red bolt.
- Mono template glyphs for the CarPlay tab bar: TabGauge/TabLog/TabDiag/TabFlash.

CarPlay (Driving Task category, template depth <= 3)
- Gauges: live values + Start/Stop Live.
- Logging: start/stop HSL and Standard loggers, shows sample count/time/file.
  Parameter file is chosen on the phone (wrong file = wrong memory addresses).
- Diagnostics: read ECM/TCM codes (shown on a pushed screen), clear with a
  confirmation alert.
- Flash: READ-ONLY status (progress, step, result). Starting/cancelling a flash
  is intentionally phone-only.
- Connecting to the ECU is done on the phone; the car shows the same session.

Code
- AppModel (Model/AppModel.swift) now owns the transports and sessions so the
  phone UI and CarPlay scene share one ECU connection. ContentView reads it.
- CarPlay/CarPlaySceneDelegate.swift, CarPlay/CarPlayController.swift.
- project.yml: generated Config/Info.plist (CarPlay scene) and
  Config/GETMobile.entitlements (com.apple.developer.carplay-driving-task).
- Workflow checks the CarPlay scene and all 8 new assets are in the build.

REQUIRED for it to appear in a car
- Apple must grant the CarPlay entitlement to your developer account
  (https://developer.apple.com/contact/carplay) and your signing profile must
  include it. A normal/free account or a sideload re-sign without it will
  install and run fine, but CarPlay will not show the app.
- Without a Mac/entitlement you can still test in the Xcode simulator
  (I/O > External Displays > CarPlay).

Not compiled locally; syntax-checked only. Untested on a real head unit.
