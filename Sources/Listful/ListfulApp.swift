import AppKit
import SwiftUI

@main
struct ListfulApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    // Not @State: in this SDK @State is a macro whose plugin ships only with
    // Xcode, so it won't build with the Command Line Tools. The App value is
    // created once, so a plain stored property is equivalent.
    private let library: LibraryModel
    private let updater: Updater

    init() {
        SettingsMigration.run()
        library = LibraryModel()
        updater = Updater()
    }

    var body: some Scene {
        Window("Listful", id: "main") {
            ContentView(library: library)
                .frame(minWidth: 520, minHeight: 300)
        }
        .defaultSize(width: 820, height: 720)
        .commands { commands }

        Settings {
            SettingsView(library: library, updater: updater)
        }
    }

    @CommandsBuilder private var commands: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .appInfo) {
            Button("About Listful") { AboutPanel.show() }
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Task List…") { library.promptNewList() }
                .keyboardShortcut("n")
            Button("Add Existing File…") { library.addExistingFiles() }
                .keyboardShortcut("o")
            Button("Reload from Disk") { library.document?.reload() }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { library.document?.saveNow() }
                .keyboardShortcut("s")
        }
        CommandMenu("Task") {
            Button("Toggle Done") { onFocused { $0.toggleDone($1) } }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Collapse") { onFocused { $0.setCollapsed(true, for: $1) } }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Expand") { onFocused { $0.setCollapsed(false, for: $1) } }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Indent") { onFocused { $0.indent($1) } }
            Button("Outdent") { onFocused { $0.outdent($1) } }
            Button("Move Up") { onFocused { $0.moveUp($1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Button("Move Down") { onFocused { $0.moveDown($1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            Divider()
            Button("Heading 1") { onFocused { $0.makeHeading(1, for: $1) } }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { onFocused { $0.makeHeading(2, for: $1) } }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { onFocused { $0.makeHeading(3, for: $1) } }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Task") { onFocused { $0.makeTask($1) } }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandGroup(before: .sidebar) {
            Button("Decruft Done Tasks") { library.document?.decruft() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(library.document == nil)
            Toggle("Show Decrufted Tasks", isOn: Bindable(library.options).showDecrufted)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
        }
    }

    /// Runs a menu action on the open list's current task, if there is one.
    private func onFocused(_ action: (TaskDocument, UUID) -> Void) {
        if let document = library.document, let id = document.focusedID { action(document, id) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable there's no Info.plist, so
        // opt in to being a regular Dock app that can take keyboard focus.
        NSApp.setActivationPolicy(.regular)
        // Only after that: switching the policy creates the Dock tile with
        // the default icon, replacing any icon set earlier.
        setDockIconIfUnbundled()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Run as a bare executable (`swift run`) there's no bundle icon, so set
    /// the Dock icon at runtime. A packaged Listful.app gets it from
    /// Info.plist instead and doesn't ship SwiftPM's resource bundle, where
    /// touching `Bundle.module` would crash, so only do this when unbundled.
    /// Source artwork: spec/icon.png (scaled to 1024px for the resource).
    @MainActor private func setDockIconIfUnbundled() {
        guard Bundle.main.bundleIdentifier == nil else { return }
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
