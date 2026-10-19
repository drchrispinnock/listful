import AppKit

/// The About panel, filled in explicitly so it looks the same whether
/// Listful runs as the packaged app or as a bare `swift run` executable.
@MainActor enum AboutPanel {
    static let copyright = "© 2026 Chris Pinnock"

    static func show() {
        let (version, build) = versionAndBuild()
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSAttributedString(
            string: "An outliner for task lists, kept as Markdown files.\nCode by Claude. Icon by ChatGPT.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred,
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Listful",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ]
        // AppDelegate sets this from the bundled icon, or the PNG under `swift run`.
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// From Info.plist in the packaged app (filled in by scripts/release).
    /// Under `swift run` there's no Info.plist, so read the repo's VERSION
    /// file next to the sources this was built from.
    private static func versionAndBuild() -> (String, String) {
        let info = Bundle.main.infoDictionary ?? [:]
        if let version = info["CFBundleShortVersionString"] as? String {
            return (version, info["CFBundleVersion"] as? String ?? "")
        }
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Listful
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appending(path: "VERSION")
        let version = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (version ?? "?", "development")
    }
}
