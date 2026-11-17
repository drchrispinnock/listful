import SwiftUI

/// UserDefaults keys for preferences, shared by `@AppStorage` users.
enum DisplaySettings {
    static let showTick = "showCompletionTick"
    static let showStrikethrough = "showCompletionStrikethrough"
    /// Decruft deletes done tasks instead of hiding them.
    static let deleteDecrufted = "deleteDecruftedTasks"
}

struct SettingsView: View {
    let library: LibraryModel
    let updater: Updater
    @AppStorage(DisplaySettings.showTick) private var showTick = true
    @AppStorage(DisplaySettings.showStrikethrough) private var showStrikethrough = true
    @AppStorage(DisplaySettings.deleteDecrufted) private var deleteDecrufted = false

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
                Toggle(isOn: $deleteDecrufted) {
                    Text("Delete decrufted tasks")
                    Text("Decruft Done Tasks deletes done tasks from the list instead of hiding them. Open tasks nested under them are kept.")
                }
            } header: {
                Text("Decruft")
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
