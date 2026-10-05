# Code Review: tap rebuild / config backup port (uncommitted, 2026-09-16)

## Scope
- Files: `Sources/Mousse/EventTapEngine.swift` (+205/-47), `ConfigStore.swift` (+98), `AccessibilityPermission.swift`, `SettingsView.swift`, `MenuContent.swift`, new `EventTapHealth.swift`, `tools/setup-signing-cert.sh` (modified, NOT new — tracked since bb90d20; plan.md row 5 says "file was missing", inaccurate), tests `EventTapHealthTests.swift`, `ConfigStoreTests.swift`.
- Build: `swift build` clean, 0 warnings. `swift test`: 84/84 pass (7 new health tests, 3 new config tests).
- Plan: all 5 phases marked done; verified.

## Overall
Solid port. Lock discipline is consistent (every lifecycle field read/written under `lock`), teardown order is correct (remove source -> disable -> invalidate), single-thread invariant holds, bounded retry is a clear improvement over the old infinite 1 Hz loop, and the "CFRunLoopRun returned with no sources" case (WindowServer invalidated the port) is now recovered by the watchdog where the old code left a dead thread forever. One real race in the stop delivery (H1) and one UX hole in ConfigStore (M1) should be fixed before commit.

---

## High

### H1. `CFRunLoopStop` can be lost -> `tapRebuildPending` stuck true forever
`EventTapEngine.swift:262-266` (requestEventTapRebuild) vs `:410-417` (threadMain publish -> CFRunLoopRun).

CF's `CFRunLoopStop` only sets the stopped flag when `rl->_currentMode != NULL`, i.e. while the loop is inside `CFRunLoopRunSpecific`. If the main thread reads a non-nil `eventTapRunLoop` (published at :412) and calls `CFRunLoopStop` before the tap thread reaches `CFRunLoopRun()` at :417, the stop is a no-op and `CFRunLoopRun` then runs indefinitely. Same (smaller) window between iterations of CFRunLoopRun's internal `do/while`.

Consequence is permanent: `tapRebuildPending` stays true, so `reEnableTap` (:239) returns early, `requestEventTapRebuild` (:255) returns early, and `tapStatus` reports "Recovering…" forever. The watchdog is neutered; the next real wake-death of the tap is never repaired. Window is microseconds, but a second rebuild request (screen-params notification often arrives 0.5-2 s after `didWake`, outside the 150 ms debounce) lands exactly while thread B is coming up, and this runs on every wake for months.

Fix: deliver the stop through the loop itself, as `ScrollAnimator.swift:497-501` / `:554-566` already do. Blocks enqueued with `CFRunLoopPerformBlock` before the loop starts are executed on the first pass:
```swift
lock.unlock()
NSLog("Mousse: rebuilding event tap (%@)", reason)
CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
    CFRunLoopStop(CFRunLoopGetCurrent())
}
CFRunLoopWakeUp(runLoop)
```
(`CFRunLoopStop` already wakes internally, so the explicit `CFRunLoopWakeUp` at :266 is only needed for the PerformBlock variant.)

## Medium

### M1. "Dismiss" on a protected-config issue hides the only indicator while every save is silently dropped
`ConfigStore.swift:141-143` + `:146`. For `.loadFailed` and `.corruptConfigRecovered(nil)` (`protectsUnreadableConfig == true`), `save()` no-ops with no signal. `dismissPersistenceIssue()` clears the banner AND the menu item but leaves the protection on, so from then on every setting change is lost until relaunch, with zero UI feedback. Fix (any one): (a) hide "Dismiss" when the issue is a protected one; (b) in `save()`'s guard, re-raise the stored issue if `persistenceIssue == nil`; (c) `dismissPersistenceIssue` no-ops while `protectsUnreadableConfig`.

### M2. Menu item "Settings not saved — Retry" is wrong for the backed-up case and dangerous for the protected case
`MenuContent.swift:16-17`. Shown for every non-nil issue. For `.corruptConfigRecovered(path:)` saves work fine, so the label is false. For `.loadFailed` / `.corruptConfigRecovered(nil)` one click overwrites the only copy of the unreadable file with no explanation (the explanatory text only exists in SettingsView). Suggest: show the item only for `.saveFailed`; for protected issues show "Config problem — open Settings…" (SettingsLink) so the user reads the message before consenting. Optionally, `retrySave()` (:135) could attempt `copyItem` to a fresh `corruptBackupURL` once more before the forced write; cheap extra safety.

### M3. `wakeDebounceWorkItem` is documented as "all under lock" but is not
`EventTapEngine.swift:23-35`. It is only touched from `handleWake` on the main thread (NSWorkspace/NSApplication notifications post on main), so it is safe — but the header comment claims lock coverage for the whole block. Move the declaration out of the block or note "main-thread only". Same for `observersInstalled` (:21).

## Low

### L1. `thread === Thread.current` guards are dead
`:386, :399, :426`. `thread` is only assigned by `startTapThreadIfNeeded` when `thread == nil`, and only nil'd by the thread itself, so the identity check is always true. Harmless, but it implies a possible state the code never reaches. Replace with `assert(thread === Thread.current)` or drop it to keep the invariant obvious.

### L2. `tapCreationFailed = false` cleared without an attempt
`:258`. When no thread exists and the 1 s backoff hasn't elapsed, `startTapThreadIfNeeded` no-ops but `tapCreationFailed` is already false, so Settings flips from "Failed — retrying" to "Starting…" for up to 1 s, then back. Cosmetic. Move the reset into `threadMain` on success only (already done at :413), i.e. delete :258.

### L3. `.corruptConfigRecovered(path:)` cleared by the first successful save
`ConfigStore.swift:151`. Any setting change (including the Enable toggle in the menu, before Settings is ever opened) removes the backup-path message. Path is NSLog'd so nothing is lost, and the lead's question of acceptability: acceptable. If you want it sticky, clear on success only when the issue is not `.corruptConfigRecovered(.some)`.

### L4. Rebuild on every `didChangeScreenParametersNotification` inflates "Recoveries since launch"
`:130, :221-222, :434`. Dock resize / resolution change / display hot-plug each count as a recovery. Not a bug; consider labelling the row "Tap rebuilds" or not counting wake-driven rebuilds.

### L5. Requested-rebuild-while-thread-mid-creation is dropped (lead's question)
`:257-263`, thread in the retry loop (`:370-380`, up to 1.85 s). Acceptable: the in-flight creation produces a fresh post-wake tap, and pending is correctly reset to false so nothing is stuck. Only theoretical miss: tapCreate returned just before sleep, thread preempted between :373 and :412 across the whole sleep — not realistic.

### L6. Script exit status
`tools/setup-signing-cert.sh:53`. `|| true` removed under `set -euo pipefail`; if grep finds nothing the script prints "==> done." then exits 1. Arguably correct (identity missing = failure) but reorder so "done" prints after the check, or keep the `|| true`.

### L7. Permission rows do not refresh after Grant
`SettingsView.swift:44-60`. `CGRequestListenEventAccess` prompts asynchronously; the row only re-renders on a `store` change. Pre-existing for Accessibility. Could wrap both rows in the same `TimelineView` as the tap status.

---

## Lead's specific questions

- **Lost rebuild / two threads / stale guard**: rebuild can be lost only via H1 (stop before Run). Two tap threads cannot coexist: `thread == nil` guard under lock + thread nils itself under lock before `startTapThreadIfNeeded`. Guards at L1 are dead, not harmful.
- **`CFRunLoopStop` on an exited loop**: safe. Swift's `runLoop` local holds a +1 on the CFRunLoop; `CFRunLoopStop` on a non-running loop is a no-op (that no-op is exactly the H1 problem in the other direction).
- **`.commonModes` and Stop**: modes are irrelevant to Stop; `CFRunLoopRun` (default mode) returns `kCFRunLoopRunStopped` reliably once the loop is running. Fine.
- **`recordEventTapRecovery()` in the disabled-by-timeout branch**: safe. Lock is fully released before re-acquire (non-recursive unfair lock, no nesting). Cost is one extra lock + `Date()` on a branch that fires only when macOS disables the tap — not on the event hot path.
- **ConfigStore overwrite without consent**: none. Every write is user-driven (`config` didSet -> `scheduleSave`; `flushPendingSave` only when pending), there are no startup mutations of `config`, and protected states short-circuit `save()`. The only unconsented-looking path is M2's one-click menu Retry.
- **`persistenceIssue = nil` on save**: acceptable (L3).
- **`TimelineView` polling `tapStatus()` every 2 s**: no issue. Lock hold is a few field reads; `CGEvent.tapIsEnabled` and `AXIsProcessTrusted` are already called at the same cadence by the watchdog. `.periodic(from: .now, ...)` re-phases on each parent re-render, harmless. Stops when the Settings scene closes.

## Positive
- Explicit teardown (remove source -> tapEnable(false) -> CFMachPortInvalidate) in the right order; no orphaned WindowServer hook.
- "CFRunLoopRun returned with no sources" is now self-healing via the watchdog (old code: dead thread, `tap` left non-nil, permanent).
- Bounded retry + watchdog re-arm replaces an infinite user-interactive sleep loop for users who declined AX.
- `EventTapHealth.resolve` pure and fully tested; `corruptBackupURL` tested for Finder-safe naming.
- `retrySave()` correctly cancels the debounced task before the forced write.

## Recommended actions
1. H1: switch `requestEventTapRebuild` to `CFRunLoopPerformBlock { CFRunLoopStop(CFRunLoopGetCurrent()) }` + `CFRunLoopWakeUp`.
2. M1: make Dismiss unavailable (or a no-op) while `protectsUnreadableConfig`.
3. M2: scope the menu item to `.saveFailed`; route protected issues to Settings.
4. M3/L1/L2: comment + dead-guard cleanup.
5. plan.md row 5: "file was missing" -> "OpenSSL 3 / LibreSSL compatibility".

## Metrics
- Build warnings: 0. Tests: 84 pass / 0 fail. New code under test: EventTapHealth 100%; ConfigStore naming + messages only (disk paths untested, acceptable for a singleton).
- EventTapEngine.swift is 782 lines (pre-existing, well over the 200-line guideline; not introduced here).

## Unresolved
- Does `didChangeScreenParametersNotification` fire on Dock/menu-bar geometry changes on macOS 27? If so, L4 count inflation will be visible to users.
