# GET Mobile HSL Datalogger v30

## Purpose
v30 targets the remaining HSL startup failure seen with the Macchina A0/A0RET WiFi transport.

## Changes
- Restores the HSL ECU setup list to the complete physical parameter catalog, matching the working Windows `SimosHslLogger` behavior.
- Keeps the UI channel selection separate: selected channels still control what is displayed/exported, while the ECU-side HSL list remains complete.
- Keeps the existing correct 5-byte-per-parameter HSL encoding and `3E02 B001E700 <count> ... 00` format.
- Adds an 8 ms minimum inter-frame margin to the HSL ISO-TP consecutive-frame sender on top of ECU-advertised STmin. This is specifically for WiFi/A0RET buffering and does not alter normal UDS ISO-TP behavior.
- Keeps the one-time HSL setup timeout at 15 seconds and poll timeout at 4 seconds.
- Keeps HSL transactions serialized so gauges/logger cannot interleave the transaction.

## Test expectation
On Start Logging, the debug log should show a full-catalog HSL setup, one ECU Flow Control frame, all consecutive frames transmitted with deliberate pacing, then a positive HSL `0x7E` response. If setup still times out with total silence, the next diagnostic step is to compare the actual CAN frames from the A0 against the Windows/J2534 logger rather than changing UDS timeouts again.
