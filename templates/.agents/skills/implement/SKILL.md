---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

<!-- Project-owned: scripts/sync-mattpocock-skills.sh skips this skill. Seeded by ticket-loop-kit from upstream mattpocock/skills `implement`; the setup-ticket-loop skill filled the __PLACEHOLDERS__. When upstream changes it, port the change here by hand. Lives in .agents/skills/ (read by Codex; .claude/skills/implement is a symbolic link to it for Claude Code). -->

"Use the X skill" below means: in Claude Code, call the Skill tool with "X"; in Codex, read `.agents/skills/X/SKILL.md` (the same as `$X`) and follow it.

Implement the work described by the user in the spec or tickets. The tracker is described in `docs/agents/issue-tracker.md`.

If the user passes only a number `N`, it is GitHub issue #N. Run `gh issue view N --json number,title,body,labels,state,comments` and state its title back. Stop if it is closed, or labelled `needs-info`, `ready-for-human` or `wontfix`. If the issue is a sub-issue, read the parent spec too.

Before starting, check the issue has no open blockers: count the open ones in the blocker list (`gh api repos/{owner}/{repo}/issues/N/dependencies/blocked_by --jq '[.[] | select(.state == "open")] | length'` is `0`). Do not use `issue_dependencies_summary.blocked_by`: it keeps an old count for a while after a blocker closes. If it has open blockers, stop and name them.

Create the branch from the remote tip, never by checking out `__BASE__` (another worktree may hold it): `git fetch origin && git checkout -b issue-<N>-<slug> origin/__BASE__`. Assign the issue to yourself (`gh issue edit N --add-assignee @me`).

Read `GLOSSARY.md` and the ADRs in `docs/adr/` that touch the area, and use the glossary's terms in code, tests and the PR.

Use the `tdd` skill where possible. Do not ask the user to confirm the seams: this overrides the confirmation step in `tdd`. Choose the seams yourself from the ticket's acceptance criteria and the existing tests around the code you touch, then proceed. List the seams you tested in the pull request body.

While working, run only `__TYPECHECK__` and single test files (`__TEST_FILE__`). Run the full bundle `__VERIFY__` exactly twice: once right before the first commit and once right before the review-fix commit.

Heavy tests (__HEAVY_TESTS__) are not part of the bundle and you never run the whole suite: the loop runs it on the base branch after merge. If this ticket adds or changes any of those test files, run only those files once, right before opening the pull request, with `__HEAVY_TEST_FILE__`, and put the files and the result in the pull request body's Verification section. If you touched none, say so there.

__MIGRATION_RULE__

Commit your work to the issue branch, mentioning `#N` in the commit message. Then use the `ticket-review` skill, with `origin/__BASE__` as the fixed point and issue #N as the spec. Fix every hard violation and every Spec finding in a follow-up commit; list the remaining judgement calls in the pull request body.

Push the branch and open a pull request into `__BASE__` with `gh pr create --base __BASE__`. Use the `pr` skill for the body's shape. Tick the met acceptance criteria in the issue body and add the `in-review` label to the issue. Do not merge the pull request.
