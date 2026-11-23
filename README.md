# BillNotch for Claude Code

The BillNotch plugin for [Claude Code](https://claude.com/claude-code). It tracks the time
you spend in Claude Code sessions and lets you log time, pull timesheets and draft invoices
without leaving the terminal.

This folder is a plugin marketplace with one plugin, `billnotch`.

## Install

Inside Claude Code:

```
/plugin marketplace add billnotch-llc/claude-code
/plugin install billnotch@billnotch
```

Claude Code then asks for a **BillNotch key**. Create one in BillNotch under Settings,
Devices, Connect Claude Code. The key acts with your own BillNotch permissions and can be
revoked at any time under API keys.

## What you get

| Skill                      | What it does                                                     |
| -------------------------- | ---------------------------------------------------------------- |
| `/billnotch:log-time`      | Log a block of work, or start and stop the timer                 |
| `/billnotch:timesheet`     | Hours by project, client or day, and what is still unbilled      |
| `/billnotch:draft-invoice` | Preview a client's unbilled time and save it as a draft invoice  |
| `/billnotch:link-repo`     | Link this repository to a project so tracked sessions land on it |
| `/billnotch:worklog`       | Turn git commits into time entries for the gaps in your day      |
| `/billnotch:review-time`   | Sort uncategorized time onto the right projects                  |

You do not have to type the commands. "Log 2 hours on the API refactor" or "what can I
invoice Acme for last month?" works too.

Invoices are only ever previewed and saved as drafts. Sending, voiding and marking paid
stay in the BillNotch app.

## Automatic session tracking

While you work with Claude Code, the plugin records blocks of active time and uploads them
to BillNotch as time entries named `Claude Code: <folder> (<branch>)`.

- A block starts with a prompt and continues while prompts keep coming within the idle
  cutoff (5 minutes by default). A whole turn counts, however long Claude works.
- Blocks shorter than a minute are dropped.
- Uploads are idempotent and retried, so a crash or an offline spell never double counts.
- **Only the folder name, the git branch and timestamps are sent.** Prompts, code, file
  names and the conversation never leave your machine.

Run `/billnotch:link-repo` once per repository to send its sessions straight to a project.
Unlinked sessions arrive uncategorized, with a project suggestion to review.

Turn tracking off with the plugin's "Track Claude Code sessions automatically" option. The
skills keep working.

## Options

| Option                | Default                     |                                                   |
| --------------------- | --------------------------- | ------------------------------------------------- |
| BillNotch key         | required                    | Stored in your system's secure credential storage |
| API URL               | `https://api.billnotch.com` | Change only for a self-hosted BillNotch           |
| Track sessions        | on                          | Passive tracking described above                  |
| Idle cutoff (minutes) | 5                           | A longer gap between prompts ends the block       |

## Requirements

Session tracking is a POSIX shell script that needs `curl`. On Windows it runs under Git
Bash. The skills and tools need nothing beyond Claude Code.

## Develop

```sh
claude plugin validate billnotch
claude --plugin-dir billnotch
```

Point the API URL option at `http://localhost:3001` to work against a local API.
