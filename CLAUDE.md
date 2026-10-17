# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Pre-implementation. The only content is `spec/specification.md`, which is the source of truth for requirements. There is no build system, source code, or tests yet — update this file with build/test commands and architecture notes once the project is scaffolded.

## What we're building

A native macOS desktop task manager, written in **Swift**, in the spirit of Workflowy but as a one-off (non-subscription) app.

Core behaviour from the spec:

- **Outline of tasks** shown as a bulleted list. Pressing Tab on a task makes it a child of the task above it (indented); the hierarchy is arbitrarily nestable.
- **Collapsing**: a parent can be collapsed to hide its children and show only the parent.
- **Task states** (initial set — design for extension):
  - `Open`
  - `Done` — rendered struck through
  - `Decrufted` — a done task that is hidden but *not* deleted; there is a toggle to show/hide decrufted tasks.

## Storage backends

Storage should sit behind an abstraction so backends can be swapped. In priority order:

1. **Markdown file on the local filesystem** — implement this first.
2. Markdown file in a git repository.
3. (Possibly) an Apple Note.

Because the primary format is Markdown, the on-disk representation should round-trip the hierarchy (indentation), collapsed state where needed, and all three task states — including Decrufted, which must persist without being lost.
