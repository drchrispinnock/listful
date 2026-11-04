# Changelog

Each release's section is used as its release notes: on the GitHub release
page and in the app's update window. `scripts/release` refuses to build a
version that has no section here.

## Unreleased

- **Repeating checklists.** File ▸ New Repeating Checklist… (Cmd-Shift-N)
  makes a template: name it, choose how often it repeats, then fill in its
  tasks. It can repeat every day, every weekday, weekly on the days you
  pick, monthly on a given day (or the last day), quarterly, or yearly on a
  date. Templates are listed under Repeating in the sidebar, and a bar at
  the top of each one shows its schedule, with Edit… to change it.
- **A fresh copy each time it's due.** When a new period starts, Listful
  copies the template into a new list named with the date, such as
  "Morning Routine 2026-11-03", titled "Morning Routine — Tue 3 Nov". It
  checks when it opens, when you switch back to it, at midnight and when
  the Mac wakes. If it hasn't run for a while, it makes only the current
  period's copy, not one for every day you missed. Earlier copies stay in
  the sidebar as they were.
- **Carry over unfinished tasks.** Turn this on for a template, and each new
  copy starts with the open tasks left in the previous copy. They're moved,
  not duplicated, so yesterday's list ends up showing what you did. Done
  subtasks travel with their unfinished parent. A task the template already
  has isn't added twice, and tasks under a heading stay under that heading.
  If you were looking at the previous copy, Listful switches to the new
  one.
- **Copies grouped under their template.** In the sidebar, each repeating
  checklist's copies are listed beneath it by date. The newest is always
  shown, and so is any older copy that still has tasks left. Older copies
  with everything ticked are folded into "Earlier". Copies no longer appear
  among your other lists.
- Templates are ordinary Markdown files in a Templates folder inside your
  task-list folder, so they sync with iCloud like your lists. The schedule
  is a hidden comment under the title.

## 0.2.2 — 2026-11-02

- **No more spinning beachball when switching back to Listful.** Coming
  back to the app could freeze it for a second or more while it re-read
  your lists to refresh their names in the sidebar, especially for lists
  kept in iCloud Drive while it was syncing them. Those reads now happen in
  the background, so the window stays responsive and the sidebar names
  update a moment later. Checking whether the open list was changed on
  another Mac or in another app works the same way.

## 0.2.1 — 2026-10-29

- **Drag tasks to move them.** Press on a task's dot and drag it up or down
  to move it, along with any tasks nested under it. A line shows where it
  will land; drag left or right to change how deeply it's nested there.
  Dropping it inside a collapsed task or heading opens it up so the task
  stays in view. A click on the dot without dragging still marks the task
  done.
- **The task you're editing stays in view.** In a long list, pressing Return
  at the bottom of the window, arrowing down past its edge, or typing until
  a task wraps onto another line now scrolls the list just enough to keep
  that task visible. Before, the cursor could disappear below the window.
- **App icon fixed on macOS 26 and later.** The icon was being shown shrunk
  inside a grey square in the Dock and Finder. It now fills its space like
  other apps' icons.

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
