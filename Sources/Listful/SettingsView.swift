import ListfulCore
import SwiftUI

/// UserDefaults keys for preferences, shared by `@AppStorage` users.
enum DisplaySettings {
    static let showTick = "showCompletionTick"
    static let showStrikethrough = "showCompletionStrikethrough"
}

struct SettingsView: View {
    let library: LibraryModel
    let updater: Updater
    @AppStorage(DisplaySettings.showTick) private var showTick = true
    @AppStorage(DisplaySettings.showStrikethrough) private var showStrikethrough = true

    private var makerExplanation: String {
        guard let maker = library.maker else { return "Waiting for this setting to download from iCloud…" }
        switch maker.device {
        case nil:
            return "Each device makes the next copy when it's due. If two make the same one while out of touch, "
                + "the two versions are merged task by task when they sync."
        case library.thisDevice:
            return "Only this Mac makes the copies. Your other devices show each one once it has synced, "
                + "so they wait for this Mac to be on and online."
        case let other?:
            return "Only “\(other.name)” makes the copies; this Mac shows each one once it has synced. "
                + "Choose This Mac to make them here instead."
        }
    }

    var body: some View {
        Form {
            Section {
                // At least one stays on so done tasks always look different.
                Toggle("Tick", isOn: $showTick)
                    .disabled(showTick && !showStrikethrough)
                Toggle("Strikethrough", isOn: $showStrikethrough)
                    .disabled(showStrikethrough && !showTick)
            } header: {
                Text("Show completion")
            }

            Section {
                Picker("Made on", selection: Binding(
                    get: { library.maker?.device },
                    set: { library.setMaker($0) }
                )) {
                    Text("Any device").tag(RepeatingDevice?.none)
                    Text("This Mac (\(library.thisDevice.name))").tag(Optional(library.thisDevice))
                    if let other = library.maker?.device, other != library.thisDevice {
                        Text(other.name).tag(Optional(other))
                    }
                }
                .disabled(library.maker == nil)
                Text(makerExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Repeating checklists")
            }

            Section {
                LabeledContent("Folder") {
                    Text(library.isUsingICloudFolder ? "iCloud Drive › Listful" : library.folderURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    if library.canMoveToICloud {
                        Button("Move to iCloud Drive…") { library.offerMoveToICloud() }
                    }
                    Button("Show in Finder") { library.revealInFinder() }
                    Button("Choose…") { library.chooseFolder() }
                }
            } header: {
                Text("Task lists")
            }

            if updater.isAvailable {
                Section {
                    Toggle("Automatically check for updates", isOn: Bindable(updater).automaticallyChecks)
                } header: {
                    Text("Updates")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
