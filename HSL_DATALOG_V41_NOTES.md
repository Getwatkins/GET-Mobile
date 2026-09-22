# GET Mobile v41 — home hub screen: Gauges / Logging / Flash as their own sections

HSL is confirmed working now, and the channel-selection bugs from the last
few builds are resolved. This build is a navigation restructure, not a
protocol/logging change.

## New structure
Connecting (or entering demo mode) now leads to a home hub (`HomeMenuView`)
with three cards - Gauges, Logging, Flash ECU - instead of dropping
straight into one long scrolling screen with everything on it. Each pushes
onto a shared navigation path, so the system back arrow returns to the hub
from anywhere, including from two levels deep (Standard Logger -> Logging
-> Home).

- **Gauges** -> `GaugesOnlyView` - just the dial grid and live-polling
  controls now; logging/flash/diagnostics moved out.
- **Logging** -> `LoggingMenuView`, a second small hub to pick HSL
  Datalogger or Standard Logger (CSV), each pushing further.
- **Flash ECU** -> unchanged `FlashView`, now pushed instead of presented
  full-screen.
- Diagnostic log buttons (GVRET/Bridge) moved to the home screen itself,
  since they're connection-level tools rather than gauge-specific.

## New/changed files
- `HomeRoute.swift` - the route enum shared by the whole nav stack.
- `HomeMenuView.swift` - the new hub screen.
- `LoggingMenuView.swift` - the new logging sub-hub.
- `GaugesOnlyView.swift` (renamed from `GaugesView.swift`) - trimmed to
  just gauges.
- `ContentView.swift` - now wraps the connected state in one
  `NavigationStack` with `.navigationDestination(for: HomeRoute.self)`
  driving all four destination screens from a single shared path, instead
  of a web of `fullScreenCover`s.

## One structural fix required
`DatalogView` and `DidLoggerView` each used to wrap their own content in a
`NavigationStack`, needed when they were presented modally via
`fullScreenCover`. Now that they're pushed onto the home hub's own
`NavigationStack` instead, keeping their own nested one would have created
invalid nested navigation containers (unpredictable back-button/nav-bar
behavior). Removed both inner wrappers - their `.toolbar`/`.navigationTitle`
now attach directly to the outer stack, and `dismiss()` on their "Done"
buttons still works correctly, popping one level as expected. Their
sheet-presented channel pickers (`HslPidPicker`, `DidChannelPicker`) keep
their own `NavigationStack`, since sheets are a separate presentation
context and still need one.

All the HSL ownership-lock timing (acquired before navigating away from
the logging hub, released on Done) carries over unchanged - it never
depended on which presentation mechanism was used.
