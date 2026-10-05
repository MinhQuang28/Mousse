---
name: mousse-logitech-hardware
description: Dev machine's Logitech test hardware for mousse (MX Master 3S over BLE) and what its HID++ control table contains
metadata:
  type: project
---

mousse's dev/test Logitech hardware is an **MX Master 3S connected over Bluetooth LE** (VID 0x046D,
PID 0xB034). No Unifying/Bolt USB receiver is available on this machine.

Consequences for HID++ / DPI-button work:
- macOS exposes it as ONE `IOHIDDevice` with usage pairs `0x0001/0x0002`, `0x0001/0x0001` and
  `0xFF43/0x0202` — there is no permission-free vendor-only entry, and it carries
  `RequiresTCCAuthorization = 1`, so Input Monitoring is mandatory to open it.
- It has **no dedicated DPI button**; the divertable target is the wheel mode-shift button,
  CID `0x00C4`. `0x00FD` / `0x00ED` are absent from its control table.
- The **receiver code path (device-index probing 0x01–0x06) cannot be tested here** — treat any
  receiver support as unverified/beta until someone with the hardware confirms it.

**Why:** these facts were established by probing the real device while planning
`plans/260826-1545-logitech-dpi-button-hidpp-diversion/`, and they are not derivable from the repo.

**How to apply:** when planning or reviewing HID++ work in mousse, assume BLE-direct
(device index 0xFF) is the verified path, and require receiver claims to be marked untested.
