# GET Mobile v36 — a working CSV logger that doesn't use HSL at all

## What this is
A new, separate "Standard Logger (CSV)" alongside the existing "HSL
Datalogger" button on the Gauges screen. It records data the exact same
way the gauges already read it successfully, every time, throughout this
entire investigation: sequential UDS `0x22` (ReadDataByIdentifier)
requests, one per selected channel, each its own complete request/response
round trip - not a single large multi-frame burst like HSL's `0x3E`
protocol, which is exactly the part that's never once gotten a response
over the GVRET WiFi connection.

This isn't a workaround bolted onto HSL - it's a genuinely different,
independent logging path with its own model, view, and channel catalog,
built specifically so it doesn't share any of the code that's been the
subject of this whole debugging session.

## New files
- `DidLoggerSession.swift` - the recording session: same public shape as
  `HslLoggerSession` (`isRunning`, `sampleCount`, `samples`, `exportCSV()`,
  etc.) so it plugs into a near-identical UI, but internally just loops
  `uds.readDataByIdentifier(did)` per selected channel every cycle - the
  same call `GaugeSessionViewModel.pollAllSlots()` already makes for the
  live gauges.
- `DidLoggerView.swift` - the logger screen and channel picker, mirroring
  `DatalogView`/`HslPidPicker`'s layout and controls, but built on
  `CommonDidCatalog` (47 real channels - Engine Speed, MAP, PUT, Lambda,
  Torque, Knock per cylinder, Misfires, Turbo Speed, Wastegate, and more)
  instead of `HslPidCatalog`'s HSL memory-address list. Not limited to the
  6 gauge slots - pick as many of the 47 as you want to log.

## Wired into GaugesView
A new "Standard Logger (CSV)" button next to "HSL Datalogger", using the
exact same ownership lock (`beginHslLogging()`/`endHslLogging()`) so it
can't race normal Live gauge polling on the shared transport - reused
as-is rather than inventing a second lock, since that logic has been
solid throughout.

## The honest tradeoff
This will be slower per-channel than HSL claims to be, especially with
many channels selected, since each one is a separate round trip rather
than one bulk response. That's the real cost of using the path that
actually works instead of the one that's been the entire subject of this
conversation. Selecting fewer, higher-priority channels will log faster;
selecting all 47 will be noticeably slower per full cycle.

## Not yet done
No live testing yet - this is new code, not something already proven the
way the gauge-reading it's built on has been. Worth a first test with a
handful of channels (the default 8 match HSL's old defaults) before
loading up all 47.
