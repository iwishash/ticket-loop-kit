# Issue tracker: GitHub

<!-- Project-owned. Seeded by ticket-loop-kit from mattpocock/skills (setup-matt-pocock-skills/issue-tracker-github.md, MIT). The vendored skills (ticket-review, to-tickets, to-spec) and the project's implement skill read this file through the "## Agent skills" block in CLAUDE.md. Edit freely; the installer never overwrites it. -->

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --json number,title,body,labels,comments`.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Make an issue a sub-issue of a parent**: `gh issue create --parent <parent> ...`, or `gh issue edit <parent> --add-sub-issue <child>` afterwards (`gh` 2.94+). Older `gh`: `gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>` (database id: `gh api repos/<owner>/<repo>/issues/<n> --jq .id`). Without sub-issues, put `Part of #<parent>` at the top of the child body.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Infer the repo from `git remote -v`; `gh` does this automatically when run inside a clone.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Triage labels

The label strings equal the role names: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. The ticket loop adds `in-review` (PR open). The installer creates all six.

## Ticket loop conventions

- A milestone is one spec issue plus sub-issue tickets titled `T<NN>: …`.
- Each ticket gets a branch `issue-<N>-<slug>` from the latest default branch.
- The PR body starts with `Closes #<N>`. Opening the PR adds the `in-review` label to the issue.
- Blocking edges use GitHub's native issue dependencies (blocked by). To decide whether a ticket can start, count the **open** issues in `gh api repos/{owner}/{repo}/issues/<N>/dependencies/blocked_by`; the summary value `issue_dependencies_summary.blocked_by` lags behind after a blocker is closed.
- The implementation procedure itself lives in `.claude/skills/implement/SKILL.md`; this file holds only facts about the tracker.
