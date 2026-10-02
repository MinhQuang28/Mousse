import SwiftUI

/// The scroll knobs as one reusable block — the global Scroll tab and every per-device profile
/// (Devices tab) edit the same `ScrollDeviceSettings`, so they can never drift apart.
struct ScrollSettingsEditor: View {
    @Binding var settings: ScrollDeviceSettings

    var body: some View {
        Picker("Scroll style", selection: $settings.scrollMode) {
            ForEach(ScrollMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if settings.scrollMode == .smooth {
            Picker("Smoothness", selection: $settings.scrollSmoothness) {
                ForEach(ScrollSmoothness.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Snappy = direct with a minimal tail (\"Regular\"). Balanced = smooth but responsive. Floaty = long trackpad-like coast ( \"High\").")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Native leaves the OS event alone, so only the reverse toggles apply there.
        let native = settings.scrollMode == .native
        // Shown in Smooth and Windows alike: it scales high-resolution ("continuous") mice in both,
        // so hiding it in Windows would leave a gain set in Smooth applied with no control.
        if !native {
            VStack(alignment: .leading) {
                // Floor of 0.05 (not 0.2): high-res "continuous" mice natively scroll fast, and
                // their gain is speed/0.5 — a 0.2 floor still meant 40% of native, too fast for
                // slow scrollers. 0.05 → 10% of native. Finer step for control at the low end.
                SettingsSlider(title: "Scroll speed", value: $settings.scrollSpeed,
                               range: 0.05...1.5, step: 0.05,
                               format: { String(format: "%.2f×", $0) },
                               minLabel: "Slow", maxLabel: "Fast")
                Text(settings.scrollMode == .smooth
                     ? "Wheel sensitivity per notch; also scales high-resolution (continuous) mice."
                     : "Scales high-resolution (continuous) mice only — a notched wheel moves by Lines per notch (except with ⌥ or ⌃ held).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.scrollMode == .smooth {
            Toggle("Scroll acceleration", isOn: $settings.scrollAcceleration)
        }
        if settings.scrollMode == .smoothStep {
            Stepper(value: $settings.scrollLines, in: 1...10) {
                Text("Lines per notch: \(settings.scrollLines)")
            }
        }
        Toggle("Reverse vertical scroll", isOn: $settings.reverseScroll)
        Toggle("Reverse horizontal scroll", isOn: $settings.reverseScrollHorizontal)
        if !native {
            VStack(alignment: .leading) {
                SettingsSlider(title: "Zoom speed (⌘ + wheel)", value: $settings.zoomSpeed,
                               range: 0.2...6.0, step: 0.1,
                               format: { String(format: "%.1f×", $0) },
                               minLabel: "Fine", maxLabel: "Coarse")
                Text("Pinch-zoom sensitivity per notch, independent of scroll speed. Each notch now glides instead of jumping; lower it if design tools (Figma, Sketch) zoom too far per click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !native {
            Toggle("Smooth high-res mice", isOn: $settings.smoothHighRes)
            Text("Turn on for high-resolution mice that scroll choppily (e.g. Keychron M6) so they use the same smoothing as a notched wheel. Leave OFF for free-spin mice like the MX Master 3 — their hardware flywheel is already smooth and this would fight it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Native = macOS's own scrolling, only the direction reversed (no speed, zoom, modifiers or per-app rules). Smooth = trackpad-style momentum. Windows = Windows-browser feel: each notch eases a fixed number of lines with no coast. Applies to a physical mouse wheel only — trackpad scrolling is left untouched.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
