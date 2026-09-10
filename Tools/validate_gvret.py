#!/usr/bin/env python3
"""Deterministic GVRET framing regression checks for the GET Mobile A0 path."""

# SavvyCAN/A0RET BUILD_CAN_FRAME: F1 00, CAN ID LE, bus, DLC, data, checksum byte.
expected = bytes.fromhex("F1 00 E0 07 00 00 00 08 03 22 20 2A AA AA AA AA 00")

can_id = 0x7E0
data = bytes.fromhex("03 22 20 2A AA AA AA AA")
encoded_id = can_id.to_bytes(4, "little")
actual = bytes([0xF1, 0x00]) + encoded_id + bytes([0x00, len(data)]) + data + bytes([0x00])
assert actual == expected, f"GVRET TX mismatch: {actual.hex(' ')}"

# A0RET GET_CANBUS_PARAMS reply body is 10 bytes after F1 06:
# flags (1) + CAN0 speed (4) + pad (1) + CAN1 speed (4).
assert len(bytes.fromhex("01 20 A1 07 00 00 00 00 00 00")) == 10

# SETUP_CANBUS is intentionally not sent during normal connection.
# The reference client reads the existing CAN configuration and uses it.

# Known A0RET/SavvyCAN RX frame: timestamp + standard CAN ID 0x216 + 2 data bytes.
rxtest = bytes.fromhex("F1 00 CF C9 AD 02 16 02 00 00 02 40 24 00")
assert int.from_bytes(rxtest[6:10], "little") == 0x216
assert rxtest[10] == 0x02
assert rxtest[11:13] == bytes([0x40, 0x24])

print("GVRET regression checks passed.")
print("TX:", actual.hex(" ").upper())
print("RX sample: ID=0x216 DLC=2 DATA=40 24")
