# GET Mobile v42 — fix a v41 navigation regression (also: idle timer disabled while app is foregrounded)

## Real bug found in v41's ContentView rewrite
The condition deciding when to leave the transport picker and show the new
home hub was `isConnectedReady || demoModeActive || activeKind != nil`.
That last clause was new in v41 and wrong: `activeKind` gets set inside
the `onConnected` callback the moment a connect screen calls it, which for
GVRET WiFi happens to already be gated on `state == .ready` - but nothing
guarantees every connection path calls its completion closure at exactly
that point, and this condition doesn't actually need that guarantee at
all. With `activeKind != nil` in the OR, the app could show the home
hub - and let the user act on Gauges/Logging - based on merely having
*attempted* a connection, not on the transport actually reporting ready.
That's a single, unified explanation for gauges not responding, HSL not
starting, and "takes a few attempts" - the UI could get ahead of a
transport that hadn't actually finished connecting yet.

Fixed: back to `isConnectedReady || demoModeActive` only. The home hub
only ever appears once the transport genuinely reports `.ready`, exactly
as it did before the v41 restructure.

## Second, related fix: stop Live when leaving Gauges
Before v41, Gauges/Logging/Flash were all on one screen, so leaving Live
running while starting HSL essentially couldn't happen without noticing -
Stop Live and Start Logging were right next to each other. Now that
Gauges is its own destination, it's easy to start Live, wander back to
Home, and open Logging without ever tapping Stop Live. The existing
`isHslActive` locking (unchanged, already handled this reasonably) closes
most of the gap, but `GaugesOnlyView` now also stops Live on
`.onDisappear`, closing it at the source instead of relying only on the
lock catching it downstream.

## Separate, unrelated addition: keep the screen awake in the foreground
`GETMobileApp.swift` now disables the idle timer while the app is active
(`UIApplication.shared.isIdleTimerDisabled`, tied to `scenePhase`), mainly
so a flash in progress is never interrupted by the phone auto-locking.
Reverts to normal locking as soon as the app is backgrounded, so it
doesn't override the user's lock settings the rest of the time.

## On "3 attempts to open the WiFi GVRET connection" specifically
Worth separating from the two bugs above: this may not be new to v41 at
all. Earlier in this same investigation there was documented evidence
(a public GitHub issue) of real WiFi reliability problems in the A0's
GVRET/ESP32RET firmware under load - a board that's unreliable to
initially associate/connect to over WiFi is a known characteristic of
that firmware, separate from anything this app does. Worth confirming
whether this also happened before v41, since if so it's not a regression
to chase in this app's code at all.
