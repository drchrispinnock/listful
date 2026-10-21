import SwiftUI

/// UserDefaults keys for display preferences, shared by `@AppStorage` users.
enum DisplaySettings {
    static let showTick = "showCompletionTick"
    static let showStrikethrough = "showCompletionStrikethrough"
}

struct SettingsView: View {
    let library: LibraryModel
    let updater: Updater
    @AppStorage(DisplaySettings.showTick) private var showTick = true
    @AppStorage(DisplaySettings.showStrikethrough) private var showStrikethrough = true

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
                LabeledContent("Folder") {
                    Text(library.folderURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
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
