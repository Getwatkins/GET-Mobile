# GET Mobile v25 HSL logger fix

Based on GETMobile v24.

## HSL protocol changes
- Replaced the single giant HSL setup request with the SimosTools MODE_3E sequence.
- Address lists are sent as 0x3E 0x32 chunks of at most 0x8F bytes.
- Each setup chunk validates the ECU acknowledgement `7E 00 <chunk length>`.
- Sends the final `3E 33 B0 01 E7 00` persist/enable command and validates `7E 00 FF`.
- Polling uses `3E 33 B0 01 E7 00` to obtain each packed HSL sample.
- HSL value decoding now follows SimosTools MODE_3E big-endian decoding.
- Gauge/HSL ownership separation from v24 is retained.

The SimosTools reference implementation builds the 3E address table in 0x8F-byte chunks and uses the final 3E33 command to enable the stream.
