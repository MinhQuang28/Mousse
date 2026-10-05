# Scroll: ceiling decel tail, hi-res speed slider, screenSpan cache

Status: done (2026-09-14) — 74 tests pass, reviewed (H1 fixed by per-frame tail attach, M1/M2/L1 applied)

## Phases
1. **Ceiling decel tail** (`ScrollAnimator`) — a Smooth-mode plan whose backlog outlasts its clock
   (speed ceiling capped it) drains at the ceiling then stops dead. Attach a drag coast from the
   ceiling speed once the backlog fits it; cap plan distance at ceiling × maxDuration (18 000 px)
   instead of 100 000 px. Track last-tick time separately from the plan clock.
2. **Speed slider visible in every mode** (`SettingsView`) — the slider scales hi-res mice in
   Standard and Smooth-step too, but was only shown in Smooth.
3. **screenSpan cache** (new `ScreenSpanResolver`, `EventTapEngine`) — cache display bounds/span
   under the cursor (≈16 µs per notch on the tap thread); flush with the cursor-app cache.
4. Tests for the tail math and cache-free helpers; run `swift test`.

## Todo
- [x] Phase 1  - [x] Phase 2  - [x] Phase 3  - [x] Phase 4
