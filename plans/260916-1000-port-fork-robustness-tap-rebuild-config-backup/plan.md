# Port fork robustness items (Souitou-iop/Mousse → local)

Source: fork `Souitou-iop/Mousse` v0.26.6 (cloned to scratchpad). Local: v0.9.6.
Scope = "mục 1" from the review: bug/robustness only, no new user features.

## Phases

| # | Item | Files | Status |
|---|------|-------|--------|
| 1 | Real event-tap rebuild (`CFRunLoopStop` → teardown → restart), wake debounce 150 ms, recovery count | `EventTapEngine.swift`, new `EventTapHealth.swift` | done |
| 2 | Input Monitoring permission surfaced separately (not gated) | `AccessibilityPermission.swift`, `SettingsView.swift` | done |
| 3 | Bounded tap-creation retry; thread yields, watchdog restarts on permission grant | `EventTapEngine.swift` | done |
| 4 | ConfigStore: back up corrupt config, never overwrite unreadable, surface issue + Retry | `ConfigStore.swift`, `SettingsView.swift`, `MenuContent.swift` | done |
| 5 | `tools/setup-signing-cert.sh`: LibreSSL-safe `-legacy` guard (macOS default openssl rejects the flag) | `tools/setup-signing-cert.sh` | done |

## Key decisions
- Rebuild the tap on every wake/display change (fork's fix for "clicks hang after display wake"): teardown removes run-loop source and invalidates the mach port so WindowServer holds no orphaned hook.
- Engine is NOT gated on Input Monitoring — local has always worked with Accessibility alone. Row is informational (a missing grant can mimic a dead tap).
- `EventTapHealth.resolve` is a pure function → unit-tested. ConfigStore is a disk-backed singleton; only `corruptBackupURL` naming is tested.
- Skipped from fork: Diagnostics panel, Localization, HID bridge, all feature work.

## Tests
- `Tests/MousseTests/EventTapHealthTests.swift` (new)
- `Tests/MousseTests/ConfigStoreTests.swift` (new, backup URL naming)
- `swift build` + `swift test` must pass.
