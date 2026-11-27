import Foundation

/// A device that can make repeating checklists' copies.
public struct RepeatingDevice: Codable, Equatable, Hashable, Sendable {
    /// Made up on each device and kept in its own settings.
    public var id: String
    /// Shown in Settings on the other devices.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which device makes repeating checklists' copies, kept in the templates
/// folder so every device sharing it sees the same choice.
public struct MakerSetting: Codable, Equatable, Sendable {
    /// nil: any device makes them when they're due.
    public var device: RepeatingDevice?

    public init(device: RepeatingDevice? = nil) {
        self.device = device
    }
}

/// Each repeating copy as this device made it, by name. Kept in this
/// device's own settings, not in iCloud: when two devices make the same
/// copy while out of touch, it's what this device's version started from,
/// which lets `mergeVersions` tell a change from a difference.
public struct MadeCopies: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var text: String
        public var made: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    /// The most kept; older ones are no longer needed.
    public static let limit = 40

    public init() {}

    public mutating func record(_ text: String, name: String, made: Date) {
        entries[name] = Entry(text: text, made: made)
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.made > $1.value.made }.dropFirst(Self.limit).map(\.key)
            for name in oldest { entries[name] = nil }
        }
    }

    /// The texts by name, as the merges take them.
    public var texts: [String: String] { entries.mapValues(\.text) }

    public static let defaultsKey = "madeRepeatingCopies"

    public static func load(from defaults: UserDefaults = .standard) -> MadeCopies {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MadeCopies.self, from: $0) } ?? MadeCopies()
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension RepeatingDevice {
    /// This device's ID, made the first time it's asked for.
    public static func localID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return id
    }
}

extension RepeatingChecklists {
    /// The file holding the `MakerSetting`, hidden in the templates folder.
    public static func makerURL(in templates: TaskLibrary) -> URL {
        templates.folderURL.appending(path: ".listful-maker.json")
    }

    /// Which device makes the copies. Throws `notDownloaded` while the
    /// setting is still only in iCloud.
    public static func maker(in templates: TaskLibrary) throws -> MakerSetting {
        guard let text = try MarkdownFileStore(fileURL: makerURL(in: templates)).readText() else { return MakerSetting() }
        return (try? JSONDecoder().decode(MakerSetting.self, from: Data(text.utf8))) ?? MakerSetting()
    }

    public static func setMaker(_ setting: MakerSetting, in templates: TaskLibrary) throws {
        let url = makerURL(in: templates)
        guard setting.device != nil else {
            if FileManager.default.fileExists(atPath: url.path) {
                var result: Swift.Result<Void, Error> = .success(())
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
                    result = Swift.Result { try FileManager.default.removeItem(at: url) }
                }
                if let coordinationError { throw coordinationError }
                try result.get()
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = String(decoding: try encoder.encode(setting), as: UTF8.self) + "\n"
        try MarkdownFileStore(fileURL: url).writeText(text)
    }

    /// What `resolveConflicts` did.
    public struct ConflictResolution: Sendable, Equatable {
        /// Copies whose versions were merged into one.
        public var merged: [URL] = []
        /// Versions of other lists, saved beside them since they can't be
        /// merged safely; each is (list, copy).
        public var copies: [ConflictCopy] = []

        public init() {}

        public var isEmpty: Bool { merged.isEmpty && copies.isEmpty }
    }

    public struct ConflictCopy: Sendable, Equatable {
        public let list: URL
        public let copy: URL
    }

    /// Deals with lists that iCloud has kept more than one version of,
    /// because they were changed on two devices that were out of touch.
    /// iCloud shows one and hides the rest; left alone, what only the hidden
    /// ones have is lost.
    ///
    /// The current period's copy of each template is merged task by task
    /// (`mergeVersions`, with this device's `bases`). Other lists, including
    /// earlier copies (whose unfinished tasks have already moved on), get
    /// each hidden version saved beside them as a conflict copy instead,
    /// unless it matches the list. Either way the versions are then marked
    /// resolved.
    public static func resolveConflicts(
        templates: TaskLibrary, lists: TaskLibrary, date: Date, calendar: Calendar,
        bases: [String: String] = [:]
    ) -> ConflictResolution {
        var resolution = ConflictResolution()
        let urls = ((try? lists.lists()) ?? []) + ((try? templates.lists()) ?? [])
        let conflicted = urls.compactMap { url -> (URL, [NSFileVersion])? in
            guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return nil }
            return (url, versions)
        }
        guard !conflicted.isEmpty else { return resolution }

        // The current period's copy of each template, with the template.
        var current: [String: Outline] = [:]
        for url in (try? templates.lists()) ?? [] {
            guard let template = try? MarkdownFileStore(fileURL: url).load(), let schedule = template.schedule else { continue }
            let key = schedule.periodKey(for: schedule.occurrence(onOrBefore: date, calendar: calendar), calendar: calendar)
            current[copyName(template: TaskLibrary.displayName(of: url), key: key)] = template
        }

        for (url, versions) in conflicted {
            let store = MarkdownFileStore(fileURL: url)
            guard let text = try? store.readText() else { continue }
            let others = versions.compactMap { version in
                (try? String(contentsOf: version.url, encoding: .utf8)).map { (version, $0) }
            }
            // A version that can't be read yet isn't marked resolved, so it isn't lost.
            guard others.count == versions.count else { continue }
            let name = TaskLibrary.displayName(of: url)
            do {
                if let template = current[name] {
                    let base = bases[name].map(MarkdownCodec.decode)
                    var merged = MarkdownCodec.decode(text)
                    for (_, other) in others {
                        merged = mergeVersions(merged, MarkdownCodec.decode(other), base: base, template: template)
                    }
                    let mergedText = MarkdownCodec.encode(merged)
                    if mergedText != text { try store.writeText(mergedText) }
                    resolution.merged.append(url)
                } else {
                    for (version, other) in others where other != text {
                        let copy = TaskLibrary.conflictCopyURL(for: url, date: version.modificationDate ?? date)
                        try MarkdownFileStore(fileURL: copy).writeText(other)
                        resolution.copies.append(ConflictCopy(list: url, copy: copy))
                    }
                }
            } catch {
                continue
            }
            markResolved(versions, of: url)
        }
        return resolution
    }

    private static func markResolved(_ versions: [NSFileVersion], of url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }
}

extension RepeatingChecklists {
    /// What `syncCopies` did.
    public struct SyncResult: Sendable {
        public var made: [Result] = []
        /// Duplicates (`… 2`) merged into their originals and trashed.
        public var trashed: [URL] = []
        public var conflicts = ConflictResolution()
        /// nil while it's still only in iCloud.
        public var maker: MakerSetting?

        public init() {}

        public var changedLists: Bool { !made.isEmpty || !trashed.isEmpty || !conflicts.isEmpty }
    }

    /// Everything the apps do to keep repeating copies in order, off the
    /// main thread: make the copies that are due (if this device makes
    /// them), resolve versions iCloud kept from two devices, and fold
    /// `… 2` duplicates into their originals. `keeping` is the open list,
    /// which isn't trashed; `bases` are this device's `MadeCopies` texts.
    public static func syncCopies(
        templates: TaskLibrary, lists: TaskLibrary, keeping: URL?, bases: [String: String], deviceID: String,
        date: Date, calendar: Calendar, locale: Locale
    ) -> SyncResult {
        var result = SyncResult()
        result.maker = try? maker(in: templates)
        result.made = makeDueCopies(
            templates: templates, lists: lists, date: date, calendar: calendar, locale: locale, deviceID: deviceID)
        var bases = bases
        for made in result.made {
            if let copy = made.copy, let text = made.madeText { bases[TaskLibrary.displayName(of: copy)] = text }
        }
        result.conflicts = resolveConflicts(templates: templates, lists: lists, date: date, calendar: calendar, bases: bases)
        result.trashed = mergeDuplicates(templates: templates, lists: lists, keeping: keeping, bases: bases)
        return result
    }

    /// For a repeating checklist's copy, how a save that clashes with
    /// another device's version is settled: merged task by task with
    /// `base` (this device's `MadeCopies` text) and the template, read when
    /// it's needed. nil for any other list, which keeps the usual conflict copy.
    public static func clashMerge(
        for url: URL, templates: TaskLibrary, lists: TaskLibrary, base: String?
    ) -> (@Sendable (String, String) -> String)? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == lists.folderURL.standardizedFileURL.path,
              let templateURL = ((try? templates.lists()) ?? []).first(where: {
                  copyKey(of: url, template: TaskLibrary.displayName(of: $0)) != nil
              })
        else { return nil }
        return { mine, theirs in
            let template = try? MarkdownFileStore(fileURL: templateURL).load()
            return MarkdownCodec.encode(mergeVersions(
                MarkdownCodec.decode(mine), MarkdownCodec.decode(theirs),
                base: base.map(MarkdownCodec.decode), template: template, aIsMine: true))
        }
    }
}
