import SwiftUI

/// The Settings window (⌘,). Tabs: General, Buttons, Scroll, Devices, Gestures.
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
            DevicesView().tabItem { Label("Devices", systemImage: "cable.connector") }
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
            if let issue = store.persistenceIssue {
                persistenceIssueBanner(issue)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if AccessibilityPermission.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { AccessibilityPermission.openSettings() }
                    }
                }
                // Not required for the mouse tap — shown because a missing grant can look exactly
                // like a dead tap on some macOS releases, and it's the first thing to check then.
                LabeledContent("Input Monitoring") {
                    if InputMonitoringPermission.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { InputMonitoringPermission.request() }
                    }
                }
                Text("Input Monitoring is optional. Grant it only if scrolling or buttons stay dead after Accessibility is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Event tap") {
                // Re-read every 2 s while the window is open; nothing else needs to publish it.
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    let status = EventTapEngine.shared.tapStatus(now: context.date)
                    LabeledContent("Status") {
                        Label(status.health.label, systemImage: status.health == .healthy
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.health == .healthy ? .green : .orange)
                    }
                    LabeledContent("Recoveries since launch") {
                        Text("\(status.recoveryCount)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func persistenceIssueBanner(_ issue: ConfigPersistenceIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            HStack {
                Button(store.saveIsBlocked ? "Overwrite with current settings" : "Retry Save") {
                    store.retrySave()
                }
                if !store.saveIsBlocked {
                    Button("Dismiss") { store.dismissPersistenceIssue() }
                }
            }
        }
    }

    private var buttonsTab: some View {
        ButtonMappingsView()
    }

    private var scrollTab: some View {
        Form {
            ScrollSettingsEditor(settings: $store.config.scrollSettings)
            if !store.config.deviceProfiles.isEmpty {
                Text("Mice with their own profile (Devices tab) ignore these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Native ignores modifiers and per-app rules — only show them when some mouse can use them.
            if store.config.scrollMode != .native || !store.config.deviceProfiles.isEmpty {
                Section("Modifier keys while scrolling") {
                    Text("⇧ Shift — scroll horizontally (swaps the axes)\n⌥ Option — precise: a few pixels per notch for fine control\n⌃ Control — quick: about half a window per notch, long glide\n⌘ Command — zoom: a real trackpad pinch (browsers, Preview, Maps…)")
                        .font(.caption)
                }
                ExcludedAppsView()
                TransposedAppsView()
            }
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
                    SettingsSlider(title: "Drag distance per Space",
                                   value: $store.config.spaceDragThreshold,
                                   range: 100...400, step: 10,
                                   format: { "\(Int($0)) px" })
                }
                Toggle("Reverse drag direction", isOn: $store.config.spaceDragReverse)
                Toggle("Keep pointer in place while dragging", isOn: $store.config.spaceDragLockPointer)
            }
            Text("Hold the chosen button and drag left/right to switch Spaces. Follow-finger drives the real macOS slide (like a three-finger trackpad swipe); turn it off for discrete one-jump-per-distance switching. Vertical drags trigger Mission Control (up) or App Exposé (down). On macOS 27+ discrete jumps are used regardless, until follow-finger is ported.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
