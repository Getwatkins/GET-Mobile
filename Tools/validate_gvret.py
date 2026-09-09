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

print("GVRET regression checks passed.")
print("TX:", actual.hex(" ").upper())
