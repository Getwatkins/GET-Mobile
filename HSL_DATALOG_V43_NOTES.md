# GET Mobile v43 — HSL crash (likely), square tiles, persistent logo

## HSL crash 5-10s after Start Logging
Leading theory: HSL can sustain a much higher real sample rate than the
Standard/DID logger, since one HSL poll returns every channel at once
instead of one request per channel (up to 20Hz is selectable, default
10Hz). Every `samples.append` is a `@Published` change, and the live graph
redraws its entire Swift Charts view from scratch on each one. Doing that
10-20 times a second is expensive enough that it was very plausibly
backing up the main thread faster than it could keep up - after several
seconds of that, iOS's watchdog can kill an app that's stayed unresponsive
long enough, which matches "crashes 5-10s in" better than an immediate,
deterministic bug would (checked the decode/parsing path for force-unwraps
or out-of-bounds access - didn't find any).

Fix: `HslLoggerSession` now records every sample into an internal buffer
at full rate (recording quality/CSV accuracy unaffected), but only
publishes into the `@Published samples` array - the thing that actually
triggers a chart redraw - at most 10 times a second, regardless of the
selected poll rate. The live numeric grid still updates every poll (cheap
Text updates, not worth throttling). Buffered samples are flushed on stop,
clear, and a fresh start, so nothing is lost at the edges.

This is my best-supported theory, not a confirmed root cause - there's no
crash log to point at a single definitive line. If it still crashes on
this build, that would be a genuinely useful data point (rules out the
chart-churn theory), and I'd want to try for an actual device crash log
next (Xcode -> Window -> Devices and Simulators -> your phone -> View
Device Logs) rather than guess a third time.

## Home screen: square tiles
Gauges/Logging/Flash are now a 2-column grid of square tiles (icon +
label) instead of stacked wide rectangles.

## Logo stays at the top everywhere
New `.withTopLogo()` view modifier puts the logo in the navigation bar on
every section - Home, Gauges, Logging, HSL Datalogger, Standard Logger,
Flash - not just the home screen. Home's old large banner+text header was
replaced by this so there's one consistent place the logo lives everywhere
you go, small and out of the way of actual content.
