GET Mobile v71 - full flashes now leave the ECU out of flash mode

Cause: CBOOT patching was a manual toggle (default OFF) shown only in Unlock mode;
Normal Flash could never patch. The desktop decides it from the mode:
  ShouldPatchCboot = Unlock or Normal.
A full flash that writes an UNPATCHED CBOOT with a modified ASW/CAL makes the
bootloader reject them, so the ECU stays in flash mode after the reset (CAL-only
never touches CBOOT, which is why it always worked).

Changes
- FlashMode gains "Flash Stock / Re-Lock" (full 5-block flash, CBOOT NOT patched).
- shouldPatchCboot is derived from the mode (Unlock, Normal = true; CAL-only,
  Stock Relock = false). The manual toggle is removed; the screen shows the CBOOT
  status for the selected mode, and the flash log's first line states it.
- Mode picker is a menu (4 long labels do not fit a segmented control).
- If the post-reset steps get no answer, the final message now says so and tells
  you to cycle the ignition and check the Flash Mode (it was a bare "DONE!").
  This is a note, not a failure: that step can time out on a good flash.

Not changed: reset sequence (identical to the desktop), CAL-only, TCM/DSG.
Not compiled locally; syntax-checked only.
