# GET Mobile v37 — select all 47 channels, scrub the log after stopping

Two additions to the Standard Logger (CSV), now that it's confirmed working:

## Select All / Deselect All
The channel picker (tap "Channels") now has "Select All 47" and "Deselect
All" at the top, instead of only being able to tap each of the 47
individually. Selecting more channels means a slower per-cycle update rate
(same tradeoff as before - each one is still its own request), which is
called out right in the picker.

## Scrub the log after stopping
The graph is now interactive: tap or drag anywhere on it to inspect any
point in the recording. The "Live"/values grid above the graph switches to
show every selected channel's value at that exact moment instead of the
latest live reading, with a timestamp and a "Back to Live" button to
return to normal. A vertical marker line (plus a highlighted point on
the currently-graphed channel) shows exactly where the selection is.

This works on whichever channels are selected for logging, not just the
one channel currently plotted on the graph - drag through the recording to
see, say, boost, torque, and knock across all 4 cylinders all update
together at whatever moment you land on, the same way the live values grid
already showed everything at once while running.

Scrub position resets automatically when Start Logging or Clear is tapped,
so a stale selection from a previous run can't linger and confuse a new
one.
