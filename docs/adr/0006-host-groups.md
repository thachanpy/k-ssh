# ADR 0006 — Host groups (folders) stored separately from hosts

- **Status:** Accepted (unverified: not compiled by the author)
- **Date:** 2026-11-14

## Context

Users want folders in the sidebar and drag-and-drop, including for hosts imported from `~/.ssh/config`.
Those hosts are never written to `hosts.json` (CLAUDE.md §5), so a `groupID` on `HostProfile` cannot work for them.

## Decision

- New file `groups.json` (`GroupsState`: ordered `groups` + `assignments[hostID] = groupID`), owned by `GroupRepository` (actor over `JSONStore`).
- Assignments are keyed by host ID. ssh-config host IDs are stable (SHA-256 of the alias), so they survive reloads.
- One level of folders (no nesting). Deleting a folder ungroups its hosts; deleting a host removes its assignment.
- Drag payload is the string `host:<uuid>`; tab reordering uses bare UUID strings, so the two never collide.
- `StoreFile` gains `.groups` (CLAUDE.md §5 file list should mention it).
