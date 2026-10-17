import Foundation

/// Settings live in a defaults domain that depends on how the app is run:
/// the executable name when unbundled (`TaskMgr` before the rename, then
/// `Listful`), or the bundle identifier for a packaged Listful.app. Copies
/// settings (lists folder, linked files, display options, window sizes)
/// forward from earlier domains so none are lost. Each domain is migrated
/// once; existing values are never overwritten, and newer domains win.
enum SettingsMigration {
    /// Newest first.
    private static let previousDomains = ["Listful", "TaskMgr"]
    /// Keys the old app no longer used.
    private static let obsoleteKeys: Set<String> = ["fileURL"]

    static func run(defaults: UserDefaults = .standard) {
        let current = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        for domain in previousDomains where domain != current {
            let doneKey = "migratedSettingsFrom\(domain)"
            guard !defaults.bool(forKey: doneKey) else { continue }
            defer { defaults.set(true, forKey: doneKey) }
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old
            where !obsoleteKeys.contains(key) && !key.hasPrefix("migratedSettingsFrom") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
