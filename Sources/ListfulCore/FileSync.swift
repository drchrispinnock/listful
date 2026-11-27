import Foundation

/// What saving a list did (see `FileSync.save`).
public enum SaveOutcome: Equatable, Sendable {
    /// Written; this text is now in the file.
    case saved(String)
    /// Merged with changes made elsewhere: this is now the file's text, and
    /// the list should show it.
    case merged(String)
    /// Changes made elsewhere clash with these. The file keeps the other
    /// version, `disk`, which the list should show; these were written to `copy`.
    case conflict(disk: String, copy: URL)
    /// The file has gone (renamed or trashed, perhaps on another device) and
    /// isn't recreated. Unsaved edits, if there were any, went to `copy`.
    case gone(copy: URL?)
}

/// Saving a list that may also be edited elsewhere: by another app, or on
/// another device through iCloud. Shared by the Mac and iOS apps.
public enum FileSync {
    /// Saves `mine`, the list's text, given `synced`, the file's text as last
    /// read or written here (nil if it has never been). If the file has
    /// changed since, the two versions are merged line by line; if they
    /// clash, the other version wins and `mine` is kept beside it as a copy.
    /// A file that was there and has gone is never recreated.
    ///
    /// With `clashMerge`, a clash is settled by it instead, given this
    /// version and the other: repeating checklists' copies merge task by
    /// task (`RepeatingChecklists.mergeVersions`).
    public static func save(
        _ mine: String, to store: MarkdownFileStore, synced: String?,
        clashMerge: ((_ mine: String, _ theirs: String) -> String)? = nil, date: Date = Date()
    ) throws -> SaveOutcome {
        guard let disk = try store.readText() else {
            guard let synced else {
                try store.writeText(mine)
                return .saved(mine)
            }
            // Writing it would bring it back under its old name.
            guard mine != synced else { return .gone(copy: nil) }
            return .gone(copy: try writeCopy(mine, beside: store.fileURL, date: date))
        }
        guard disk != synced else {
            try store.writeText(mine)
            return .saved(mine)
        }
        switch TextMerge.merge(base: synced ?? "", mine: mine, theirs: disk) {
        case .merged(let text):
            if text != disk { try store.writeText(text) }
            return .merged(text)
        case .conflict:
            if let clashMerge {
                let text = clashMerge(mine, disk)
                if text != disk { try store.writeText(text) }
                return .merged(text)
            }
            return .conflict(disk: disk, copy: try writeCopy(mine, beside: store.fileURL, date: date))
        }
    }

    private static func writeCopy(_ text: String, beside url: URL, date: Date) throws -> URL {
        let copy = TaskLibrary.conflictCopyURL(for: url, date: date)
        try MarkdownFileStore(fileURL: copy).writeText(text)
        return copy
    }
}
