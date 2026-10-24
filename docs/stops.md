# When the loop stops

[README](../README.md) · [한국어](stops.ko.md)

## Notifications: Slack, and stop records on GitHub

So that a loop that breaks while you are away does not go unnoticed, the loop reports in two places.

- **Slack (notification)**: with `SLACK_WEBHOOK_URL` set, the loop posts start, each ticket done, a stop, and finish to a channel. A stop carries the reason and the last 12 log lines (including the worker screen tail), prefixed with `SLACK_MENTION` if set (not for Ctrl-C).
- **GitHub (record)**: when the loop stops mid-ticket it comments on that issue (reason, machine, PR, worktree, the last 30 of the loop's own log lines) and adds the `loop-stopped` label (`STOPPED_LABEL`). The loop writes as your account, and GitHub does not notify you of your own activity, so this is a record, not an alert. Ticket selection ignores the label; the loop removes it when it merges that ticket. The worker screen is left out of the comment so it never lands in a public repository.

A stop is reported once however the loop ends: a stop condition (no PR, timeout, repairs used up, …), the terminal window closing, Ctrl-C, `kill`, or a command failing under `set -e` (for example `git fetch` or `gh` when the network drops). `kill -9`, power loss and sleep cannot be caught: the script gets no chance to send anything.

Slack setup (once per computer):

1. <https://api.slack.com/apps> → **Create New App** → **Blank app** (formerly From scratch) → a name (e.g. `ticket-loop`) and the workspace.
2. In the wizard that follows, add only `incoming-webhook` under **Bot scopes** (leave user scopes and events empty) → **Create and Install** → pick the channel for the webhook (e.g. a private `#ticket-loop` created beforehand; you must be a member to see it) → **Allow**. **Go to App Settings** → **Incoming Webhooks** in the sidebar → copy the URL under "Webhook URLs for Your Workspace" (the Slack CLI steps are not needed). On the older screens, **Incoming Webhooks** → **Activate Incoming Webhooks** → **Add New Webhook** gives the same URL. Workspaces that restrict app installs need admin approval.
3. Put the URL in the per-machine file, which is not committed. Do not use the repository `loop.env`; it is committed, and the loop warns at startup if a webhook URL is there. Anyone with the URL can post to the channel.
   ```bash
   mkdir -p ~/.config/ticket-loop
   cat >> ~/.config/ticket-loop/loop.env <<'EOF'
   SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/T…/B…/…}"
   SLACK_MENTION="${SLACK_MENTION:-<@U012AB3CD>}"   # optional: Slack profile → ⋮ → Copy member ID
   EOF
   chmod 600 ~/.config/ticket-loop/loop.env
   ```
   The file applies to every repository on that computer (it follows `XDG_CONFIG_HOME`) and is read before the repository `loop.env`, so it wins.
4. Phone alerts: set the channel to notify on all new messages, or keep it at mentions only and let `SLACK_MENTION` ring only on stops.
5. Check: the loop's startup lines show `notifications: desktop + Slack` and "Ticket loop started" appears in the channel. `--dry-run` sends nothing.

## Triage: the loop tries to fix what stopped it

Noticing a stop and getting to it usually takes longer than the fix. On rental-portal spec #96 a post-merge check failed at 15:43; the fix was three lines of test expectations, and the loop ran again at 19:08. So with `LOOP_TRIAGE=1` (the default) the loop does not stop right away in four cases. It writes a stop record, starts a **triage session** (an agent in a fresh worktree `loop-triage-N-<time>`, started the same way as a worker) with `/loop-triage <record>`, and waits, still holding the lock, for a verdict file (`resume` or `halt`). Slack gets "triage started" and then the outcome.

| Stop | Triage session | On `resume` the loop |
|---|---|---|
| Post-merge check failed (retry included) | Compares the failure with the merged PR's diff, fixes the test expectation or the code, runs only the failing test files, opens a fix PR into the default branch. An unrelated timeout is rerun and called a flake | Labels the fix PR `loop-triage`, merges it after CI, reruns the post-merge check on the merged branch (`post-merge-N-after-triage.log`), continues if it passes |
| CI failure or conflict after the repair rounds, or CI still failing after a repair that pushed no commit | Pushes a fix to the ticket PR's branch. A threshold such as a bundle-size ceiling is raised only when the ticket's own change justifies it, with the reason in a PR comment. A CI infrastructure error gets `gh run rerun --failed` | Continues from that PR's conflict/CI check |
| `WORKTREE_SETUP_CMD` failed (cmux, tmux) | Reproduces the setup and fixes the repository script or lockfile in a fix PR, or nothing if it was transient | Merges the fix PR, fast-forwards the worker worktree (and the main checkout when it is on the default branch; git refuses a merge that would touch local changes) and reruns the setup |
| Worker stopped without a PR | Diagnosis only: summarizes what the worker was stuck on. It does not answer the worker's question | (always stops) |

The loop resumes where it stopped instead of starting over, because a fresh run skips a ticket with an open PR or an assignee. On `halt`, no verdict (timeout or idle), a failing fix PR, or the same stop again after resuming, the loop stops with the verdict summary appended to the reason (Slack mention) and keeps the triage worktree. It triages at most `TRIAGE_MAX` times per run (default 1) and each stop once; `TRIAGE_TIMEOUT_SEC` (default 3600) bounds a session.

The session runs the `loop-triage` skill committed on the default branch, so nothing is triaged until the kit install PR is merged (the startup lines say so). It never edits the main checkout or kit-owned files: a loop bug ends in a kit bug report next to the stop record (`<id>.kit-bug.md`) for you to file, so the repository's logs and code never go to the (public) kit repository on their own. It does not weaken tests without a reason quoted from the merged PR, does not merge, and does not touch local processes, production, or secrets. Other stops (ticket timeout, lost terminal, agent start failure, merge failure, signals, `set -e`) are not triaged: they are not points the loop can safely resume from.

Every stop, triaged or not, leaves `.ticket-loop/stops/<id>.json` (reason, issue, PR, log paths, worktrees, the command to rerun) and its id in the issue comment. To pick it up yourself, run `/loop-triage <id>` (`$loop-triage` in Codex) in an agent session in that repository; it reads the record and any earlier verdict, and asks before merging.
