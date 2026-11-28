# Changelog

Each release's section is used as its release notes: on the GitHub release
page and in the app's update window. `scripts/release` refuses to build a
version that has no section here.

## 0.8.1 — 2026-11-28

- **Choose the device that makes each repeating checklist.** 0.8's “Made
  on” setting applied to every repeating checklist at once. It's now set
  for each checklist separately, so a daily list can be made only on your
  home Mac while a weekend one is made wherever you are. On the Mac it's
  in the checklist's schedule (Edit… on the template); on iPhone and iPad
  it's Made On in an open template's menu. The template's bar says which
  device makes it. Any device remains the default, with versions made on
  two devices merged as in 0.8.
- The setting has gone from Settings.

## 0.8 — 2026-11-27

- **Repeating checklists made on two devices at once now merge.** If two
  Macs (or a Mac and an iPhone) are out of touch when a new day's
  checklist is due, say one on a train without a connection, each makes
  its own copy and you tick things off in both. When they sync, the two
  versions used to clash: one was saved as a separate “(conflict …)”
  list, or iCloud quietly kept only one of them, losing what you'd done
  in the other. Now they're merged task by task:
  - A task ticked on either device is ticked.
  - Tasks added on either device are kept, in the place you added them.
  - A task moved on one device (to another day or heading) is moved,
    not doubled.
  - A routine task from the template that you decrufted on one device
    stays gone.
  - A carried-over task that one device doesn't have is kept, in case
    that device never had it.
- **Or let one device make them.** Settings › Repeating checklists ›
  Made on chooses Any device (the default, with the merging above) or
  just this one. With one device chosen, the others never make copies;
  they show each one once it has synced from that device, so that device
  needs to be on and online first. The choice is shared by all your
  devices.
- **No more silently lost versions of other lists.** When iCloud kept
  only one version of any other list changed on two devices at once, the
  other is now saved beside it as a “(conflict …)” list, and Listful
  says so.
- The same applies in the iPhone and iPad app.

## 0.7.1 — 2026-11-27

- **Decruft now always deletes done tasks.** Decruft Done Tasks
  (Cmd-Shift-D) used to hide done tasks by default, leaving them in the
  list file, and deleting them was an option in Settings. Hidden tasks
  got in the way, so Decruft now always deletes them, and the setting is
  gone. Any open subtasks under a done task are kept and move up into
  its place.
- Tasks hidden by an earlier Decruft are deleted too the next time you
  decruft. Until then, View ▸ Show Decrufted Tasks still shows them.
- The same applies in the iPhone and iPad app.

## 0.7 — 2026-11-19

- **Only tasks are tasks.** Text in a list file that isn't a task or a
  heading (paragraphs, notes under a task, numbered lines) used to be
  turned into tasks. Now it's shown as it is, in grey under the task or
  heading it follows, and left alone: it can't be edited in Listful, but
  it stays in the file exactly as written and moves with its task.
- **`{…}` attribute blocks are hidden everywhere.** Blocks like `{#id}` or
  `{.class}` at the end of a task were shown as part of its text, and a
  line holding nothing but one (`- [ ] {#id: …}`) showed as an empty
  task. Both are now hidden, as they already were on headings, and kept
  in the file.
- Pasting plain lines still makes a task of each.
- The same applies in the iPhone and iPad app.

## 0.6 — 2026-11-17

- **Your task lists move to iCloud Drive › Listful.** Listful now has a
  folder of its own in iCloud Drive, shown in Finder as **iCloud Drive ›
  Listful** with the app's icon. The coming iPhone and iPad app uses the
  same folder, so your lists are there on every device without choosing
  anything, and it no longer relies on Desktop & Documents syncing being
  on.
  - The folder appears on your Macs once the iPhone or iPad app has been
    opened on your Apple Account. Until then nothing changes.
  - Then, if your lists are in the old place, `Documents › Task Lists`,
    Listful offers to move them: **Move Lists**, **Not Now** (it asks
    again next time) or **Keep Using “Task Lists”**. Everything moves:
    lists, folders and repeating checklists, including files iCloud
    hasn't downloaded to this Mac. The empty Task Lists folder goes to the
    Trash afterwards.
  - Move them on one Mac only. Your other Macs see the lists have gone
    and switch to the new folder by themselves, as long as they have
    Listful 0.6. Update every Mac **before** moving, because an older
    Listful would keep using the old folder.
  - If iCloud Drive › Listful already has a list with the same name and
    different contents, yours is kept beside it as “Name 2” and Listful
    tells you. Identical copies are merged.
  - A folder you chose yourself in Settings stays as it is. To move it,
    use **Settings › Move to iCloud Drive…**.

## 0.5 — 2026-11-14

- **Folders in the sidebar.**
  - **Subfolders** of your Task Lists folder now appear in the sidebar as
    folders you can open and close, each with its lists. Make one with
    **File › New Folder…** (or the + button), and right-click a folder to
    add a list to it, rename it, show it in Finder or move it to the
    Trash (Listful asks first, since its lists go too). New Task List
    (Cmd-N) puts the new list in the folder of the list you're in.
  - **Folders from elsewhere**, such as Dropbox or OneDrive, can be added
    with **File › Add Existing Folder…** (Cmd-Shift-O) or by dragging the
    folder onto the sidebar. They appear under Other Folders, their lists
    are edited where they are, and the sidebar keeps up as lists are
    added or removed there. Right-click one to remove it from the
    sidebar; the folder itself isn't touched.
  - Lists in folders work like any other: rename them, trash them, or
    drag a task onto one to move it there. Only one level of folders is
    shown.
- **Sort tasks A–Z.** **Task › Sort A–Z** (Cmd-Option-S) sorts the level
  you're on: the task you're in and the ones alongside it. To sort a
  task's subtasks, click into one of them. On a heading it sorts the
  tasks under it, and with no task selected it sorts the top level.
  Numbers sort by value, so "2" comes before "10", and subtasks move
  with their tasks. Top-level tasks stay between the headings around them.
- **Heading attributes are hidden.** Markdown files written for Pandoc,
  kramdown and the like can end a heading with an attribute block, as in
  `## Setup {#setup}`. Listful now shows just "Setup", and keeps the
  `{#setup}` in the file, after the heading's new text if you rename it.

Groundwork for an iPhone and iPad version, which will read and write the
same Task Lists folder in iCloud Drive. Listful now handles iCloud files
properly:

- **Lists that aren't downloaded yet open without freezing.** With
  "Optimize Mac Storage" on, or straight after another Mac changes a
  list, iCloud may not have the file's contents on this Mac yet. Opening
  such a list used to freeze the window while it downloaded. It now
  shows "Downloading from iCloud…" and opens once the file arrives.
- **A list that can't be read is never saved over.** If a list couldn't
  be read (offline, say, before iCloud had downloaded it), Listful used
  to show it as empty, and typing into it could replace the file with
  the empty list. It now says it can't open the list, offers Try Again,
  and saves nothing until the file has been read.
- **Plays by iCloud's rules for reading and writing files.** Listful now
  reads, saves, renames and trashes lists the way Apple asks apps to for
  iCloud Drive files, so iCloud knows a file is being changed and treats
  a rename as a rename rather than a new file.
- **Lists stored only in iCloud still count.** On iPhone and iPad (and
  older Macs), iCloud keeps a file it hasn't downloaded as a hidden
  stand-in. Listful now lists such files under their real names, starts
  downloading them when opened, and won't create a new list with the same
  name.

## 0.4 — 2026-11-06

- **Select several tasks.** Shift-Up or Shift-Down while editing a task
  selects it and the tasks above or below; Shift-click selects everything
  down to the task you click; dragging from one task's text into another
  selects the tasks in between; Escape selects the task you're editing.
  Selected tasks are highlighted. Then:
  - **Copy, Cut and Paste** work on whole tasks, with any tasks nested
    under them. Copied tasks paste into other apps as a Markdown list.
    Paste with tasks selected replaces them.
  - **Delete** removes them, **Tab** and **Shift-Tab** indent and outdent
    them, and **Cmd-Return** marks them done (or open again if they're all
    done already).
  - **Up** and **Down** move the selection, **Cmd-A** selects every task,
    and **Return** or **Escape** go back to editing.
- **Paste several lines as tasks.** Pasting text with more than one line
  into a task, from Listful or another app, adds each line as a task below
  it, keeping any Markdown nesting, ticks and headings. Pasted into an
  empty task, the lines take its place.
- **Delete at the start of a task joins it to the one above.** The task's
  text is added to the end of the task above, with the cursor where they
  meet, and its subtasks come along as that task's last subtasks. Before,
  Delete only removed a task once it was empty. Delete at the start of a
  heading turns it back into a task, as it already did for an empty one.
- **Listful on several Macs.** If you run Listful on more than one Mac
  sharing a folder through iCloud:
  - **Only the Mac you're using makes repeating copies.** At midnight, or
    when a Mac wakes, Listful now waits until someone is actually using
    that Mac before making a new period's copy, and after a wake it gives
    iCloud 45 seconds to bring in a copy made elsewhere. Before, every
    Mac with Listful open made its own copy at midnight, and iCloud kept
    them all, renaming the extras ("Daily 2026-11-06 2").
  - **Duplicate copies are merged.** If two Macs do make the same copy,
    the second is folded into the first: a task ticked in either stays
    ticked, tasks added to only one are kept, and the duplicate goes to
    the Trash. Until then it's listed under its template, marked "(2)",
    rather than among your other lists.
  - **A list renamed or deleted on another Mac stays gone.** If that
    happened while it was open here, Listful could write it back under its
    old name. Now it doesn't; any changes you'd just made are saved beside
    it as a conflict copy instead.

## 0.3.2 — 2026-11-04

- **Delete decrufted tasks.** A new setting, Settings ▸ Decruft ▸ Delete
  decrufted tasks, makes Decruft Done Tasks delete done tasks from the list
  instead of hiding them. Tasks decrufted earlier are deleted too. An open
  task nested under a done one isn't lost: it moves up to take the done
  task's place. It's off unless you turn it on.

## 0.3.1 — 2026-11-04

- **Drag tasks into other lists.** Drag a task's dot onto a list in the
  sidebar to move it there, along with any tasks nested under it. The list
  is outlined while you're over it. The task goes at the end of that list,
  at the top level, and leaves this one. This works for repeating
  checklists, their copies and files from elsewhere too.

## 0.3 — 2026-11-04

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
