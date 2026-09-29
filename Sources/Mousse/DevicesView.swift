import SwiftUI

/// Devices tab: per-mouse scroll profiles. Lists the connected mice plus any saved profile whose
/// mouse is currently unplugged; turning "Custom settings" on seeds a profile from the global
/// Scroll settings, turning it off deletes the profile (the mouse falls back to the global ones).
struct DevicesView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var tracker = DeviceTracker.shared
    @State private var expanded: Set<String> = []

    /// Connected mice first, then profiles for mice that are not connected right now.
    private var rows: [HIDDeviceInfo] {
        let connectedKeys = Set(tracker.connected.map(\.key))
        let offline = store.config.deviceProfiles
            .filter { !connectedKeys.contains($0.id) }
            .map { HIDDeviceInfo(key: $0.id, name: $0.name) }
        return tracker.connected + offline
    }

    var body: some View {
        Form {
            // Re-read every 2 s so the warning clears once the grant lands (no relaunch needed).
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if !InputMonitoringPermission.isTrusted {
                    Section {
                        Label("Per-device settings need Input Monitoring to tell your mice apart. Until it is granted, every mouse uses the global Scroll settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Button("Grant Input Monitoring…") {
                            if !InputMonitoringPermission.request() { InputMonitoringPermission.openSettings() }
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text("No mouse detected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { device in
                Section {
                    deviceRow(device)
                }
            }
            Text("A mouse without custom settings uses the Scroll tab. Identical mice (same model) share one profile. After switching to a different mouse, its first scroll event may still use the previous mouse's settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { tracker.setTabOpen(true) } // lists connected mice even without a profile
        .onDisappear { tracker.setTabOpen(false) }
    }

    @ViewBuilder
    private func deviceRow(_ device: HIDDeviceInfo) -> some View {
        let connected = tracker.connected.contains { $0.key == device.key }
        let hasProfile = store.config.deviceProfiles.contains { $0.id == device.key }
        Toggle(isOn: Binding(
            get: { hasProfile },
            set: { on in setCustom(on, for: device) })) {
            VStack(alignment: .leading) {
                Text(device.name)
                Text(connected ? "Connected · \(device.key)" : "Not connected · \(device.key)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if hasProfile {
            DisclosureGroup("Custom settings", isExpanded: Binding(
                get: { expanded.contains(device.key) },
                set: { open in
                    if open { expanded.insert(device.key) } else { expanded.remove(device.key) }
                })) {
                ScrollSettingsEditor(settings: profileSettings(device.key))
            }
        }
    }

    /// Binding by profile ID, not array index: deleting the profile (its toggle sits right above)
    /// would leave an index binding pointing past the end while SwiftUI tears the editor down.
    private func profileSettings(_ key: String) -> Binding<ScrollDeviceSettings> {
        Binding(
            get: { store.config.deviceProfiles.first { $0.id == key }?.settings ?? store.config.scrollSettings },
            set: { newValue in
                guard let i = store.config.deviceProfiles.firstIndex(where: { $0.id == key }) else { return }
                store.config.deviceProfiles[i].settings = newValue
            })
    }

    private func setCustom(_ on: Bool, for device: HIDDeviceInfo) {
        if on {
            guard !store.config.deviceProfiles.contains(where: { $0.id == device.key }) else { return }
            store.config.deviceProfiles.append(
                DeviceProfile(id: device.key, name: device.name, settings: store.config.scrollSettings))
            expanded.insert(device.key)
        } else {
            store.config.deviceProfiles.removeAll { $0.id == device.key }
            expanded.remove(device.key)
        }
    }
}
