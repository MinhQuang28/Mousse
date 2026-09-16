# Mousse

A lightweight, single-process menu-bar mouse utility for macOS 15+ (Sequoia and later).
It gives a plain USB/Bluetooth mouse the things macOS leaves out: smooth scrolling, button
remapping, and a drag-to-switch-Spaces gesture — without a background helper, a license server,
or any system configuration changes.

## Features

### Scroll

- **Three styles** — _Standard_ (instant wheel, no animation), _Smooth_ (trackpad-style eased
  momentum), and _Smooth-step_ (Windows-browser feel: each notch eases a fixed number of lines
  with no coast).
- **Adjustable speed** — wheel sensitivity in Smooth; in every style it also scales
  high-resolution (continuous) mice — and **lines-per-notch** (Smooth-step).
- **Independent zoom speed** — ⌘ + wheel pinch-zoom sensitivity (0.2×–6×) is decoupled from
  scroll speed, so design tools like Figma can zoom finely while pages still scroll fast.
- **Reverse direction** independent of the system setting.
- **Smooth high-res mice** — opt-in smoothing for high-resolution mice that have no hardware
  flywheel (e.g. Keychron M6) and otherwise scroll choppily. Leave it off for free-spin mice
  like the MX Master 3, whose flywheel is already smooth.
- Trackpad gestures are never touched — only a physical mouse wheel is affected.

### Buttons

- Remap any mouse button to a **preset action** (Move Left/Right a Space, Mission Control,
  App Exposé, Launchpad, media keys) or **record a custom keyboard shortcut** (e.g. ⌘[ / ⌘]
  for browser back/forward, ⌘W, ⌘⇧4).

### Gestures

- **Drag to switch Spaces** — hold a chosen button and drag left/right; one Space jump per
  configurable drag distance. Optionally keeps the pointer pinned in place while dragging.

### Reliability

- Recovers automatically from **sleep/wake** and **display changes** (plugging/unplugging a
  monitor or changing resolution) — the event tap is rebuilt from scratch, not just re-enabled,
  so clicks and scroll never silently die. Settings shows the tap's health and recovery count.
- A **corrupt or unreadable config** is backed up, never overwritten silently; save failures are
  surfaced in Settings and the menu with a retry.
- Correctly handles **high-resolution / free-spin mice** (honors speed and reverse without
  fighting the hardware flywheel).
- Runs as one Swift process with negligible idle CPU and a small, stable memory footprint.

## Requirements

- macOS 15.0 (Sequoia) or later.
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) so it can
  read mouse input.

## Install

> **Note for testers:** Mousse is currently signed with a **local (non-notarized) certificate**
> — there is no Apple Developer ID behind it yet — so macOS will block the app on first launch.
> That warning is expected; the steps below get past it. If you'd rather not trust a pre-built
> binary, build from source instead (no Gatekeeper steps needed).

### Option 1 — Download the pre-built app (3 steps)

**Step 1 — Install.** Download `Mousse.zip` from the
[latest release](https://github.com/MinhQuang28/Mousse/releases), unzip it, and drag
`Mousse.app` into your **Applications** folder.

**Step 2 — Unblock.** Clear the Gatekeeper quarantine flag (one-time; a downloaded,
non-notarized app won't open without it):

```sh
xattr -dr com.apple.quarantine /Applications/Mousse.app
```

Not comfortable with Terminal? Instead: double-click the app once (macOS blocks it), then
System Settings → Privacy & Security → scroll down → **Open Anyway** → open the app again.

**Step 3 — Open & grant access.** Launch Mousse from Applications and grant
**Accessibility** when prompted (System Settings → Privacy & Security → Accessibility →
enable Mousse). Done — the mouse icon appears in the menu bar; click it to configure
scrolling and buttons.

### Option 2 — Build from source

Requires the Xcode (beta) Swift toolchain.

```sh
# One-time per machine: a stable signing identity so Accessibility is granted once and
# survives every rebuild (otherwise the app re-prompts after each build).
tools/setup-signing-cert.sh

# Build the menu-bar .app into build/Mousse.app
./build-app.sh

# Run it
open build/Mousse.app
```

> **Check the signature before trusting a rebuild:** `build-app.sh` looks for the
> **"Mousse Local Signing"** identity in the login keychain and prints
> `==> signing with stable identity (…)` when it uses it. If it prints
> `==> ad-hoc signing` instead, the cert is missing on this machine — run
> `tools/setup-signing-cert.sh` once and rebuild, or every rebuild will get a fresh
> ad-hoc signature and macOS may demand Accessibility be re-granted each time.
> The cert is **per-machine and per-project** (a similar cert from another project,
> e.g. "HiDisplay Local Signing", does not count). Verify what an installed build is
> signed with: `codesign -dvv /Applications/Mousse.app 2>&1 | grep Authority`.

## Usage

Launch the app — it lives in the menu bar (no Dock icon). Open **Settings** (⌘,) for four tabs:
**General** (enable, launch-at-login, permission and event-tap status), **Buttons**, **Scroll**,
and **Gestures**.

## Development

```sh
# Run the test suite (config codec, button actions, scroll math)
swift test

# Package a release: build + zip + sha256 (local only)
tools/package-release.sh

# Same, and publish the GitHub release + upload the zip
tools/package-release.sh --publish
```

### Project layout

| Path                          | Purpose                                                      |
| ----------------------------- | ------------------------------------------------------------ |
| `Sources/Mousse/`          | App source (event tap, scroll animator, settings UI, config) |
| `Tests/MousseTests/`       | Unit tests                                                   |
| `build-app.sh`                | Assemble & sign the `.app` bundle                            |
| `tools/setup-signing-cert.sh` | Create the stable local signing certificate                  |
| `tools/package-release.sh`    | Build, zip, hash, and (optionally) publish a release         |

## License

Mousse is **source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE.md):

- ✅ Free for **personal, noncommercial use** — install it, read the source, modify it, build it yourself, share it for free.
- ❌ **Commercial use is not permitted** — you may not copy this source into your own product, sell it, charge for access to it, or otherwise use it for commercial purposes without a separate license from the author.

Copyright © Ha Minh Quang; no source was copied from it.
