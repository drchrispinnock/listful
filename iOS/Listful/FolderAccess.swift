import Foundation

/// Remembers the folder of task lists the user picked, across launches.
/// An iOS app can only reach a folder outside its own container (such as
/// iCloud Drive › Documents › Task Lists) once the user has chosen it, and
/// keeps that access with a bookmark.
enum FolderAccess {
    private static let bookmarkKey = "folderBookmark"

    /// The saved folder, with access to it started; nil if none was chosen
    /// or it can't be found any more.
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }
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
}
