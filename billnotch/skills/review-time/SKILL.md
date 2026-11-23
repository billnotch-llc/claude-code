---
name: review-time
description: Sort uncategorized or wrongly categorized BillNotch time onto the right projects. Use when the user asks to clean up, categorize, review or tidy their tracked time, or to move tracked sessions to a project.
---

# Review uncategorized time

1. Call `list_projects`, then `list_time_entries` with `uncategorized: true` for the period (default: the last 14 days). Entries that carry a `suggestedProjectId` already have a BillNotch suggestion; `suggestedReason` says why.
2. Group the entries by where they belong. Use the activity text, any suggestion, and for "Claude Code: <folder> (<branch>)" entries the folder name against project names and keywords.
3. Show the plan as a table: project, number of entries, total time, and whether they will be marked billable (the project's own `billable` value unless the user says otherwise). List anything you cannot place separately and ask.
4. After the user approves, call `assign_time_entries` once per project with that group's ids, the `projectId` and `isBillable`.
5. Report how many entries moved. `assigned` can be lower than the number sent: entries already on an invoice, or outside what the member may edit, are skipped. Say so when it happens.

Only assign entries the user approved. Never guess a project for an entry with no signal; leave it uncategorized and say why.

If the same folder keeps arriving uncategorized, suggest the `link-repo` skill so future sessions go straight to the project.
