# ticket-loop-kit

Installs and updates the **ticket loop** in other repositories: an unattended loop that implements, verifies, and merges GitHub issue tickets one at a time, each in its own worktree. Worktrees and agent terminals are driven by a backend (Orca, cmux, or tmux). 

## Requirements and supported environments

"Verified" means one real ticket went end to end (worktree → worker → PR → CI → merge → cleanup).

| | Supported | Status |
|---|---|---|
| Worker agent | **Claude Code** (`AGENT=claude`, default) | Verified. Runs `claude --dangerously-skip-permissions` |
| | **Codex CLI** (`AGENT=codex`) | Wired up, **not verified on a real ticket**. Runs `codex --dangerously-bypass-approvals-and-sandbox`; needs a ChatGPT plan that includes Codex CLI, or an API key |
| Backend | **Orca** (`BACKEND=orca`, default) | Verified (Orca 1.4.x). Orca app running, repository registered, Command Source "orca.yaml only" |
| | **cmux** (`BACKEND=cmux`) | Verified (cmux 0.65). Run the loop inside a cmux terminal; the agent's cmux integration must be on |
| | **tmux** (`BACKEND=tmux`) | Verified (tmux 3.8). Any terminal app or SSH. Idle comes from Claude Code hooks; Codex is wired through `notify` but untested |
| Issue tracker | **GitHub Issues** via `gh` | Sub-issues (spec → tickets), `blocked_by`, labels, PR checks, merge. Other trackers would need the selection, PR, and merge functions rewritten |
| OS | **macOS** | Verified |
| | **Linux / WSL** | Code paths exist (`orca-ide`, `notify-send`, `date -d`) but have **not been run**. tmux inside WSL is the likeliest to work as is; Orca from WSL is untried; cmux is macOS-only |
| | Native Windows (cmd, PowerShell, Git Bash) | **Not supported**: bash installer and loop, symbolic links under `.claude/skills/`, no tmux in Git Bash. `npx … init` refuses on win32 and points to WSL |
| Tools | `git`, `gh` (logged in), `jq`, bash; Node ≥ 18 for `npx … init` | The bash-only install needs no Node |

**Skills, not baked-in prompts.** The worker follows skills committed in the repository, taken from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT). `tdd` and `code-review` (renamed `ticket-review`) are vendored into `.agents/skills/` and pinned to an upstream commit, so every worker runs the same version. The project-owned `implement` skill (sent as `/implement N`, `$implement N` in Codex) calls `tdd` → `ticket-review` → `pr`. The planning skills (`grill-with-docs`, `to-spec`, `to-tickets`, `retro`) are optional (`--workflow-skills`). Each skill lives once in `.agents/skills/<name>` (read by Codex) with a `.claude/skills/<name>` symbolic link (read by Claude Code).

**Constraints.**

- The worker bypasses permission prompts. The real guard against a bad merge or force push is GitHub branch protection; the kit's `deny` rules (`.claude/settings.json`, `.codex/rules/ticket-loop.rules`) are a second line.
- One loop per repository (lock directory under `.git`). GitHub (labels, assignees, PRs) is the only state.
- Each ticket starts in a fresh worktree with an empty context, so skills, worker rules, and `AGENTS.md`/`CLAUDE.md` changes take effect only after they are merged.
- The worker does not run heavy suites (integration, E2E). The loop runs `POST_MERGE_CMD` on the default branch once per `POST_MERGE_EVERY` merges (default 4; 1 means every merge) and when a spec or the run ends and stops on failure (with `POST_MERGE_RETRY_CMD`, only after one retry also fails).

## Install

From the root of the target repository:

```bash
npx github:iwishash/ticket-loop-kit init
```

Pick the backend and install steps with the keyboard (`--yes` skips the questions; `NO_COLOR` disables colors). Pin a version with `npx github:iwishash/ticket-loop-kit#v0.9.14 init`. Without Node:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/iwishash/ticket-loop-kit/main/install.sh)
```

Then:

1. In Claude Code (or Codex, as `$setup-ticket-loop`) run `/setup-ticket-loop`. It fills in the verification commands, `orca.yaml`, CI, worker rules, and `implement` for this repository and opens a PR.
2. Orca only: Settings → Projects → <repository> → Worktree Hooks → Advanced: set Command Source to **"orca.yaml only"** and turn on **"Wait for setup to complete before starting agent"**.
3. Merge the PR, then run `bash scripts/ticket-loop.sh --dry-run` and `--max 1`.

## Who does what

| Actor | Responsibility |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) | Backend choice (`BACKEND=` in `.ticket-loop/loop.env`, only when absent), install-step toggles, tool checks, then calls `install.sh` |
| `install.sh` (same in every repository) | Skill-conflict check, loop and sync scripts, `setup-ticket-loop` skill, vendored mattpocock skills, templates, `.gitignore` and `deny` merge, 6 labels, git credentials (gh), Orca registration, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` (needs to read the repository) | Fills the `__PLACEHOLDER__`s in `implement`, `pr`, and `worker-rules.md` (verification commands, the heavy suite and its single-file form), `orca.yaml`, CI, `loop.env`, `docs/agents/ticket-loop.md`, a `CLAUDE.md` pointer → PR |
| Human | Orca settings, merging the PR, watching the `--max 1` trial |

Loop behaviour worth knowing:

- `ticket-loop.sh` is Appendix D of the guidebook plus two additions: `.ticket-loop/loop.env` (committed defaults written as `VAR="${VAR:-value}"`; run-time environment wins) and a startup port check.
- If CI uses path filters, GitHub creates no checks on filtered PRs and the loop cannot tell "not up yet" from "never coming". Mirror the filter with `CI_SKIP_REGEX` or `CI_SKIP_CMD` (a script that reads the file list on stdin and prints `run` or `skip`). Leave both empty when there is no filter.
- After each merge and at the end of a `--parent` run, the loop closes the spec issue once all its sub-issues are closed.
- Outputs: `.ticket-loop/loop-MMDD.log`, `.ticket-loop/tickets.jsonl` (per machine, not committed), and after a `--parent <spec>` run the spec report `docs/loop-reports/spec-<N>.html` (review it and commit via PR). When a spec completes, the loop suggests a `/retro` pass; it never runs one itself.
- With `POST_MERGE_PORT` set, a busy port is logged with the occupying process and re-checked every 30 seconds.
- Before counting an idle strike the loop classifies the worker screen (last 25 lines). `USAGE_LIMIT_REGEX` (claude preset `reached your .* limit|usage limit`) stops the ticket at once as `usage_limit`, with the matched line and any "resets at / try again at" phrase in the reason, and without a triage session (it would hit the same limit; rerun the loop after the limit resets). `PERMISSION_PROMPT_REGEX` (claude preset `Do you want to proceed\?`) stops it as `worker_no_pr` when the same prompt line has sat unchanged at the bottom of the screen for `PROMPT_STALL_SEC` (300 s), even when the backend never reports idle; the loop never answers the prompt. Both are ERE, overridable in `loop.env`; an empty value disables that detection (the codex preset leaves both empty until measured).
- `POST_MERGE_RETRY_CMD` (default empty: no retry) gives a failed post-merge check exactly one retry. The loop waits for the port again, then runs the command in the same check worktree with `POST_MERGE_FAILED_LOG` set to the first run's log (absolute path); output goes to `post-merge-N-retry.log` next to it. If the retry passes, the loop continues, records `passed on retry in Ns (first run failed in Ms)`, comments "likely flaky" on the issue (machine, log file names, durations — no log contents), and posts to Slack without a mention. If it fails too, the loop stops and names both logs. The kit is test-runner agnostic, so the repository decides what to rerun. For vitest, commit a script (the check worktree is the merged default branch) and set `POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh}"` (the install takes seconds when nothing changed; it keeps dependencies right when the loop reruns the script at older commits to bisect a batched failure, see `POST_MERGE_EVERY` below):

  ```bash
  # scripts/post-merge-retry.sh — rerun only the test files that failed in the first run
  files=$(perl -pe 's/\e\[[0-9;]*m//g' "$POST_MERGE_FAILED_LOG" \
    | grep -oE 'FAIL +[^ ]+\.test\.ts' | awk '{print $2}' | sort -u)
  [ -n "$files" ] || { echo "no failed test files found — not retrying"; exit 1; }
  pnpm exec vitest run --config vitest.integration.config.ts $files
  ```

  When no failed file is found (the run broke during install or an environment check), the script fails instead of retrying, so a real break is not hidden. `perl` strips the ANSI color codes because macOS `sed` does not understand `\x1b`.
- `POST_MERGE_EVERY` (default 4) batches the post-merge check. It runs after every fourth merged ticket, and sooner when the ticket's spec is complete or the run has no more tickets, so a three-ticket spec gets one check after its third ticket. `1` checks after every merge (use it when the suite takes a few minutes: batching saves nothing there). `0` checks only when a spec or the run ends. A check on the default branch covers every merge before it, so no merge goes unchecked; what batching gives up is knowing which merge broke the suite. When a batched check fails and its retry fails too, the loop finds the first failing merge: it runs `POST_MERGE_RETRY_CMD` (the failed tests only) at the last passed commit, then bisects the merges since. The result goes into the stop reason and into the stop record as `post_merge_window`, for triage. Without `POST_MERGE_RETRY_CMD` the loop does not bisect, because rerunning the full suite would cost what batching saved. Bisecting runs the retry command at older commits in the same check worktree, so a retry command that relies on installed dependencies should install them first (for example `pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh`). Unchecked merges are kept in `.git/ticket-loop-post-merge.json`, so a loop that stops and restarts keeps the batch. The spec report puts the check's time on the ticket after which it ran and marks the others "post-merge check deferred". Background: in rental-portal the integration suite took 47–52 minutes per ticket (9.8 hours for 12 tickets of one spec) and caught no regression in the 34 runs after workers began running the related integration tests before opening their PR.

## Backends

The loop touches worktrees and terminals through nine functions (create, remove, send a prompt, shell input, Ctrl-C, wait for idle, read the screen, set status, startup check), implemented per backend as `orca_*`, `cmux_*`, `tmux_*` and selected with `BACKEND=orca|cmux|tmux` in `loop.env`. Ticket selection, PR, CI, repair, merge, post-merge verification, records, and the spec report are shared.

| | Orca | cmux | tmux |
|---|---|---|---|
| Worktree | `orca worktree create` runs the `orca.yaml` setup | `git worktree add` under `WORKTREE_DIR` (default `~/.cache/ticket-loop/<owner-repo>/worktrees`), then `WORKTREE_SETUP_CMD` | Same as cmux |
| Agent | Orca launches it with `--agent claude --prompt` | `cmux workspace create --cwd … --command "claude …"`; the workspace's claude shim attaches the Claude Code hooks | A window in `TMUX_SESSION` (default `ticket-loop`, or the current session) running `claude … --settings <hook settings>` |
| Idle detection | `orca terminal wait --for tui-idle` | `lifecycle` from `cmux rpc surface.input_state` every 5 s | Hooks write `state/<worktree>` under `~/.cache/ticket-loop/<owner-repo>/tmux/`; read every 5 s |
| Input and screen | `orca terminal send / read` | `cmux paste --submit`, `send --force` + `send-key enter`, `read-screen --lines 25` | `send-keys -l` + `Enter`, last 25 lines of `capture-pane -p` |
| Status display | `orca worktree set --workspace-status` | `cmux workspace status set`, `cmux pr`, `cmux log` | `[working]`, `[review]`, `[done]`, `[needs-attention]` in the window name |
| Prerequisites | Orca app running, repository registered | Inside a cmux terminal (socket mode `cmuxOnly`); main checkout trusted by Claude Code | `tmux` installed; main checkout trusted; `AGENT=claude\|codex` only. Watch with `tmux attach -t ticket-loop` |

Claude Code decides a new worktree's trust by the main checkout's path, so the cmux and tmux startup checks read `~/.claude.json` and refuse to start until the main checkout is trusted. Warp, Ghostty, and the like are terminal apps, not backends: run the tmux backend inside them. cmux CLI notes (0.65): `--json` goes after the command, lanes are `todo|working|needs-attention|review|done`, and a workspace whose process is still alive closes only with `workspace close --force`.

## What goes where

| Kit path | Target repository | On install |
|---|---|---|
| `files/scripts/ticket-loop.sh`, `ticket-state.sh`, `sync-mattpocock-skills.sh` | `scripts/` | Overwritten every time (kit-owned) |
| `files/.agents/skills/setup-ticket-loop/`, `loop-triage/` | Same path, plus `.claude/skills/` links | Overwritten every time |
| `templates/.agents/skills/implement/`, `pr/` | Same path, plus `.claude/skills/` links | Only when absent (project-owned afterwards) |
| `templates/.codex/rules/ticket-loop.rules` | Same path | Only when absent. Codex counterpart of the `deny` rules; the installer fills in the default branch |
| `templates/.ticket-loop/worker-rules.md`, `docs/loop-reports/README.md`, `docs/agents/issue-tracker.md` | Same paths | Only when absent |
| — | `.agents/skills/tdd`, `ticket-review` (+ planning skills), with `.claude/skills/` links | Vendored by `sync-mattpocock-skills.sh` |
| — | `.gitignore` (`/.ticket-loop/*.log`, `*.jsonl`, `stops/`), `deny` in `.claude/settings.json` | Merged |
| — | 6 GitHub labels, git credentials (gh), Orca registration | Created when missing |
| — | `.ticket-loop/kit.json` | Records the installed kit commit |

Skills live once in `.agents/skills/<name>` with `.claude/skills/<name>` links (the `npx skills add` layout); installs from 0.6 or earlier are migrated with `git mv`. The `## Agent skills` block goes in `AGENTS.md` (Codex reads only that file) and `CLAUDE.md` imports it with `@AGENTS.md`; `/setup-ticket-loop` writes both. Project-specific values live in `loop.env`, `orca.yaml`, `worker-rules.md`, and the `implement` and `pr` skills. Do not edit kit-owned files in the target repository; fix them in the kit.

## Update

Run the install command again. Kit-owned files and vendored skills are refreshed; project-owned files, including `loop.env`, stay as they are. Installs from 0.3 or earlier are migrated (`.agent-loop/` or `.orca-loop/` → `.ticket-loop/`, old skills and `.gitignore` lines removed) and the installer lists files that still point at old paths for you to fix in the same PR. Review with `git diff` and open a PR. npx caches a fetched repository; use `npx --yes --prefer-online` to re-fetch the same ref.

Options: `--yes`, `--backend <orca|cmux|tmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). The bash path also takes `--ref <ref>`.

## mattpocock skills: what is vendored, what is checked

Skills are vendored as files rather than installed as a plugin so that every worktree and cloud session gets the same version from a plain clone, and no automatic update can change behaviour mid-run.

| Set | Skills | Default |
|---|---|---|
| core | `tdd`, `code-review` → `ticket-review` (the name clashes with the built-in `/code-review`) | Always |
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`, plus `grilling`, `domain-modeling`, `writing-for-agents` | Fresh install: on, unless the `mattpocock-skills` plugin is enabled for this repo (then the plugin provides them on this machine). Reinstall: the previous choice. `--workflow-skills` / `--no-workflow-skills` override |
| kept | Skills an earlier install (0.5 and before vendored all 26) placed outside the two sets | Kept and synced, never added to a fresh install. `--prune-skills` removes them |

The manifest `.agents/skills/.mattpocock.json` records all three. A skill you deleted by hand is not restored; one upstream dropped is left alone. Its `project_owned` list names the skills the repository maintains by hand (`implement` and `pr` by default): add a vendored name such as `ticket-review` there and the sync leaves that directory alone and lists it under `project-owned (update by hand)`. Any other vendored skill is overwritten; when it differed from the previous sync's upstream copy (committed edits included), the summary adds `overwrote local edits: <name>` so you can restore it from git and mark it `project_owned`. Other upstream skills come from the plugin (`claude plugin install mattpocock-skills@claude-plugins-official`).

Before changing anything, the installer looks for the same skills installed another way (`bash scripts/sync-mattpocock-skills.sh --check` runs it alone):

| Found | Handling |
|---|---|
| The `mattpocock-skills` plugin enabled for this repo (the picker shows `/tdd` and `/mattpocock-skills:tdd` side by side; the loop runs the vendored one) | Notice. `tdd` and `ticket-review` are vendored anyway; a fresh install leaves the planning skills to the plugin. The checklist offers `claude plugin disable … --scope project` (off by default; if you turn it on, vendor the planning skills too) |
| The same skill in `~/.claude/skills/<name>` (shadows the committed copy) | Warning with the names |
| `skills-lock.json` from `npx skills add`, or a `.claude/skills/*` link pointing outside this repo's `.agents/skills/` | **Install stops.** Remove with `npx skills remove` and rerun (`--force-skills` overrides, `--no-skills` skips vendoring) |
| A `code-review` skill directory (replaces the built-in `/code-review`) | Warning with an `rm -rf` hint |
| A same-named directory not in the manifest, or `.claude/commands/<name>.md` | Notice |

The plugin and `~/.claude/skills` checks run only for `--agent claude`; with `--agent codex` a same-named `~/.agents/skills/<name>` is reported instead.

## Running the same repository on several computers

A plain clone runs on another computer; reinstall only to upgrade the kit, on one computer, and `git pull` elsewhere.

- Everything the loop needs is committed. The only per-machine files are `.ticket-loop/*.log` and `tickets.jsonl` (ignored), plus `~/.config/ticket-loop/loop.env` outside the repository (secrets such as the Slack webhook URL; see "Notifications").
- The backend may differ per computer: `BACKEND=cmux bash scripts/ticket-loop.sh N` overrides the `loop.env` default. cmux and tmux need `WORKTREE_SETUP_CMD` in `loop.env`, worktrees under `~/.cache/ticket-loop/<owner-repo>/worktrees`, and the main checkout trusted by Claude Code (open `claude` there once).
- Concurrent loops: give explicit ticket numbers, or partition automatic selection with `--parent` or `--label`. Assignee and open-PR checks do not prevent a race seconds apart; a conflicting PR is handled by the repair step.
- The spec report is drawn from that computer's `tickets.jsonl`, so run one spec on one computer; tickets without records fall back to PR timestamps.

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

## Working on the kit

- After changing the loop script, regenerate Appendix D and the PDF: `python3 docs/sync-guide.py && bash docs/build-pdf.sh` (`tests/smoke.sh` checks that Appendix D matches).
- `bash tests/smoke.sh` installs into a temporary repository without network, checks that installing twice is idempotent, and renders the spec report against fixtures.
- Record changes in `CHANGELOG.md`; the version goes in `VERSION`, `package.json`, and a tag.
- Do not add a build step such as `prepare` to `package.json`; fetched straight from git, it would run on the user's machine. The npx package contains only the `files` list; `docs/` and `tests/` are excluded.

## Verification status

Verified with one real ticket per backend (details in `CHANGELOG.md`):

| Backend | Ticket | Wall clock | Repairs |
|---|---|---|---|
| Orca 1.4.x | iwishash/boiler-webapp #34 → PR #38 (2026-10-12) | 10 min | 0 |
| cmux 0.65 | iwishash/boiler-webapp #39 → PR #40 (2026-10-12) | 7 min | 0 |
| tmux 3.8 | iwishash/ticket-loop-dummy #1 → PR #2 (2026-10-13) | 4 min | 0 |

Triage (0.9.0, iwishash/ticket-loop-dummy on tmux, 2026-10-17), one run per resumable stop. Each failure came from a second PR merged while the ticket was in flight, so the worker could not see it:

| Stop | Ticket | Triage session | Wall clock |
|---|---|---|---|
| Post-merge check failed | #12 → PR #13 | Fix PR #14 (code), merged; check passed again | 6 min |
| Worktree setup failed | #17 → PR #19 | Fix PR #18 (setup script), merged; worktree pulled, setup passed | 7 min |
| CI failed, repairs used up (`REPAIR_ROUNDS=0`) | #21 → PR #22 | Merged `main` into the ticket branch and pushed the fix | 6 min |
| Worker stopped without a PR | #23 | Diagnosis only, `halt (needs-human)`; the loop stopped with the summary | stopped |

The setup run found a bug fixed in 0.9.1: the fix PR title `fix: #17 …` closed the still-open ticket on merge. `/loop-triage <id>` by hand on the #23 stop (headless, read-only tools) found the record, kept the earlier verdict, and gave the rerun and worktree cleanup steps, asking before cleaning up.

Also verified: stop reporting (0.8.8) — iwishash/ticket-loop-dummy #3 on cmux, stopped twice (SIGHUP and SIGTERM → issue comment, `loop-stopped` label, Slack) and merged on the third run as PR #4 (3 min, label removed); `tests/smoke.sh`, the npx wrapper against a real fetch of the repository (then private), and migration of a 0.2 install (smoke test only).

Not yet verified:

- Batched post-merge checks (`POST_MERGE_EVERY` other than 1) and bisecting a batched failure on a real loop (`tests/smoke.sh` covers them with a real git repository and fake commands).
- `POST_MERGE_PORT`, `POST_MERGE_RETRY_CMD`, `CI_SKIP_CMD`, `CI_SKIP_REGEX`, and the repair prompt on a real ticket (`POST_MERGE_CMD` ran in the triage runs above; every run had 0 repairs). rental-portal (PR #82) has them configured.
- The label creation and Orca registration steps of `install.sh` (turned off in testing).
- `/setup-ticket-loop` beyond one run on boiler-webapp.
- Linux and WSL. The Linux branches have never executed; try the tmux backend inside WSL first. Orca driven from WSL through `orca-ide` is an open question (Windows app vs. Linux AppImage under WSLg, path mapping).
- Triage: a flake verdict, a loop-bug verdict with a kit bug report, no verdict (timeout or idle), and a conflict (rather than a CI failure) left to triage. `tests/smoke.sh` covers them with fake backends and `gh`.
- Codex as the worker. The preset, prompts, skill layout, `AGENTS.md`, `.codex/rules/ticket-loop.rules`, and `--agent codex` are in place, but nothing has run on a machine with Codex installed: idle detection, `$implement` picking up the skill, repair prompts, and whether the rules file loads under `--dangerously-bypass-approvals-and-sandbox`.
- The source repository rsrehab/rental-portal still uses its own `scripts/orca-ticket-loop.sh`.
- Of the stop paths, two signals (SIGHUP and SIGTERM) and `die` (the triage `halt` above) ran for real. `set -e`, Ctrl-C and SIGPIPE were checked by the smoke test (fake `gh` and `curl`) and by pty and `tee` experiments.
