# GET Mobile v27 — HSL ISO-TP transaction fix

Based on the working Windows Simos18 logger supplied by the user.

- Keeps the proven 3E02 B001E700 setup and 3E04 B001E700 FFFF poll commands.
- HSL transmit waits for the ECU's initial ISO-TP Flow Control, then sends the complete consecutive-frame request without speculative second-FC reads.
- Removed the adaptive 150 ms second-FC probe because it could race the ECU's final HSL response.
- Increased the HSL transaction timeout to 6 seconds.
- Added explicit HSL phase logging so the debug trace identifies whether timeout occurs waiting for Flow Control or waiting for the final 7E acknowledgement/data.
- Gauge behavior is unchanged.
