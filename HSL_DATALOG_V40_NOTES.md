# GET Mobile v40 — actual fix for "Select All" acting like "Deselect All"

## Root cause
The id-collision fix in v38/v39 did resolve the manual-selection cap, as
confirmed - that part is done. "Select All" clearing everything instead of
selecting everything is a different, second bug: it was a plain `Button`
placed directly beside "Deselect All" in the same `HStack`, inside a single
List row. Multiple buttons sharing one List row is a known SwiftUI failure
mode - tap-target handling between sibling buttons in the same row is
unreliable, and taps can trigger the wrong button's action (or both).
That's consistent with "Select All" behaving like "Deselect All": the
first button's tap was very plausibly being caught by the second button's
action instead.

## Fix
Moved both actions out of the List body entirely and into a toolbar menu
("Select" in the top-left of the channel picker, with "Select All N" and
"Deselect All" as menu items). Toolbar menu items don't share a List row's
tap-through behavior, so this class of bug can't happen here - each is its
own distinct, unambiguous tap target.
