import SwiftUI

@main
struct ListfulApp: App {
    @State private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(library: library)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: library.becameActive()
            case .inactive, .background: library.resignedActive()
            @unknown default: break
            }
        }
    }
}

/// Asks for the folder of task lists the first time, then shows the lists
/// beside the open one (or, on iPhone, one after the other).
struct RootView: View {
    @Bindable var library: LibraryStore

    var body: some View {
        Group {
            if library.folderURL == nil {
                ChooseFolderView(library: library)
            } else {
                NavigationSplitView {
                    SidebarView(library: library)
                } detail: {
                    if let document = library.document {
                        OutlineScreen(document: document, library: library)
                            .id(ObjectIdentifier(document))
                    } else {
                        ContentUnavailableView(
                            "No Task List", systemImage: "checklist",
                            description: Text("Choose a task list."))
                    }
                }
            }
        }
        .fileImporter(isPresented: $library.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.choose(url) }
        }
        .alert(
            "Task lists",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }),
            presenting: library.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }
}

struct ChooseFolderView: View {
    let library: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Task Lists", systemImage: "folder")
        } description: {
            Text("Listful keeps each list as a Markdown file in a folder. Choose the folder your Mac uses: "
                + "usually iCloud Drive › Documents › Task Lists. You can make a new folder there too.")
        } actions: {
            Button("Choose Folder…") { library.isChoosingFolder = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
