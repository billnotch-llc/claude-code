---
name: link-repo
description: Link the current repository to a BillNotch project so automatically tracked Claude Code time lands on that project. Use when the user asks to link, connect or map this repo or folder to a project or client, or asks why tracked sessions show up uncategorized.
---

# Link this repository to a BillNotch project

The plugin tracks Claude Code sessions automatically. Without a link they arrive in BillNotch uncategorized, with a project suggestion to review. A link file sends them straight to one project.

1. Call `list_projects`. Match on the repository name, the project name and its keywords, and propose the best candidate. If several fit or none does, list them and ask. Projects are created in BillNotch, not here.
2. After the user confirms, write `.billnotch.json` at the repository root:

   ```json
   {
     "projectId": "<project id>",
     "billable": true
   }
   ```

   Set `billable` to the project's own `billable` value from `list_projects`.

3. Ask whether the link should be shared with the team. The file holds only a project id, so committing it is safe, but teammates in another BillNotch organization would get an id that does not exist for them. If it is personal, add `.billnotch.json` to `.git/info/exclude` instead of `.gitignore`.
4. Tell the user it applies from the next prompt. Time already tracked stays where it is; offer the `review-time` skill to move it.

To unlink, delete the file.

If the user wants tracking off entirely, that is the plugin's "Track Claude Code sessions automatically" option, not this file.
