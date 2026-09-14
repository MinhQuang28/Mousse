import SwiftUI

/// The Settings window (⌘,). Three tabs: General, Buttons, Scroll.
struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore

    // Deliberately NOT seeded from `LoginItem.isEnabled`. A `@State` default expression re-runs
    // every time the view struct is built, and `Settings { SettingsView() }` rebuilds it on every
    // App-body pass — including while the window has never been opened. That put a synchronous
    // SMAppService XPC round-trip inside every SwiftUI graph update on the main thread, for a value
    // SwiftUI then throws away (the first install wins). Read the real status in `.task` instead:
    // once, when the window actually appears.
    @State private var launchAtLogin = false

    var body: some View {
        TabView {
            generalTab.tabItem  { Label("General", systemImage: "gearshape") }
            buttonsTab.tabItem  { Label("Buttons", systemImage: "computermouse") }
            scrollTab.tabItem   { Label("Scroll", systemImage: "scroll") }
            gesturesTab.tabItem { Label("Gestures", systemImage: "hand.draw") }
        }
        .frame(width: 480, height: 360)
        .padding()
        .task { launchAtLogin = LoginItem.isEnabled }
    }

    private var generalTab: some View {
        Form {
            Toggle("Enable Mousse", isOn: $store.config.enabled)
            // Side effect lives in the binding's setter, not in `onChange`. `onChange` fires for
            // any write to the state, so the `.task` load and the resync below would both bounce
            // straight back into SMAppService, asking it to register the state it just reported.
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    LoginItem.setEnabled(newValue)
                    launchAtLogin = LoginItem.isEnabled // resync: registration can fail
                }))
            LabeledContent("Accessibility") {
                if AccessibilityPermission.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant…") { AccessibilityPermission.openSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var buttonsTab: some View {
        ButtonMappingsView()
    }

    private var scrollTab: some View {
        Form {
            Picker("Scroll style", selection: $store.config.scrollMode) {
                ForEach(ScrollMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if store.config.scrollMode == .smooth {
                Picker("Smoothness", selection: $store.config.scrollSmoothness) {
                    ForEach(ScrollSmoothness.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Snappy = direct with a minimal tail (\"Regular\"). Balanced = smooth but responsive. Floaty = long trackpad-like coast ( \"High\").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Shown in EVERY mode: the slider scales high-resolution ("continuous") mice in
            // Standard and Smooth-step too, so hiding it there left a gain the user had set in
            // Smooth silently applied with no control to change it.
            VStack(alignment: .leading) {
                Text("Scroll speed: \(String(format: "%.2f×", store.config.scrollSpeed))")
                // Floor of 0.05 (not 0.2): high-res "continuous" mice natively scroll fast, and
                // their gain is speed/0.5 — a 0.2 floor still meant 40% of native, too fast for
                // slow scrollers. 0.05 → 10% of native. Finer step for control at the low end.
                Slider(value: $store.config.scrollSpeed, in: 0.05...1.5, step: 0.05) {
                    Text("Scroll speed")
                } minimumValueLabel: { Text("Slow").font(.caption) }
                  maximumValueLabel: { Text("Fast").font(.caption) }
                Text(store.config.scrollMode == .smooth
                     ? "Wheel sensitivity per notch; also scales high-resolution (continuous) mice."
                     : "Scales high-resolution (continuous) mice only — a notched wheel keeps its native step in this mode (except with ⌥ or ⌃ held).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.config.scrollMode == .smooth {
                Toggle("Scroll acceleration", isOn: $store.config.scrollAcceleration)
            }
            if store.config.scrollMode == .smoothStep {
                Stepper(value: $store.config.scrollLines, in: 1...10) {
                    Text("Lines per notch: \(store.config.scrollLines)")
                }
            }
            Toggle("Reverse scroll direction", isOn: $store.config.reverseScroll)
            if store.config.scrollMode != .standard {
                Toggle("Smooth high-res mice", isOn: $store.config.smoothHighRes)
                Text("Turn on for high-resolution mice that scroll choppily (e.g. Keychron M6) so they use the same smoothing as a notched wheel. Leave OFF for free-spin mice like the MX Master 3 — their hardware flywheel is already smooth and this would fight it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Standard = instant wheel (no animation). Smooth = trackpad-style momentum. Smooth-step = Windows-browser feel: each notch eases a fixed number of lines with no coast. Applies to a physical mouse wheel only — trackpad scrolling is left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Modifier keys while scrolling") {
                Text("⇧ Shift — scroll horizontally (swaps the axes)\n⌥ Option — precise: a few pixels per notch for fine control\n⌃ Control — quick: about half a window per notch, long glide\n⌘ Command — zoom: a real trackpad pinch (browsers, Preview, Maps…)")
                    .font(.caption)
            }
            if store.config.scrollMode != .standard {
                ExcludedAppsView()
            }
            TransposedAppsView() // axis-swap works in every scroll mode, including Standard
        }
        .formStyle(.grouped)
    }

    private var gesturesTab: some View {
        Form {
            Picker("Drag to switch Spaces", selection: $store.config.spaceDragButton) {
                Text("Off").tag(0)
                ForEach(3...9, id: \.self) { Text("Button \($0)").tag($0) }
            }
            if store.config.spaceDragButton != 0 {
                Toggle("Follow-finger animation", isOn: $store.config.spaceDragFollowFinger)
                if !store.config.spaceDragFollowFinger {
                    VStack(alignment: .leading) {
                        Text("Drag distance per Space: \(Int(store.config.spaceDragThreshold)) px")
                        Slider(value: $store.config.spaceDragThreshold, in: 100...400, step: 10)
                    }
                }
                Toggle("Reverse drag direction", isOn: $store.config.spaceDragReverse)
            }
            Text("Hold the chosen button and drag left/right to switch Spaces. Follow-finger drives the real macOS slide (like a three-finger trackpad swipe); turn it off for discrete one-jump-per-distance switching. Vertical drags trigger Mission Control (up) or App Exposé (down). On macOS 27+ discrete jumps are used regardless, until follow-finger is ported.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
