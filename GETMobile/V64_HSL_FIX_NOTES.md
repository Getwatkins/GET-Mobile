GET Mobile v64 — HSL setup/reconnect correction

Changes from v63:

1. Corrected ISO-TP interpretation/documentation of ECU Flow Control.
   `30 00 02` means Continue-To-Send, Block Size 0 (unlimited), STmin 2 ms.
   Therefore v63's transmission of CF1..CF7 after that FC is correct.

2. HSL setup now makes one controlled fallback attempt if the selected-channel
   3E02 request receives no ECU acknowledgement. The fallback uses the exact
   14-parameter memory list captured in the working GET Flasher/GVRET trace:
   Airmass, Airmass SP, Coolant Temp, Engine Speed, FP DI, FP DI SP,
   Fuel Flow HPFP, IAT, Ign Table Value, Lambda, MAP, Pedal Pos, PUT, Torque.
   This list is only a fallback; normal startup still uses the user's selected
   channels first.

3. If the fallback setup succeeds, polling/decode uses that ECU list while the
   UI still publishes only the user's selected channels.

4. GVRET reconnects during HSL no longer force ContentView back to the transport
   selection screen. The active HSL navigation stack remains visible while the
   TCP transport reconnects.

5. Added HSL ownership-aware connection-state handling for remote TCP close and
   receive errors.

6. No automatic infinite 3E02 retry loop was added. A failed selected setup gets
   exactly one known-good fallback attempt, then the error is surfaced.

7. Swift syntax parse check completed successfully with swiftc -parse on all
   Swift source files in this package.

Important:
This package is source/build-ready. A macOS/Xcode runner is still required to
produce the signed/unsigned iOS IPA; this Linux environment cannot run Xcode.
