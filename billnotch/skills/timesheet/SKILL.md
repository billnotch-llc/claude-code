---
name: timesheet
description: Summarize tracked time from BillNotch for a period, by project, client or day. Use when the user asks how much they worked, for a timesheet, weekly or monthly hours, billable totals, or what is still unbilled.
---

# Timesheet from BillNotch

1. Pick the period. "This week" follows the member's week start; `whoami` returns `weekStart` and `timezone`. Default to the current week when the user names no period.
2. Call `report_summary` with `from`, `to` and `tz` set to the member's timezone, so the day buckets match their calendar. Add `projectId` when they ask about one project.
3. Present it compactly:
   - Total hours and billable hours.
   - A table by project: hours, billable hours, billable amount, already invoiced.
   - Days only when the user asked for a daily breakdown.
4. Durations arrive in seconds: show hours and minutes ("6h 30m"). Money arrives as integer cents plus a currency: format it, and never add amounts in different currencies together.

## What is unbilled

When the user asks what they can invoice, what is unbilled, or where money is slipping, call `revenue_leaks` and report:

- Uninvoiced billable work per client, oldest first, with the amount and how old it is.
- Projects with billable time but no hourly rate, and projects with no client. Those hours cannot be invoiced until that is fixed in BillNotch.
- Uncategorized time. Offer the `review-time` skill to sort it.

A member without the "view all time" permission sees only their own hours. `whoami` reports this as `seesAllMembersTime`; say whose time the numbers cover when it is false.

Report only what the tools return. If a period is empty, say so instead of estimating.
