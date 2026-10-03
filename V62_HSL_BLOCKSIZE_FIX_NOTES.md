GET Mobile v62 — HSL ISO-TP Block Size Fix

Root cause identified by comparison with the working GET Flasher implementation.

GET Flasher uses the OpenPort/J2534 ISO15765 driver, so the driver performs
ISO-TP segmentation and honors ECU Flow Control automatically.

GET Mobile sends raw CAN frames through GVRET/A0, so it must implement the
ISO-TP sender state machine itself.

The ECU returns:
    30 00 02 AA AA AA AA AA

That means:
    Flow Status = Continue To Send
    Block Size = 2
    STmin = 2 ms

The sender must therefore:
    FF
    wait FC
    CF1
    CF2
    wait FC
    CF3
    CF4
    wait FC
    ...

v62 enforces that behavior. A non-zero Block Size is now a hard limit.
Sequence numbers are also checked before every transmitted CF.

The 3E04 poll works with the existing implementation because it only needs
one CF; that explains why it returns the valid 7E Tester Present response
while the larger 3E02 setup was failing.

Build this source through the normal GitHub/XcodeGen workflow.
