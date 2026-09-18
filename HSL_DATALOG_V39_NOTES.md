# GET Mobile v39 — likely explanation for the "capped at 10", plus new gauge defaults

## The "capped at 10, Select All does nothing" symptom
Traced `selectedNames` (the Set that tracks which channels are picked)
through every place that touches it - the picker, the model, the polling
loop - and confirmed there is no numeric cap anywhere in this app's code.
Manual toggling is a plain `Set.insert`/`.remove`, and "Select All" is a
single `selectedNames = Set(CommonDidCatalog.all.map(\.name))` assignment.

That said, the previous build (v38) shipped a real, separate bug fix: two
pairs of catalog entries (AFR/Lambda, Boost-Vacuum/MAP) intentionally share
the same underlying DID, and `CommonDidEntry`'s SwiftUI id was based on
that DID - so two rows had duplicate ids. Per Apple's own documentation,
`ForEach`/`List` behavior with duplicate ids is explicitly *undefined*, not
just "two rows glitch" - the diffing engine can misbehave more broadly
depending on interaction patterns, which can plausibly look exactly like
"selection stops taking effect past some point" and "a bulk update gets
silently dropped," even though there's no actual numeric limit anywhere.
Fixed in v38 (name-based id, verified unique across all 50 entries) -
carried forward here unchanged.

If this build still shows the same cap after a clean rebuild/reinstall
(not just relaunching an already-installed older build), that would rule
this out and mean there's something else going on worth a fresh, focused
look - but duplicate-id list corruption is a well-documented enough failure
mode, matching this symptom closely enough, that it's the more likely
explanation than an invisible cap that doesn't exist anywhere in the code.

## New gauge defaults
The 6 default gauge slots are now AFR, Engine Speed, Boost/Vacuum, Ign Avg,
IAT, and Oil Temp (previously PUT, Engine Speed, MAP, and three empty
slots). All six resolve to real `CommonDidCatalog` entries - verified exact
name matches, including the two derived ones (AFR, Boost/Vacuum).
