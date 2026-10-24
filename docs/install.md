# Install and update

[README](../README.md) · [한국어](install.ko.md)

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

## Who does what

| Actor | Responsibility |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) | Backend choice (`BACKEND=` in `.ticket-loop/loop.env`, only when absent), install-step toggles, tool checks, then calls `install.sh` |
| `install.sh` (same in every repository) | Skill-conflict check, loop and sync scripts, `setup-ticket-loop` skill, vendored mattpocock skills, templates, `.gitignore` and `deny` merge, 6 labels, git credentials (gh), Orca registration, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` (needs to read the repository) | Fills the `__PLACEHOLDER__`s in `implement`, `pr`, and `worker-rules.md` (verification commands, the heavy suite and its single-file form), `orca.yaml`, CI, `loop.env`, `docs/agents/ticket-loop.md`, a `CLAUDE.md` pointer → PR |
| Human | Orca settings, merging the PR, watching the `--max 1` trial |

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

Options: `--yes`, `--backend <orca|cmux|tmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). The bash path also takes `--ref <ref>`. Pin a version with `npx github:iwishash/ticket-loop-kit#v0.9.16 init`; `NO_COLOR` disables colors.

## mattpocock skills: what is vendored, what is checked

**Skills, not baked-in prompts.** The worker follows skills committed in the repository, taken from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT). `tdd` and `code-review` (renamed `ticket-review`) are vendored into `.agents/skills/` and pinned to an upstream commit, so every worker runs the same version. The project-owned `implement` skill (sent as `/implement N`, `$implement N` in Codex) calls `tdd` → `ticket-review` → `pr`. The planning skills (`grill-with-docs`, `to-spec`, `to-tickets`, `retro`) are optional (`--workflow-skills`). Each skill lives once in `.agents/skills/<name>` (read by Codex) with a `.claude/skills/<name>` symbolic link (read by Claude Code).

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

- Everything the loop needs is committed. The only per-machine files are `.ticket-loop/*.log` and `tickets.jsonl` (ignored), plus `~/.config/ticket-loop/loop.env` outside the repository (secrets such as the Slack webhook URL; see [Notifications](stops.md#notifications-slack-and-stop-records-on-github)).
- The backend may differ per computer: `BACKEND=cmux bash scripts/ticket-loop.sh N` overrides the `loop.env` default. cmux and tmux need `WORKTREE_SETUP_CMD` in `loop.env`, worktrees under `~/.cache/ticket-loop/<owner-repo>/worktrees`, and the main checkout trusted by Claude Code (open `claude` there once).
- Concurrent loops: give explicit ticket numbers, or partition automatic selection with `--parent` or `--label`. Assignee and open-PR checks do not prevent a race seconds apart; a conflicting PR is handled by the repair step.
- The spec report is drawn from that computer's `tickets.jsonl`, so run one spec on one computer; tickets without records fall back to PR timestamps.
