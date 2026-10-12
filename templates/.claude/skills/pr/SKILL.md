---
name: pr
description: "Use when writing a PR body."
---

<!-- Project-owned: scripts/sync-mattpocock-skills.sh skips this skill. Seeded by agent-loop-kit. Upstream `pr` is a summary + evidence + merge-danger template for human-driven PRs; ticket PRs are read afterwards for acceptance, seams, gaps and judgement calls, so the body is fixed to that shape. -->

Write the PR body in __PR_LANGUAGE__, in this order. Skip no section; write "none" (or its equivalent in that language) when a section is empty. Use the glossary's terms (`GLOSSARY.md`).

```markdown
Closes #N

## Acceptance criteria
- [x] <the issue's acceptance criteria verbatim, checked only when met>
- [ ] <what is not met, and why>

## Seams tested
- `<test file>` — <what it pins, in one line>

## Verification
- `__VERIFY__` <result>, migration <applied / none>

## Not verified
- <e.g. E2E not run — the loop runs it after merge / no manual browser check>

## Remaining judgement calls
- <what the review left as a judgement call, interpretations the spec did not settle>
```

Translate the headings into __PR_LANGUAGE__. Add one more section, `## Rollback`, only when the change is a one-way door (schema data change, auth or session behaviour, money, production config): say what reverting the PR cannot undo and what to do instead.

Keep each bullet to one or two sentences. Put evidence (test counts, measured sizes) on its own line. No screenshots unless the ticket is visual, and then one small one.
