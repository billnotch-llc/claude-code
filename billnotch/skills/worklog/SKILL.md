---
name: worklog
description: Turn git history into BillNotch time entries. Use when the user wants to log today's or a past day's work from their commits, backfill a timesheet they forgot to fill in, or write time entry descriptions from what they shipped.
---

# Log work from git history

Commits say what was done. They do not say how long it took, so the user decides the durations.

1. Pick the day or range (default: today). Get the user's own commits:

   ```sh
   git log --since="<start>" --until="<end>" --author="$(git config user.email)" --date=iso-strict --pretty="%ad%x09%s"
   ```

2. Call `list_time_entries` for the same range. Automatically tracked sessions appear there as "Claude Code: ...". They already cover time spent in Claude Code, so do not log that time again.
3. Group related commits into a few blocks of work, each with a specific one-line description built from the commit subjects. Leave out merge commits and version bumps.
4. Propose a table: block, suggested start and end, project. Base the times on commit timestamps and on the gaps left by existing entries, and say plainly that they are estimates. Use the project from `.billnotch.json` when the repository is linked, otherwise `list_projects`.
5. Let the user correct descriptions, times and projects. Wait for an explicit go-ahead.
6. Log each approved block with `log_time`, using `startedAt` and `endedAt`. On `OVERLAPPING_ENTRIES`, stop and show the collision rather than forcing it.
7. Finish with the total hours logged and the day's new total from `report_summary`.

If an automatically tracked block already covers the work and only its wording is poor, it is better left as tracked. This skill fills gaps; it does not rewrite existing entries.
