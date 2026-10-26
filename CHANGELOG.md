# Changelog

Each release's section is used as its release notes: on the GitHub release
page and in the app's update window. `scripts/release` refuses to build a
version that has no section here.

## Unreleased

- **Drag tasks to move them.** Press on a task's dot and drag it up or down
  to move it, along with any tasks nested under it. A line shows where it
  will land; drag left or right to change how deeply it's nested there.
  Dropping it inside a collapsed task or heading opens it up so the task
  stays in view. A click on the dot without dragging still marks the task
  done.

## 0.2 — 2026-10-21

- **Check for Updates.** Listful ▸ Check for Updates… looks for a newer
  version and offers to download and install it. Updates are signed and
  verified before they're installed.
- **Automatic update checks.** On its second launch Listful asks whether to
  check for updates automatically. You can change this any time in
  Settings ▸ Updates.
- Release notes like these are now shown in the update window, so you can
  see what's changed before installing.

Coming from 0.1? That version can't update itself, so download this one from
the release page once. Later versions will install from within the app.

## 0.1 — 2026-10-20

First release.

- **Outliner task lists.** Each line is a task; nest tasks with Tab and
  Shift-Tab, and collapse or expand a task's children with Cmd-Up and
  Cmd-Down. Move tasks with Cmd-Shift-Up and Cmd-Shift-Down.
- **Return** adds a task below. In the middle of a task it splits the text at
  the cursor; at the very start it adds an empty task above. Return on an
  empty nested task steps it back out a level, as in other outliners.
- **Done and decrufted.** Cmd-Return marks a task done (ticked, struck
  through, or both — choose in Settings). View ▸ Decruft Done Tasks
  (Cmd-Shift-D) tidies done tasks away without deleting them; View ▸ Show
  Decrufted Tasks (Cmd-Shift-H) brings them back.
- **Headings.** Type `# `, `## ` or `### ` at the start of a task, or use
  Task ▸ Heading 1–3 (Cmd-Option-1–3), to make a heading. Collapsing a
  heading hides its section. A `#` title on a file's first line is shown as
  the list's title.
- **Plain Markdown files.** Every list is an ordinary `.md` task list you can
  open in any editor. Hand-edited files with tabs, `*` or `+` bullets or
  uneven indentation are read sensibly.
- **Sidebar of lists.** Lists live in one folder (default
  `~/Documents/Task Lists`, changeable in Settings), plus any Markdown files
  elsewhere you add with File ▸ Add Existing File… (Cmd-O). Create, rename and
  move lists to the Trash from the sidebar.
- **Edits from elsewhere.** If a list changes in another app or on another
  Mac (e.g. via iCloud), Listful reloads it. If you've both changed it, the
  two versions are merged; when they clash, your version is saved beside the
  file as "Name (conflict <date>).md" and Listful tells you.
- Saves automatically as you type.
- Universal app for Apple silicon and Intel Macs, macOS 14 or later, signed
  and notarized by Apple.
