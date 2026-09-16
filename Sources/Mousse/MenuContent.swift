import SwiftUI

/// The dropdown shown from the menu-bar icon.
struct MenuContent: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Toggle("Enabled", isOn: $store.config.enabled)

        Divider()

        if !AccessibilityPermission.isTrusted {
            Button("⚠️ Grant Accessibility…") { AccessibilityPermission.openSettings() }
            Divider()
        }
        // Only a plain save failure is safe to retry blindly. A protected (unreadable) config
        // needs the explanation in Settings before the user overwrites the only copy.
        if case .saveFailed = store.persistenceIssue {
            Button("⚠️ Settings not saved — Retry") { store.retrySave() }
            Divider()
        } else if store.persistenceIssue != nil {
            SettingsLink { Text("⚠️ Settings issue — open Settings…") }
            Divider()
        }

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")

        Button("Quit Mousse") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
