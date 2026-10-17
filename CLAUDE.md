# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Listful** — a native macOS outliner-style task manager (Workflowy-like, no subscription), in Swift/SwiftUI. (Formerly TaskMgr; the repo directory is still `taskmgr`.) Requirements live in `spec/specification.md`.

## Commands

The machine has only the Command Line Tools (no Xcode), so everything goes through SwiftPM:

```sh
swift build                                   # build
scripts/test                                  # run all tests (Swift Testing)
scripts/test --filter OutlineTests            # one suite
scripts/test --filter "OutlineTests/outdentPlacesAfterParentSubtree"  # one test
swift run Listful                             # launch the app
.build/debug/Listful -libraryFolder /some/dir # launch against another task-list folder (NSArgumentDomain overrides the saved default)
```

Avoid smoke-launching the GUI unless needed, and tell the user first: the app activates itself on launch and **takes keyboard focus from their terminal**, so whatever they're typing goes to your test instance (stray Delete presses trashed scratch lists this way). The Bash tool runs zsh (not the user's tcsh), so `PID=$!` works. Stop the app by that PID, never `pkill -f Listful` — the user may have their own instance running, and a signal skips the save-on-quit. Smoke launches also share the user's real defaults domain (`defaults read Listful`): values passed as `-key value` aren't persisted, but the app writes `linkedFiles`/`selectedList` back during the run, so delete any scratch entries afterwards.

Use `scripts/test` rather than bare `swift test`: with only the CLT, SwiftPM intermittently can't find the Swift Testing macro plugin ("plugin for module 'TestingMacros' not found", often reported only as `error: fatalError`). The script passes `-plugin-path` explicitly. `--build-system native` is worse (can't find `Testing` at all).

## Toolchain constraints

- **Don't use `@State` (or other SwiftUI macros like `@Entry`/`@Previewable`).** In this SDK they're macros whose plugin ships only with Xcode, so they fail to build with the CLT. `@Observable` and `@Bindable` work. The app holds its `LibraryModel` as a plain `let` on the `App` struct.
- Deployment target is macOS 14; the SDK is newer, so watch for APIs that are SDK-newer than 14 (e.g. `UTType.markdown` is 27+).
- Settings live in the defaults domain named after the executable (`Listful`). `SettingsMigration` copies the old `TaskMgr` domain across once at startup.
- The app isn't a `.app` bundle, so there's no Info.plist or `.icns`: `AppDelegate` sets the Dock icon at launch from `Resources/AppIcon.png` via `Bundle.module` (a 1024px copy of `spec/icon.png`; regenerate with `sips -z 1024 1024 spec/icon.png --out Sources/Listful/Resources/AppIcon.png`).
- Inside `#expect(...)`, don't call mutating methods; assign to a local first.

## Architecture

Two targets: `ListfulCore` (pure model + persistence, fully unit-tested, no AppKit) and `Listful` (SwiftUI/AppKit app). Put logic that can be tested in Core.

**Outline model (`Outline.swift`).** The tree is stored as a *flat pre-order array* of `TaskItem`s with a `depth`, not as nested nodes. Invariant (enforced in `init`): first item depth 0, each depth ≤ previous + 1. A subtree is the contiguous run of following items with greater depth (`subtreeEnd`). All structural edits (indent, outdent, insert, move up/down, remove) are slice operations on that array and must preserve the invariant. This shape maps 1:1 to both the Markdown file and the visible row list.

Task states: `open`, `done` (struck through), `decrufted` (done + hidden, never deleted).

Headings (`headingLevel` 1–3) are items too, but not tasks: always depth 0, never done, never parents — the item after a heading is forced to depth 0, so tasks under a heading are top-level, matching Markdown. A heading instead owns a *section* (up to the next heading of same-or-higher level; `sectionEnd`), and collapsing it hides the section. `canCollapse` covers both kinds. Tasks can be moved across headings (changing section); headings can't be indented or moved by Move Up/Down. Edits that put an item inside a collapsed section expand it (`reveal`). Typing `# `/`## `/`### ` at the start of a task converts it (`TaskDocument.setTitle`); backspace in an empty heading turns it back into a task.

`Outline.title` is the list's own title — a `#` on the file's first content line — and is *not* an item. It's shown as a big editable field above the rows and used as the list's name in the sidebar and window (falling back to the file name). Consequence: if a list has no title and its first row is an H1 heading, that heading becomes the title on next load. Renaming a titled list in the sidebar updates the title as well as the file name. `visibleIndices(showDecrufted:)` computes what to display: descendants of collapsed items are hidden, and decrufted items hide along with their whole subtree unless shown.

**Persistence.** `TaskStore` protocol (`load`/`save`) is the backend seam — local Markdown (`MarkdownFileStore`) exists; git-backed Markdown and Apple Notes are planned as further conformances. `MarkdownCodec` defines the file format: optional `# Title` first line, `#`/`##`/`###` headings at column 0 (blank lines around them), `- [ ]`/`- [x]` tasks with two-space nesting; state the checkbox can't express goes in a trailing `<!-- listful: decrufted collapsed -->` comment. Decoding is lenient (tabs, `*`/`+` bullets, irregular indentation nested relative to ancestors, non-list lines kept as tasks) so hand-edited files survive. Files written before the rename use `<!-- taskmgr: … -->`; those are still read (`legacyMarkerPrefixes`) and rewritten as `listful:` on save. Canonical text must round-trip exactly — there's a test for it.

`TaskLibrary` treats a folder as a collection of lists: every non-hidden `.md` file is one list, named by its filename. It handles listing (Finder-style sort), create/rename (name validation, clash detection, case-only renames) and trashing. `contains`/`canonicalURL` decide whether an arbitrary file is really one of the folder's lists (comparing symlink-resolved paths). Its URLs are always rebuilt from `folderURL` so they compare equal across calls — the sidebar selection relies on `URL ==`.

**App.** Object graph: `ListfulApp` → `LibraryModel` → (optional) `TaskDocument`, plus a shared `ViewOptions` (show-decrufted).

- `LibraryModel` owns the folder (default `~/Documents/Task Lists`, changeable in Settings), the sidebar's `lists`, and `selection`. Setting `selection` saves the old document and creates a fresh `TaskDocument` for the new file. It watches the folder with a `DispatchSource` and refreshes on any change. Before renaming or trashing the open file it calls `closeDocument()` (save + drop) so a pending debounced save can't recreate the old path. It also saves the open document on quit. It also keeps `linkedFiles`: lists outside the folder, edited in place, persisted as paths (no sandbox, so no security-scoped bookmarks). They're re-checked for existence when the app becomes active (only the folder is watched); a missing one stays selected but its document is dropped *without* saving, so the file isn't recreated at its old path. Linked files can't be renamed or trashed from the app — Delete just removes them from the sidebar. Trashing a folder list always asks first (`pendingTrash`), with Cancel as the default button. Folder path and last-selected list persist in `UserDefaults`.
- `TaskDocument` owns one file's `Outline`, exposes id-based actions (rows reference tasks by `UUID`, never by index, since indices shift), and debounce-saves after every mutation. It only writes if something changed.
- Display prefs (tick / strikethrough) are `@AppStorage` keys in `DisplaySettings`; `@AppStorage` works with the CLT.

Keyboard editing goes through `TaskTextField`, an `NSViewRepresentable` around `NSTextField`, because SwiftUI's `TextField` can't intercept Tab/Shift-Tab before AppKit uses them for focus. It maps field-editor selectors (`insertNewline:`, `insertTab:`, `insertBacktab:`, `moveUp:`, `moveDown:`, `deleteBackward:` on empty) to `TaskFieldCommand`s. Focus uses two fields on `TaskDocument`: `focusRequestID` is a one-shot request — the matching field makes itself first responder and acknowledges via `didFocus`, which clears it (a persistent "should be focused" flag would steal focus back from the sidebar on every re-render). `focusedID` is the last-focused row, which menu commands target; clicking a field updates it via `becomeFirstResponder`. Structural moves re-request focus because SwiftUI may re-host the moved row's field. The row list uses a non-lazy `VStack` so every field exists to receive focus. Shortcuts that aren't text-editing commands (Cmd-Return done, Cmd-Up/Down collapse/expand, Cmd-Shift-Up/Down move, Cmd-Shift-D decruft) are menu commands in `ListfulApp` acting on the open document's `focusedID`. The sidebar itself is a standard `NavigationSplitView` (`SidebarCommands` gives the show/hide menu item).
