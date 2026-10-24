# Running the loop

[README](../README.md) · [한국어](loop.ko.md)

## Settings and behaviour worth knowing

- `ticket-loop.sh` is Appendix D of [the guidebook](ticket-loop-guide.pdf) plus two additions: `.ticket-loop/loop.env` (committed defaults written as `VAR="${VAR:-value}"`; run-time environment wins) and a startup port check.
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
