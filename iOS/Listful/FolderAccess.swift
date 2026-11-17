import Foundation

/// Where the task lists are. By default that's the app's own folder in
/// iCloud Drive (iCloud Drive › Listful: the container
/// `iCloud.com.chrispinnock.listful`, public, so it shows in Files and
/// Finder; on a Mac it's `~/Library/Mobile Documents/iCloud~com~chrispinnock~listful/Documents`).
/// The user can choose another folder instead (Dropbox, say); an iOS app
/// can only reach that once it's been chosen, and keeps access with a
/// bookmark.
enum FolderAccess {
    static let containerID = "iCloud.com.chrispinnock.listful"
    private static let bookmarkKey = "folderBookmark"

    /// The app's iCloud Drive folder, created if need be; nil if iCloud
    /// Drive is off or the user isn't signed in. Slow the first time, so
    /// call it off the main thread.
    nonisolated static func iCloudFolder() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let folder = container.appending(path: "Documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The folder the user chose, with access to it started; nil if none
    /// was chosen or it can't be found any more.
    static func restoreChosen() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        // A folder that's gone, or gone to the Trash (as Task Lists does when
        // the Mac moves the lists to iCloud Drive › Listful), is forgotten.
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
              !url.path.contains("/.Trash"), FileManager.default.fileExists(atPath: url.path)
        else {
            forgetChosen()
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if isStale { save(url) }
        return url
    }

    /// Remembers a folder the user has just picked. Access to it must
    /// already have been started.
    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Forgets the chosen folder, going back to iCloud Drive › Listful.
    static func forgetChosen() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static var hasChosenFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }
}
