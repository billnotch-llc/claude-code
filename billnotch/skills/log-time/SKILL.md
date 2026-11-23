---
name: log-time
description: Log a block of work to BillNotch, or start and stop the BillNotch timer. Use when the user says to log, track, record or bill time ("log 2h on the API refactor", "start a timer", "stop the timer"), or asks whether a timer is running.
---

# Log time in BillNotch

Use the BillNotch MCP tools. The entry is written as the signed-in member.

## Logging a finished block

1. Work out three things from what the user said: what they did, how long or between which times, and which project.
2. Call `list_projects` to find the project id. If this repository has a `.billnotch.json` file at its root, its `projectId` is the default project. If neither gives a clear match, ask which project, or log it uncategorized if the user says so.
3. Call `log_time`:
   - `activity`: one specific line in the user's own words. "Fix webhook retry bug" is good, "Development" is not.
   - Give `durationMinutes` alone when the work just finished (the block ends now), or `startedAt` plus `endedAt` or `durationMinutes` for a block in the past. Convert the user's local times to ISO 8601 with their offset; `whoami` returns their timezone if you need it.
   - Leave `isBillable` out unless the user says otherwise, so the project's own setting applies.
4. Confirm in one line: project, duration, time range.

If the call fails with `OVERLAPPING_ENTRIES`, the block collides with time already tracked. Tell the user which entries overlap and ask before retrying with `allowOverlap: true`. Automatically tracked Claude Code sessions are a common cause; overlapping them is usually a double count, not something to force.

If it fails with `BILLING_LOCKED`, the organization's trial has ended. Say so and point to Settings, Billing in BillNotch. Do not retry.

## Timer

- "Start a timer": `start_timer` with an activity and, when known, a project id. If it fails with `TIMER_ALREADY_RUNNING`, show `timer_status` and ask whether to stop that one first.
- "Stop the timer": `stop_timer`. Pass `activity` or `projectId` only to change what the timer was started with.
- "Is a timer running?": `timer_status`.

Never invent durations. If the user gives no length and no times, ask.
