---
name: project-build-toolchain
description: How to build/test Mousse (plain Xcode 27 works as of 2026-09-16; the earlier Xcode-beta DEVELOPER_DIR is gone) and how to sim animator math standalone
metadata:
  type: project
---

Build/test with plain `swift build` / `swift test` from the repo root. As of 2026-09-16 `/Applications/Xcode.app` is Xcode 27.0 (27A266a) and `xcode-select -p` already points at it; `/Applications/Xcode-beta.app` no longer exists, so do NOT export the old `DEVELOPER_DIR=/Applications/Xcode-beta.app/...` (xcrun errors out).

**Why:** On macOS 27 the CommandLineTools toolchain could not build this package (lead, 2026-09-14); the beta was needed until Xcode 27 shipped. Suite is 84 XCTest cases, runs in ~1 s after a warm build.

**How to apply:** If `swift test` ever fails with a toolchain error, check `xcode-select -p` before assuming code breakage. For verifying scroll-animator behaviour numerically, `Sources/Mousse/ScrollMath.swift` only imports Foundation and compiles standalone: copy it next to a scratch `main.swift` and `xcrun swiftc -O ScrollMath.swift main.swift`. Mirror `step()` (planRate compression, 50 ms plan-time clamp, ceiling per frame) when simulating — the unit tests omit `planRate`.
