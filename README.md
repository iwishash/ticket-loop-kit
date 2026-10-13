# ticket-loop-kit

A kit that installs and updates the **ticket loop** in other repositories: an unattended loop that implements, verifies, and merges GitHub issue tickets one at a time, each in its own worktree. The worktrees and agent terminals are handled by a backend (Orca or cmux).
The principles and operating guide are in the [Unattended Ticket Loop Guidebook](docs/ticket-loop-guide.pdf) (Korean). The original Korean version of this README is [README.ko.md](README.ko.md).

## Install

From the root of the target repository:

```bash
npx github:iwishash/ticket-loop-kit init
```

Pick the backend and install steps with the keyboard (↑↓, numbers, Space, Enter; q to abort). The wrapper then calls `install.sh` and writes a `BACKEND=` line to `.ticket-loop/loop.env`. Pass `--yes` to skip the questions (automatic when not on a terminal). Disable colors with `NO_COLOR`. If you use an SSH-alias remote or keychain credentials, `gh auth setup-git` is not needed. To pin the kit version: `npx github:iwishash/ticket-loop-kit#v0.5.1 init`. While the repository is private, get invited to it, then run `gh auth login` followed by `gh auth setup-git` once so npx can fetch it (GitHub credentials in the macOS keychain also work).

To install with bash only, without npx:

```bash
bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

Then, in Claude Code:

1. `/setup-ticket-loop` — fills in the verification commands, `orca.yaml`, CI, worker rules, and `implement` for this repository, then opens a PR

Finally, in the Orca app: Settings → Projects → <repository> → Worktree Hooks → Advanced: set Command Source to **"orca.yaml only"** and turn on **"Wait for setup to complete before starting agent"**. After merging the PR, run `bash scripts/ticket-loop.sh --dry-run`, then `--max 1`.

Required tools: `git`, `gh` (logged in), `jq`, the Orca app and CLI, Claude Code.

## Who does what

| Actor | Responsibility |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) — questions and wrapper | Backend selection, the `BACKEND=` line in `.ticket-loop/loop.env` (only when absent), toggling install steps, tool checks, passing the installed kit commit to `install.sh` |
| `install.sh` — the part that is the same in every repository | Checks for conflicting skill installs (below), installs the loop, diagnostics, and skill-sync scripts plus the `setup-ticket-loop` skill, vendors the mattpocock skills (`tdd`, `ticket-review`, and the planning set when chosen), places the `docs/agents/issue-tracker.md` template, merges `.gitignore` and `deny` entries, creates 6 labels, sets up git credentials (gh), registers with Orca, writes `.ticket-loop/kit.json` |
| `/setup-ticket-loop` — the part that requires reading the repository | Fills the `__PLACEHOLDER__`s in `implement`, `pr`, and `worker-rules.md` (verification commands, the heavy suite and the command that runs one file of it — the worker runs only the files it touched, once, right before the PR; the loop runs the full suite after merge), the `verify` command, `orca.yaml`, CI, `.ticket-loop/loop.env`, `docs/agents/ticket-loop.md`, a `CLAUDE.md` pointer → PR |
| Human | Orca app settings (Command Source "orca.yaml only"), merging the PR, watching the `--max 1` trial |

The kit's `ticket-loop.sh` is the script from Appendix D of the guidebook (3rd edition) plus two additions: reading the per-repository defaults file `.ticket-loop/loop.env`, and a port check before starting. Repository constants such as `POST_MERGE_CMD` and `POST_MERGE_PORT` go there as `VAR="${VAR:-value}"` and are committed; environment variables given at run time win.

If the repository's CI uses path filters (`paths`/`paths-ignore`) and therefore does not run on some PRs, tell the loop the same verdict with `CI_SKIP_REGEX` (a simple exclusion list) or `CI_SKIP_CMD` (a repository script that reads the file list on stdin and prints `run` or `skip`). GitHub creates no checks at all on a filtered PR, so the loop cannot tell "not up yet" from "never coming". This is not a rule the loop invents; it mirrors the repository's filter. Leave it empty when there is no filter (default: wait for checks on every PR).

After a ticket is merged and closed, and when a `--parent` run finishes, the loop counts the spec issue's sub-issues and, if all of them are closed, closes the spec issue with a comment (it counts the list, not the summary value). If any sub-issue is still open, it leaves the spec alone.

The loop leaves three things behind. The progress log `.ticket-loop/loop-MMDD.log` (for humans), the per-ticket records `.ticket-loop/tickets.jsonl` (per machine, not committed), and, when a `--parent <spec>` run exits normally, the spec report `docs/loop-reports/spec-<N>.html` (one table of status, result brief, elapsed time, and model per ticket; a human reviews it and commits it via PR). When a spec was completed in this run, the loop ends with one line suggesting a `/retro` pass and listing what to read. It is a suggestion only; the loop never runs the retrospective itself. The report's fixed text is English; issue and PR titles from GitHub and stop reasons from the records are kept verbatim. In repositories that set `POST_MERGE_PORT`, when the port is busy the loop logs the occupying process and re-checks every 30 seconds. If the port is already busy at startup, it logs one "warning" line.

## Backends

The loop script does only nine things with worktrees and agent terminals (create, remove, send a prompt, shell input, Ctrl-C, wait for idle, read the screen, set status, startup check). Each backend implements them as functions of the same names (`orca_*`, `cmux_*`), selected with `BACKEND=orca|cmux` in `.ticket-loop/loop.env`. Ticket selection, PR, CI, repair, merge, post-merge verification, records, and the spec report are shared.

| | Orca | cmux |
|---|---|---|
| Worktree | `orca worktree create` creates it and runs the `orca.yaml` setup | The loop runs `git worktree add` (`WORKTREE_DIR`, default `~/.cache/ticket-loop/<owner-repo>/worktrees`) and then `WORKTREE_SETUP_CMD` |
| Agent | Orca launches it with `--agent claude --prompt` | `cmux workspace create --cwd … --command "claude … \"$(cat promptfile)\""` — the claude shim in the workspace shell attaches the Claude Code hooks |
| Idle detection | `orca terminal wait --for tui-idle` (blocking) | Reads `lifecycle` from `cmux rpc surface.input_state` every 5 seconds (reported by Claude Code hooks) |
| Input and screen | `orca terminal send / read` | `cmux paste --submit`, `send --force` + `send-key enter`, `read-screen --lines 25`. Wakes the workspace from hibernation before sending |
| Status display | `orca worktree set --workspace-status` | `cmux workspace status set`, `cmux pr`, `cmux log` |
| Prerequisites | Orca app running, repository registered | Run inside a cmux terminal (socket mode defaults to `cmuxOnly`) |

Both backends have been verified with one real ticket each (boiler-webapp #34 on Orca, #39 on cmux). Observed with cmux 0.65: `--json` must come after the command to get JSON output (`workspace create --json --id-format uuids` → `workspace_id`, `surface_id`), lanes are `todo|working|needs-attention|review|done`, and a workspace whose process is still alive can only be closed with `workspace close --force`. The loop must be launched inside a cmux terminal: the socket mode default is `cmuxOnly`, so `cmux identify` is refused from outside.

## What goes where

| Kit path | Target repository | On install |
|---|---|---|
| `files/scripts/ticket-loop.sh` | `scripts/ticket-loop.sh` | Overwritten every time (kit-owned) |
| `files/scripts/ticket-state.sh` | `scripts/ticket-state.sh` | Overwritten every time |
| `files/scripts/sync-mattpocock-skills.sh` | `scripts/sync-mattpocock-skills.sh` | Overwritten every time |
| `files/.claude/skills/setup-ticket-loop/` | Same path | Overwritten every time |
| `templates/.claude/skills/implement/`, `pr/` | Same path | Only when absent (project-owned afterwards) |
| `templates/.ticket-loop/worker-rules.md` | Same path | Only when absent |
| `templates/docs/loop-reports/README.md` | Same path | Only when absent |
| `templates/docs/agents/issue-tracker.md` | Same path | Only when absent — GitHub tracker conventions read by the vendored skills and `implement` |
| — | `.claude/skills/tdd`, `ticket-review` (+ 7 planning skills) | Vendored by `sync-mattpocock-skills.sh` |
| — | `.gitignore` (`/.ticket-loop/*.log`, `/.ticket-loop/*.jsonl`), `deny` in `.claude/settings.json` | Lines and entries merged |
| — | 6 GitHub labels, repository git credentials (gh), Orca registration | Created when missing |
| — | `.ticket-loop/kit.json` | Records the installed kit commit |

Project-specific values live in the target repository's `.ticket-loop/loop.env` (loop defaults, including `BACKEND`), `orca.yaml` (Orca), `.ticket-loop/worker-rules.md`, and the `implement` and `pr` skills. Do not edit kit-owned files in the target repository; fix them in the kit.

## Update

Run the same install command again. Only kit-owned files and the mattpocock skills change; project-owned files (including `loop.env`) stay as they are. In repositories installed by 0.3 or earlier, the installer `git mv`s `.agent-loop/` (or `.orca-loop/` for 0.2 and earlier) to `.ticket-loop/` (logs and records included), and removes the old skills `setup-agent-loop` and `setup-orca-loop` and the old `.gitignore` lines. It then lists any files that still point at the old paths (`docs/agents/ticket-loop.md`, `CLAUDE.md`, `REPORT_DIR` in `loop.env`, etc.) so you can fix them by hand in the same PR. To pin a version: `npx github:iwishash/ticket-loop-kit#v0.5.1 init` (the bash path takes `--ref v0.3.0`). Review the changes with `git diff` and open a PR. npx caches a repository once fetched, so to re-fetch the same ref use `npx --yes --prefer-online` or `npm cache clean --force`.

Options: `--yes`, `--backend <orca|cmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). The bash path also takes `--ref <ref>` (`bash install.sh --help`).

## mattpocock skills: what is vendored, what is checked

The loop script itself does not depend on any skill. It sends `/implement N` to the worker, and that `implement` (a project-owned template) calls `tdd` and `ticket-review` through the Skill tool. So the kit vendors only two sets from upstream [mattpocock/skills](https://github.com/mattpocock/skills) (MIT) into `.claude/skills/` as files. Files rather than a plugin, because worker worktrees and cloud sessions then get the same version from a plain clone, and an automatic update cannot change behaviour in the middle of an unattended run.

| Set | Skills | Default |
|---|---|---|
| core | `tdd`, `code-review` → `ticket-review` (the name clashes with the built-in `/code-review`) | Always |
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`, plus the `grilling`, `domain-modeling`, `writing-for-agents` they call | Off. `--workflow-skills` or the interactive checklist; kept if a previous install had them |
| kept | Whatever an earlier install (0.5 and before vendored all 26) placed outside the two sets, e.g. `implement-spec`, `grill-me`, `triage` | Kept and synced with the rest; never added to a fresh install. `--prune-skills` (or the checklist item) removes them |

The other upstream skills (`ask-matt`, `wizard`, `teach`, …) are not vendored into a fresh install. Install the plugin (`claude plugin install mattpocock-skills@claude-plugins-official`) if you want them. A repo that already has them keeps them: the kit put them there, so you may be using them, and the kit keeps updating them from the same upstream commit. The manifest `.claude/skills/.mattpocock.json` lists them under `kept`. A skill you deleted by hand is not brought back, and one upstream has dropped is left as is. The only exception is `setup-matt-pocock-skills`, which is removed because `/setup-matt-pocock-skills` is no longer needed: the `docs/agents/issue-tracker.md` it used to write comes from a kit template, and `/setup-ticket-loop` writes the `## Agent skills` block in `CLAUDE.md`.

Before changing anything, the installer looks for the same skills installed another way (Claude Code does not warn about duplicates; run `bash scripts/sync-mattpocock-skills.sh --check` to see the result on its own).

| Found | What happens | Handling |
|---|---|---|
| The `mattpocock-skills` plugin enabled for this repo (`enabledPlugins`, user < project < local) | Both load: `/tdd` and `/mattpocock-skills:tdd` appear side by side | Warning. The interactive checklist offers "disable the plugin for this repo", which runs `claude plugin disable … --scope project` |
| The same skill in `~/.claude/skills/<name>` | A personal skill shadows the project skill, so the machine's copy runs instead of the committed one | Warning with the names. Remove them or accept it |
| `skills-lock.json` from `npx skills add`, or a `.claude/skills/*` symbolic link | Two tools overwrite the same directories in turn | **Install stops**. Remove with `npx skills remove` and rerun (`--force-skills` to override, `--no-skills` to skip vendoring) |
| A `.claude/skills/code-review` directory | A project skill replaces the built-in `/code-review`; the kit uses `ticket-review` | Warning with an `rm -rf` hint |
| A same-named directory not in the manifest, or `.claude/commands/<name>.md` | Overwritten / the skill wins but both remain | Notice |
| Skills an earlier install vendored outside the selected sets | Kept and synced | Notice with the names. `--prune-skills` removes them |

## Running the same repository on several computers

Once a repository is set up, a plain clone runs on another computer. Reinstall only when upgrading the kit, on one computer; the others get it with `git pull`.

- Everything the loop needs is committed: `scripts/ticket-loop.sh`, `.ticket-loop/loop.env` (including `BACKEND` and `WORKTREE_SETUP_CMD`), `worker-rules.md`, `kit.json`, and the `implement` and `pr` skills. The only per-machine files are `.ticket-loop/*.log` and `tickets.jsonl`, both in `.gitignore`. On a new computer they start empty.
- The backend may differ per computer. Values in `loop.env` are of the form `${BACKEND:-orca}`, so an environment variable given at run time wins: computer A runs `bash scripts/ticket-loop.sh N` on Orca, computer B runs `BACKEND=cmux bash scripts/ticket-loop.sh N` inside a cmux terminal. A repository that will use cmux needs `WORKTREE_SETUP_CMD` in `loop.env`.
- Each backend keeps worktrees in its own place (Orca in its configured location, cmux in `~/.cache/ticket-loop/<owner-repo>/worktrees`). Nothing is left in the repository, so computers do not collide.
- The prerequisites on a new computer are the usual ones: `gh auth login`, `claude`, `jq`, the repository's package manager. With cmux, run inside a cmux terminal (socket mode defaults to `cmuxOnly`) and make sure the Claude Code integration in Settings is on. If it is off, `lifecycle` only ever returns `unknown` and the loop times out after the startup grace period.
- When running concurrently, split the tickets. Specifying numbers gives separate branches (`issue-N-…`) that never overlap. Automatic selection skips tickets that have an assignee or an open PR, and the worker assigns itself as soon as it starts, but that does not prevent a race where two loops pick the same ticket seconds apart. If you run several loops with automatic selection, partition the scope with `--parent` or `--label`. If one side merges and the other side's PR conflicts, the loop's repair step handles it.
- The spec report (`--parent`) is drawn from that computer's `tickets.jsonl`, so the table is most complete when one spec runs on one computer. Tickets without records fall back to PR timestamps.

## Working on the kit

- After changing the loop script, regenerate Appendix D and the PDF with `python3 docs/sync-guide.py && bash docs/build-pdf.sh` (`tests/smoke.sh` checks that Appendix D matches).
- `bash tests/smoke.sh` — installs into a temporary repository (no network or GitHub), checks that installing twice gives the same result, and renders the spec report jq against fixture data.
- Record changes in `CHANGELOG.md`; the version goes in `VERSION`, `package.json`, and a tag (`tests/smoke.sh` checks that the two files agree).
- Do not add a build step such as `prepare` to `package.json`. When fetched straight from git, that script would run on the user's machine. The npx package contains only the `files` list (`bin`, `install.sh`, `files/`, `templates/`, `VERSION`); `docs/` and `tests/` are excluded.

## Verification status (0.3.0, 2026-10-12)

Verified:

- `tests/smoke.sh` passes: syntax, Appendix D match, install into a temporary repository, reinstall leaves project-owned files, `settings.json`, and `.gitignore` unchanged, spec report jq rendering (merged, stopped, and no-record cases)
- The spec report, port wait, and terminal retry code in 0.2.0 was taken verbatim from the general-purpose script (guidebook 3rd edition) that ran two real tickets (#67, #68, spec #65) in rsrehab/rental-portal. The kit adds only `loop.env` reading and the startup port check
- Install including skill sync: mattpocock 1.3.1 plus 16 unreleased changesets (`49dd158`), 26 skills; `implement` and `pr` are skipped
- The remote one-line install (`--ref v0.1.0`) fetched and installed, recording `534653a` in `.ticket-loop/kit.json`
- The npx wrapper: a copy of the kit fetched via `git+file://` installs with `--yes` and leaves the commit and `ref` (`npx#<tag>` when a `#tag` is given) in `kit.json`. The interactive paths (backend selection, per-item questions, declining cmux, Ctrl+D) were verified with a pty. `npx github:iwishash/ticket-loop-kit init --yes` and the pinned `#main` form were fetched for real from an empty npm cache (private repository, HTTPS plus keychain credentials, no SSH key), installed into a temporary repository including skill sync, and left `e707bfe` and `ref: npx` / `npx#main` in `kit.json`

- Migration of a 0.2 install: the smoke test installs into a temporary repository that has `.orca-loop/` (rules, `loop.env`, logs), the old skill, and the old `.gitignore` lines, and confirms they are moved with `git mv` and nothing is lost. Applying it to rental-portal for real is still pending

- One real ticket on the Orca backend (iwishash/boiler-webapp #34 → PR #38, 2026-10-12): after a first install (`npx … init` plus the user running `/setup-ticket-loop`), `bash scripts/ticket-loop.sh 34 --max 1` went from worktree creation → worker startup → PR → waiting on 8 CI jobs → merge → issue closed → worktree and branch cleanup → records (`tickets.jsonl`, including the model) in 10 minutes of wall-clock time. On the first attempt the loop died right after creating the worktree because of a `set -u` bug in `orca_set_status` (the worker kept going on its own); this result is from the rerun after the fix. Post-merge verification was skipped because that repository has none

- One real ticket on the cmux backend (iwishash/boiler-webapp #39 → PR #40, 2026-10-12, cmux 0.65): inside a cmux terminal, `BACKEND=cmux WORKTREE_SETUP_CMD='pnpm install --frozen-lockfile --prefer-offline' bash scripts/ticket-loop.sh 39 --max 1` went from `git worktree add` → pnpm install → `cmux workspace create --command "claude …"` → idle detection via the hook-reported `lifecycle` → PR → 8 CI jobs → merge → `workspace close --force`, worktree, and branch cleanup → records in 7 minutes of wall-clock time (0 repairs, 0 idle false positives). The lane followed working → review → done. Two of the draft's assumptions were wrong and were fixed (`--json` placement and `close --force`); the rest (JSON field names, lane names, uuid, hook injection) were right

Not yet verified — check in the first repository that adopts the kit and update this section:

- `/setup-ticket-loop` was run once by the user on boiler-webapp (the resulting PR was merged). No feedback yet on question order or missing items
- The label creation and Orca registration steps of `install.sh` were turned off in testing. The commands themselves are the ones used in rsrehab/rental-portal
- The kit's `ticket-loop.sh` paths for `POST_MERGE_CMD`, `POST_MERGE_PORT`, `CI_SKIP_CMD`, `CI_SKIP_REGEX`, and the repair prompt. The one boiler-webapp ticket had no post-merge verification, no CI path filter, and 0 repairs. Running a real ticket in rental-portal (switched in PR #82, with `CI_SKIP_CMD` and `POST_MERGE_CMD` configured) will confirm them
- The cmux backend as a whole beyond that one ticket. Only `--dry-run` failing with a socket error outside a cmux terminal has been confirmed
- The source repository rsrehab/rental-portal still uses its repository-specific `scripts/orca-ticket-loop.sh` (not switched to the kit)
- Codex as the worker. `AGENT=codex` in `loop.env` is a preset only: it switches the launch command (`codex --dangerously-bypass-approvals-and-sandbox`), the banner and model regexes, and the skill prefix (`$implement N`), and the worker/repair prompts no longer name Claude Code tools. But the skills still live only in `.claude/skills/`, which Codex does not read (`.agents/skills/` + `AGENTS.md` placement is the next step), and idle detection, `$implement`, and repair prompts have not been run on a machine with Codex installed. Not "supported" until that happens
