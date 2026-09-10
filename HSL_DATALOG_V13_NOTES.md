# GET Mobile v13 — SimosTools-style HSL datalogging

Adds native iOS HSL logging based on the supplied `PIDListHSL-S50.csv` and the public SimosTools/VW_Flash HSL implementation.

- Uses UDS `0x3E 0x02` to install the high-speed parameter list at `0xB001E700`.
- Uses `0x3E 0x04 FF FF` to poll the packed memory values.
- Uses the supplied PID addresses, lengths, signedness, equations, units, min/max and assignments.
- Default selection: Engine Speed, MAP, PUT, Lambda, Torque, Pedal Pos, IAT, Coolant Temp.
- Select/search any supplied PID from the HSL channel picker.
- 5/10/15/20 Hz logging rate options (10 Hz default).
- Live values and a Swift Charts graph.
- CSV export/share from the iOS share sheet.
- Automatically stops the normal gauge live poll while HSL logging is active, then resumes it when the logger view closes.
- Keeps flashing isolated from live logging; the existing flash workflow is not modified.

The HSL request/poll structure follows the public SimosTools/VW_Flash `simos_hsl.py`: HSL setup uses `3E02` + `B001E700` + list length + `[0][length][address]` entries, and HSL polling uses `3E04 FFFF`. See `https://github.com/bri3d/VW_Flash/blob/master/lib/simos_hsl.py`.
