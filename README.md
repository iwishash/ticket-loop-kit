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
- The worker does not run heavy suites (integration, E2E). The loop runs `POST_MERGE_CMD` on the default branch after each merge and stops on failure.

## Install

From the root of the target repository:

```bash
npx github:iwishash/ticket-loop-kit init
```

Pick the backend and install steps with the keyboard (`--yes` skips the questions; `NO_COLOR` disables colors). Pin a version with `npx github:iwishash/ticket-loop-kit#v0.8.0 init`. Without Node:

```bash
bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
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
| `files/.agents/skills/setup-ticket-loop/` | Same path, plus a `.claude/skills/` link | Overwritten every time |
| `templates/.agents/skills/implement/`, `pr/` | Same path, plus `.claude/skills/` links | Only when absent (project-owned afterwards) |
| `templates/.codex/rules/ticket-loop.rules` | Same path | Only when absent. Codex counterpart of the `deny` rules; the installer fills in the default branch |
| `templates/.ticket-loop/worker-rules.md`, `docs/loop-reports/README.md`, `docs/agents/issue-tracker.md` | Same paths | Only when absent |
| — | `.agents/skills/tdd`, `ticket-review` (+ planning skills), with `.claude/skills/` links | Vendored by `sync-mattpocock-skills.sh` |
| — | `.gitignore` (`/.ticket-loop/*.log`, `*.jsonl`), `deny` in `.claude/settings.json` | Merged |
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
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`, plus `grilling`, `domain-modeling`, `writing-for-agents` | Off. `--workflow-skills` or the checklist; kept if a previous install had them |
| kept | Skills an earlier install (0.5 and before vendored all 26) placed outside the two sets | Kept and synced, never added to a fresh install. `--prune-skills` removes them |

The manifest `.agents/skills/.mattpocock.json` records all three. A skill you deleted by hand is not restored; one upstream dropped is left alone. Other upstream skills come from the plugin (`claude plugin install mattpocock-skills@claude-plugins-official`).

Before changing anything, the installer looks for the same skills installed another way (`bash scripts/sync-mattpocock-skills.sh --check` runs it alone):

| Found | Handling |
|---|---|
| The `mattpocock-skills` plugin enabled for this repo (`/tdd` and `/mattpocock-skills:tdd` would both load) | Warning; the checklist offers `claude plugin disable … --scope project` |
| The same skill in `~/.claude/skills/<name>` (shadows the committed copy) | Warning with the names |
| `skills-lock.json` from `npx skills add`, or a `.claude/skills/*` link pointing outside this repo's `.agents/skills/` | **Install stops.** Remove with `npx skills remove` and rerun (`--force-skills` overrides, `--no-skills` skips vendoring) |
| A `code-review` skill directory (replaces the built-in `/code-review`) | Warning with an `rm -rf` hint |
| A same-named directory not in the manifest, or `.claude/commands/<name>.md` | Notice |

The plugin and `~/.claude/skills` checks run only for `--agent claude`; with `--agent codex` a same-named `~/.agents/skills/<name>` is reported instead.

## Running the same repository on several computers

A plain clone runs on another computer; reinstall only to upgrade the kit, on one computer, and `git pull` elsewhere.

- Everything the loop needs is committed. The only per-machine files are `.ticket-loop/*.log` and `tickets.jsonl` (ignored).
- The backend may differ per computer: `BACKEND=cmux bash scripts/ticket-loop.sh N` overrides the `loop.env` default. cmux and tmux need `WORKTREE_SETUP_CMD` in `loop.env`, worktrees under `~/.cache/ticket-loop/<owner-repo>/worktrees`, and the main checkout trusted by Claude Code (open `claude` there once).
- Concurrent loops: give explicit ticket numbers, or partition automatic selection with `--parent` or `--label`. Assignee and open-PR checks do not prevent a race seconds apart; a conflicting PR is handled by the repair step.
- The spec report is drawn from that computer's `tickets.jsonl`, so run one spec on one computer; tickets without records fall back to PR timestamps.

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

Also verified: `tests/smoke.sh`, the npx wrapper against a real fetch of the repository (then private), and migration of a 0.2 install (smoke test only).

Not yet verified:

- `POST_MERGE_CMD`, `POST_MERGE_PORT`, `CI_SKIP_CMD`, `CI_SKIP_REGEX`, and the repair prompt on a real ticket (all three runs had no post-merge verification, no CI filter, 0 repairs). rental-portal (PR #82) has them configured.
- The label creation and Orca registration steps of `install.sh` (turned off in testing).
- `/setup-ticket-loop` beyond one run on boiler-webapp.
- Linux and WSL. The Linux branches have never executed; try the tmux backend inside WSL first. Orca driven from WSL through `orca-ide` is an open question (Windows app vs. Linux AppImage under WSLg, path mapping).
- Codex as the worker. The preset, prompts, skill layout, `AGENTS.md`, `.codex/rules/ticket-loop.rules`, and `--agent codex` are in place, but nothing has run on a machine with Codex installed: idle detection, `$implement` picking up the skill, repair prompts, and whether the rules file loads under `--dangerously-bypass-approvals-and-sandbox`.
- The source repository rsrehab/rental-portal still uses its own `scripts/orca-ticket-loop.sh`.
