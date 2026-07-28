import KeyboardShortcuts
import SwiftUI

struct ShelfSettingsSection: View {
    @ObservedObject var state: AppState
    let shelf: ShelfService?

    @AppStorage(UserDefaultsKeys.shelfEnabled) private var enabled = false

    var body: some View {
        Section(state.l10n.s.featureHubNameShelf) {
            Toggle(state.l10n.s.shelfEnable, isOn: $enabled)
                .onChange(of: enabled) { _, _ in
                    shelf?.syncWithPreferences()
                }
            Text(state.l10n.s.shelfEnableCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(state.l10n.s.shelfNoPermission, systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let shelf {
            ShelfRegisteredSettingsSection(state: state, shelf: shelf)
                .disabled(!enabled)
        }
    }
}

private struct ShelfRegisteredSettingsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var shelf: ShelfService

    @AppStorage(UserDefaultsKeys.shelfShortcutEnabled) private var shortcutEnabled = true
    @AppStorage(UserDefaultsKeys.shelfShakeToOpen) private var shake = true
    @AppStorage(UserDefaultsKeys.shelfDropZoneEnabled) private var dropZone = true
    @AppStorage(UserDefaultsKeys.shelfCloseAfterDrop) private var closeAfterDrop = false
    @AppStorage(UserDefaultsKeys.shelfRemoveAfterDrop) private var removeAfterDrop = true

    @State private var showingAppPicker = false

    private var strings: Strings { state.l10n.s }

    var body: some View {
        Section {
            Toggle(strings.shelfShortcutToggle, isOn: $shortcutEnabled)
                .onChange(of: shortcutEnabled) { _, _ in shelf.syncHotkey() }

            HStack {
                Text(strings.shelfHotkeyLabel)
                Spacer()
                HotkeyRecorderView(
                    displayText: shelf.hotkey.displayString,
                    onShortcutChanged: shelf.handleRecorderChange,
                    l10n: state.l10n
                )
            }
            .disabled(!shortcutEnabled)

            VStack(alignment: .leading, spacing: 3) {
                Toggle(strings.shelfShakeToggle, isOn: $shake)
                    .onChange(of: shake) { _, _ in shelf.syncDragMonitor() }
                Text(strings.shelfShakeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Toggle(strings.shelfDropZoneToggle, isOn: $dropZone)
                    .onChange(of: dropZone) { _, _ in shelf.syncDragMonitor() }
                Text(strings.shelfDropZoneCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                shelf.summon()
            } label: {
                Label(strings.shelfOpenNow, systemImage: "tray.and.arrow.down")
            }
        }

        Section(strings.shelfBehaviorTitle) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(strings.shelfCloseAfterDrop, isOn: $closeAfterDrop)
                Text(strings.shelfCloseAfterDropCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle(strings.shelfRemoveAfterDrop, isOn: $removeAfterDrop)
                Text(strings.shelfRemoveAfterDropCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section(strings.shelfExclusionsTitle) {
            if sortedExclusions.isEmpty {
                Text(strings.shelfExclusionsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedExclusions, id: \.self) { bundleID in
                    HStack(spacing: 9) {
                        Image(nsImage: InstalledApps.icon(for: bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(InstalledApps.name(for: bundleID))
                        Spacer()
                        Button {
                            shelf.removeAutomaticExclusion(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                showingAppPicker = true
            } label: {
                Label(strings.shelfAddApp, systemImage: "plus")
            }

            Text(strings.shelfExclusionsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingAppPicker) { appPickerSheet }
    }

    private var sortedExclusions: [String] {
        shelf.automaticExclusions.sorted {
            InstalledApps.name(for: $0)
                .localizedCaseInsensitiveCompare(InstalledApps.name(for: $1)) == .orderedAscending
        }
    }

    private var appPickerSheet: some View {
        let excluded = Set(shelf.automaticExclusions)
        return ShelfAppPickerView(
            strings: strings,
            loadApps: { InstalledApps.installedBundleApplications(excluding: excluded) },
            onCancel: { showingAppPicker = false },
            onSelect: { url in
                showingAppPicker = false
                guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
                shelf.addAutomaticExclusion(bundleID)
            }
        )
    }
}
