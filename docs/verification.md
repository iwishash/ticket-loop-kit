# Verification status

[README](../README.md) · [한국어](verification.ko.md)

Verified with one real ticket per backend (details in [CHANGELOG.md](../CHANGELOG.md)):

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
- The environment the check commands get (`TICKET_LOOP_POST_MERGE_WHY`, `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`, 0.9.17) on a real loop, especially a rerun after a failed spec-end check and a documentation PR that completes a spec (`tests/smoke.sh` covers them with fake commands and structural checks).
- `POST_MERGE_PORT`, `POST_MERGE_RETRY_CMD`, `CI_SKIP_CMD`, `CI_SKIP_REGEX`, and the repair prompt on a real ticket (`POST_MERGE_CMD` ran in the triage runs above; every run had 0 repairs). rental-portal (PR #82) has them configured.
- The label creation and Orca registration steps of `install.sh` (turned off in testing).
- `/setup-ticket-loop` beyond one run on boiler-webapp.
- Linux and WSL. The Linux branches have never executed; try the tmux backend inside WSL first. Orca driven from WSL through `orca-ide` is an open question (Windows app vs. Linux AppImage under WSLg, path mapping).
- Triage: a flake verdict, a loop-bug verdict with a kit bug report, no verdict (timeout or idle), and a conflict (rather than a CI failure) left to triage. `tests/smoke.sh` covers them with fake backends and `gh`.
- Codex as the worker. The preset, prompts, skill layout, `AGENTS.md`, `.codex/rules/ticket-loop.rules`, and `--agent codex` are in place, but nothing has run on a machine with Codex installed: idle detection, `$implement` picking up the skill, repair prompts, and whether the rules file loads under `--dangerously-bypass-approvals-and-sandbox`.
- The source repository rsrehab/rental-portal still uses its own `scripts/orca-ticket-loop.sh`.
- Of the stop paths, two signals (SIGHUP and SIGTERM) and `die` (the triage `halt` above) ran for real. `set -e`, Ctrl-C and SIGPIPE were checked by the smoke test (fake `gh` and `curl`) and by pty and `tee` experiments.
