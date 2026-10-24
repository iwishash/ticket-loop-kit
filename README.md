> [!NOTE]
> Built for one person's repositories and changed often. Pin a version tag (`npx github:iwishash/ticket-loop-kit#vX.Y.Z init`) if you depend on it.

<div align="center">

# ticket-loop-kit

**Hand a spec's tickets to coding agents, come back to merged PRs.**

An unattended loop that takes GitHub issue tickets one at a time — fresh worktree, agent, PR, CI, repair, merge — installed into any repository with one command.

[![Version](https://img.shields.io/github/v/tag/iwishash/ticket-loop-kit?sort=semver&style=flat-square&label=version)](CHANGELOG.md)
[![smoke](https://img.shields.io/github/actions/workflow/status/iwishash/ticket-loop-kit/smoke.yml?branch=main&style=flat-square&label=smoke)](https://github.com/iwishash/ticket-loop-kit/actions/workflows/smoke.yml)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square)](#constraints)

[**Install**](docs/install.md) · [**Running the loop**](docs/loop.md) · [**When it stops**](docs/stops.md) · [**Verification**](docs/verification.md) · [**한국어**](README.ko.md)

```sh
npx github:iwishash/ticket-loop-kit init
```

</div>

---

## Why

Splitting a spec into a dozen tickets is the easy part. Getting an agent through each one is babysitting: open a worktree, start the agent, wait for the PR, rerun CI, merge, pull, run the slow tests, start the next — and notice when something broke while you were away.

The ticket loop does the babysitting. Label tickets `ready-for-agent` (or file them as sub-issues of a spec), run one command, and each ticket goes worktree → agent → PR → CI → merge → cleanup before the next one starts. When something stops it, the loop tries to fix it first, then tells you.

## What you get

| | |
|---|---|
| **One ticket, one fresh worktree** | Each ticket starts from the latest default branch with an empty agent context, so nothing leaks between tickets and each one builds on the merges before it. |
| **Skills, not baked-in prompts** | The worker runs `/implement N`, a skill committed in your repository that calls `tdd` → `ticket-review` → `pr` (vendored from [mattpocock/skills](https://github.com/mattpocock/skills) and pinned). To change how workers work, change the skill in a PR. |
| **Through to the default branch** | The loop waits for CI, sends conflicts and failures back to the same worker, merges, and closes the spec when its last ticket closes. Slow suites run on the default branch every few merges, with an optional retry for flakes and a bisect to the merge that broke them. |
| **Stops that fix themselves** | A failed post-merge check, CI out of repairs, or a broken worktree setup starts a triage agent that opens a fix PR; when it lands, the loop resumes where it stopped. |
| **Stops you hear about** | Slack on start, each ticket, stop, and finish; a comment and `loop-stopped` label on the issue; a stop record any agent session can pick up with `/loop-triage`. |
| **GitHub is the only state** | Labels, assignees, and PRs. No server or database: a plain clone runs the loop on another computer. |
| **A report per spec** | A `--parent <spec>` run ends with an HTML report: result, CI and check times, and model per ticket, plus what still needs a human. |

## Supported

"Verified" means one real ticket went end to end.

| | Verified | Wired, not verified | Not supported |
|---|---|---|---|
| Worker agent | Claude Code | Codex CLI | |
| Backend (worktrees, terminals) | Orca 1.4 · cmux 0.65 · tmux 3.8 | | |
| OS | macOS | Linux, WSL | native Windows |
| Issue tracker | GitHub Issues | | others |

Needs `git`, `gh` (logged in), `jq`, and bash; Node ≥ 18 for `npx … init` only. tmux runs inside any terminal app or over SSH.

## Install

From the root of the target repository:

```sh
npx github:iwishash/ticket-loop-kit init
# without Node:
bash <(curl -fsSL https://raw.githubusercontent.com/iwishash/ticket-loop-kit/main/install.sh)
```

The installer asks for the backend and install steps (`--yes` takes the defaults). Then:

1. Run `/setup-ticket-loop` in Claude Code (`$setup-ticket-loop` in Codex). It reads the repository, fills in the verification commands, `orca.yaml`, CI, worker rules, and `loop.env`, and opens a PR.
2. Orca only: Settings → Projects → <repository> → Worktree Hooks → Advanced: set Command Source to **"orca.yaml only"** and turn on **"Wait for setup to complete before starting agent"**.
3. Merge the PR.

To update, run the install command again. Kit-owned files are refreshed; `loop.env` and project-owned skills stay as they are. → [Install and update](docs/install.md)

## Usage

```sh
bash scripts/ticket-loop.sh --dry-run      # list the tickets it would take
bash scripts/ticket-loop.sh --max 1        # one ticket — do this first
bash scripts/ticket-loop.sh                # every ready ticket
bash scripts/ticket-loop.sh --parent 40    # the sub-issues of spec #40, then the spec report
bash scripts/ticket-loop.sh 12 15          # these tickets, in this order
```

Also `--label <label>`, `--no-merge` (stop at green CI), `--skip-post-merge`, `--help`.

A ticket is ready when it is open, labelled `ready-for-agent`, unassigned, not blocked by an open issue, and has no open PR. Settings live in `.ticket-loop/loop.env` (committed; environment variables override it); per-machine secrets such as the Slack webhook go in `~/.config/ticket-loop/loop.env`. The optional planning skills (`/grill-with-docs`, `/to-spec`, `/to-tickets`, `/retro`) turn an idea into a spec issue with ticket sub-issues, and look back once it has run.

→ [Running the loop](docs/loop.md) · [When the loop stops](docs/stops.md)

## Constraints

- **Workers run without permission prompts.** Your real guard against a bad merge or force push is GitHub branch protection; the kit's `deny` rules are a second line.
- **One loop per repository, one ticket at a time.** Loops on several computers need disjoint tickets (`--parent`, `--label`, or explicit numbers).
- **Changes reach workers only after they merge.** Every ticket starts from the default branch, so edits to skills, worker rules, or `AGENTS.md`/`CLAUDE.md` count once merged.
- **Workers don't run heavy suites.** Integration and E2E tests run on the default branch every `POST_MERGE_EVERY` merges (default 4), so a regression surfaces a few merges late and is then bisected.
- **GitHub Issues only.** Another tracker means rewriting ticket selection, PR, and merge.
- **macOS only, so far.** Linux and WSL code paths have never run; native Windows is not supported. Codex as the worker has not run on a real ticket. → [Verification](docs/verification.md)

## Documentation

| | |
|---|---|
| [Install and update](docs/install.md) | What the installer and `/setup-ticket-loop` write, where files go, options, vendored skills and conflict checks, several computers |
| [Running the loop](docs/loop.md) | Settings worth knowing (post-merge checks, retries, batching, screen classification), outputs, backends |
| [When the loop stops](docs/stops.md) | Slack and GitHub notifications, triage sessions, stop records |
| [Verification](docs/verification.md) | What ran on real tickets, and what has not |
| [Working on the kit](CONTRIBUTING.md) | Tests, guidebook sync, releases |

## License

[MIT](LICENSE). Vendored skills come from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT).
