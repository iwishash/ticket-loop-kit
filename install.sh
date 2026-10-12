#!/usr/bin/env bash
set -euo pipefail

# ticket-loop-kit install / update — run in the target repository root. Running it again gives the same result.
#
#   npx github:iwishash/ticket-loop-kit init           # recommended — asks for the backend, then runs this script (bin/ticket-loop-kit.js)
#   bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
#   bash /path/to/ticket-loop-kit/install.sh          # from a local clone of the kit
#
# What it does (the part that is the same for every project):
#   0. Migrates a 0.3 or 0.2 install: git mv .agent-loop/ (or .orca-loop/) to .ticket-loop/, removes the old setup-agent-loop /
#      setup-orca-loop skill and the old .gitignore lines
#   1. Overwrites the managed files: scripts/ticket-loop.sh, scripts/ticket-state.sh, scripts/sync-mattpocock-skills.sh,
#      .claude/skills/setup-ticket-loop/
#   2. Places templates only when missing (project-owned afterwards): .claude/skills/implement and pr, .ticket-loop/worker-rules.md,
#      docs/loop-reports/README.md
#   3. Vendors the mattpocock skills into .claude/skills/ (code-review → ticket-review)
#   4. Adds /.ticket-loop/*.log and /.ticket-loop/*.jsonl to .gitignore; merges deny rules into .claude/settings.json
#      (no gh pr merge, no force push, no direct push to the default branch)
#   5. Creates the 6 GitHub labels, sets the repo-scoped git credential helper (gh), registers the repo with Orca
#   6. Records the kit commit in .ticket-loop/kit.json
# The project-specific part (verify command, orca.yaml, CI, worker rules) is done afterwards by /setup-ticket-loop in Claude Code.
#
# Options:
#   --ref <ref>          kit tag, branch or commit (default main)
#   --no-skills          skip the mattpocock skill sync
#   --no-github          do not create the labels
#   --no-git-credential  leave the repo's git credential helper alone
#   --no-orca            skip registering the repo with Orca
# Environment: KIT_REPO (default iwishash/ticket-loop-kit), KIT_DIR (local kit path — skips the clone),
#              KIT_COMMIT (kit commit to record in kit.json — the npx shell passes it for a package without .git)

KIT_REPO="${KIT_REPO:-iwishash/ticket-loop-kit}"
KIT_DIR="${KIT_DIR:-}"
REF="main"
DO_SKILLS=1
DO_GITHUB=1
DO_CREDENTIAL=1
DO_ORCA=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --no-skills) DO_SKILLS=0 ;;
    --no-github) DO_GITHUB=0 ;;
    --no-git-credential) DO_CREDENTIAL=0 ;;
    --no-orca) DO_ORCA=0 ;;
    --help|-h) awk 'NR > 2 && /^#/ { on = 1; sub(/^# ?/, ""); print; next } on { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# 색 — 터미널일 때만, NO_COLOR(https://no-color.org)·TERM=dumb 이면 끈다
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else
  C_B=""; C_D=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""
fi
say() { printf '%s▸%s %s%s%s\n' "$C_G" "$C_0" "$C_B" "$*" "$C_0"; }
warn() { printf '%s! %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die() { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

for tool in git jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed."; done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this inside a git repository."
cd "$ROOT"

# ---------- 키트 받기 ----------
if [[ -z "$KIT_DIR" ]]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$self_dir" && -f "$self_dir/files/scripts/ticket-loop.sh" ]]; then
    KIT_DIR="$self_dir"
  else
    command -v gh >/dev/null 2>&1 || die "gh is not installed. Clone the kit and run with KIT_DIR=<path>."
    KIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ticket-loop-kit.XXXXXX")"
    trap 'rm -rf "$KIT_DIR"' EXIT
    gh repo clone "$KIT_REPO" "$KIT_DIR" -- -q || die "Could not clone $KIT_REPO (check gh auth status)."
    git -C "$KIT_DIR" checkout -q "$REF" || die "Kit ref $REF does not exist."
  fi
fi
[[ -f "$KIT_DIR/files/scripts/ticket-loop.sh" ]] || die "Not a kit directory: $KIT_DIR"
KIT_COMMIT="${KIT_COMMIT:-$(git -C "$KIT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
KIT_VERSION="$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)"
say "ticket-loop-kit ${KIT_VERSION} (${KIT_COMMIT:0:7}) → ${ROOT}"

# 기본 브랜치: origin/HEAD → gh → main
BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [[ -z "$BASE" ]] && command -v gh >/dev/null 2>&1; then
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi
BASE="${BASE:-main}"

# ---------- 0. 옛 경로 마이그레이션 (0.3 이하: .agent-loop/ · setup-agent-loop, 0.2 이하: .orca-loop/ · setup-orca-loop) ----------
for old in .agent-loop .orca-loop; do
  [[ -d "$old" ]] || continue
  if [[ ! -e .ticket-loop ]]; then
    if git ls-files --error-unmatch "$old" >/dev/null 2>&1; then git mv "$old" .ticket-loop; else mv "$old" .ticket-loop; fi
    say "Moved ${old}/ to .ticket-loop/ (logs and records included)"
  else
    warn "Both ${old}/ and .ticket-loop/ exist — using .ticket-loop/ and leaving ${old}/ alone. Merge them and delete ${old}/."
  fi
done
for old in setup-agent-loop setup-orca-loop; do
  if [[ -d ".claude/skills/$old" ]]; then
    rm -rf ".claude/skills/$old"
    say "Removed the old $old skill (replaced by setup-ticket-loop)"
  fi
done
if [[ -f .gitignore ]] && grep -qE '^/\.(agent|orca)-loop/' .gitignore; then
  tmp="$(mktemp)"; grep -vE '^/\.(agent|orca)-loop/' .gitignore > "$tmp" || true; mv "$tmp" .gitignore
  say "Removed the /.agent-loop/ and /.orca-loop/ lines from .gitignore"
fi

# ---------- 1. 관리 파일 (매번 덮어쓴다) ----------
managed=()
while IFS= read -r -d '' f; do
  rel="${f#"$KIT_DIR/files/"}"
  mkdir -p "$(dirname "$rel")"
  cp "$f" "$rel"
  [[ "$rel" != *.sh ]] || chmod +x "$rel"
  managed+=("$rel")
done < <(find "$KIT_DIR/files" -type f -print0 | sort -z)
say "Updated ${#managed[@]} managed files"

# ---------- 2. 템플릿 (없을 때만) ----------
while IFS= read -r -d '' f; do
  rel="${f#"$KIT_DIR/templates/"}"
  if [[ -e "$rel" ]]; then
    echo "  kept  $rel (project-owned)"
  else
    mkdir -p "$(dirname "$rel")"
    cp "$f" "$rel"
    echo "  added $rel (template — /setup-ticket-loop fills it in)"
  fi
done < <(find "$KIT_DIR/templates" -type f -print0 | sort -z)

# ---------- 3. mattpocock 스킬 ----------
if [[ $DO_SKILLS -eq 1 ]]; then
  if command -v rsync >/dev/null 2>&1; then
    say "Syncing the mattpocock skills"
    bash scripts/sync-mattpocock-skills.sh || warn "Skill sync failed — run bash scripts/sync-mattpocock-skills.sh later"
  else
    warn "rsync is not installed — skipping the skill sync."
  fi
fi

# ---------- 4. .gitignore · settings.json ----------
touch .gitignore
grep -qxF '/.ticket-loop/*.log' .gitignore || printf '\n# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다\n/.ticket-loop/*.log\n' >> .gitignore
grep -qxF '/.ticket-loop/*.jsonl' .gitignore || printf '# 티켓 루프의 티켓별 기록(RECORDS_FILE) — 기계별 원자료. 스펙 리포트(docs/loop-reports/)만 커밋한다\n/.ticket-loop/*.jsonl\n' >> .gitignore

mkdir -p .claude
[[ -f .claude/settings.json ]] || echo '{}' > .claude/settings.json
tmp="$(mktemp)"
jq --arg base "$BASE" '
  .permissions.deny = ((.permissions.deny // []) + [
    "Bash(gh pr merge:*)",
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
    ("Bash(git push origin " + $base + ":*)")
  ] | unique)' .claude/settings.json > "$tmp" && mv "$tmp" .claude/settings.json
say "Merged deny rules into .claude/settings.json (default branch ${BASE})"

# ---------- 5. GitHub · git · Orca ----------
OWNER_REPO=""
if command -v gh >/dev/null 2>&1; then
  OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

if [[ $DO_GITHUB -eq 1 ]]; then
  if [[ -n "$OWNER_REPO" ]]; then
    gh label create ready-for-agent --color 0E8A16 --description "에이전트가 바로 구현 가능" --force >/dev/null
    gh label create ready-for-human --color FBCA04 --description "사람이 구현" --force >/dev/null
    gh label create needs-info      --color D93F0B --description "정보 부족" --force >/dev/null
    gh label create needs-triage    --color C5DEF5 --description "분류 필요" --force >/dev/null
    gh label create wontfix         --color FFFFFF --description "하지 않음" --force >/dev/null
    gh label create in-review       --color 5319E7 --description "PR 열림" --force >/dev/null
    say "GitHub labels: 6 ensured (${OWNER_REPO})"
  else
    warn "Could not resolve the GitHub repository — skipping labels (gh repo view failed)."
  fi
fi

# 무인 세션의 git push가 키체인 확인 창을 기다리며 멈추지 않게, 이 저장소에서는 gh 토큰만 쓴다
# (빈 값으로 상위 설정의 helper 목록을 비운 뒤 gh를 넣는다. 워크트리가 이 설정을 공유한다)
if [[ $DO_CREDENTIAL -eq 1 ]] && command -v gh >/dev/null 2>&1; then
  if ! git config --local --get-all credential.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
    git config --local --unset-all credential.helper 2>/dev/null || true
    git config --local --add credential.helper ''
    git config --local --add credential.helper '!gh auth git-credential'
    say "git credential: this repo now uses the gh token (undo: git config --local --unset-all credential.helper)"
  fi
fi

if [[ $DO_ORCA -eq 1 ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then ORCA_CLI="${ORCA_CLI:-orca-ide}"; else ORCA_CLI="${ORCA_CLI:-orca}"; fi
  if ! command -v "$ORCA_CLI" >/dev/null 2>&1; then
    warn "Orca CLI ($ORCA_CLI) not found — skipping registration (Orca Settings → General → Orca CLI)."
  elif [[ -n "$OWNER_REPO" ]]; then
    if "$ORCA_CLI" repo list --json 2>/dev/null | jq -e --arg suffix "/${OWNER_REPO}" \
         '.result.repos[] | select((.gitRemoteIdentity.canonicalKey // "") | endswith($suffix))' >/dev/null 2>&1; then   # 호스트 별칭(github.com-<계정>)도 맞게
      echo "  Orca: already registered"
    elif "$ORCA_CLI" repo add --path "$ROOT" --json >/dev/null 2>&1; then
      say "Registered the repo with Orca"
    else
      warn "Orca registration failed — start the Orca app, then run '$ORCA_CLI repo add --path $ROOT --json'"
    fi
  fi
fi

# ---------- 6. 매니페스트 ----------
mkdir -p .ticket-loop
jq -n --arg repo "$KIT_REPO" --arg ref "$REF" --arg commit "$KIT_COMMIT" --arg version "$KIT_VERSION" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson managed "$(printf '%s\n' "${managed[@]}" | jq -R . | jq -s .)" \
  '{kit: $repo, ref: $ref, commit: $commit, version: $version, installed_at: $at, managed: $managed}' > .ticket-loop/kit.json

# 추적 파일과 무시되지 않은 새 파일만 본다(로그·node_modules 같은 무시 대상은 제외). 주석에 남은 옛 이름도 잡힌다 — 손으로 고친다
stale="$(git ls-files -co --exclude-standard -z 2>/dev/null | xargs -0 grep -l -e '\.agent-loop' -e 'setup-agent-loop' -e '\.orca-loop' -e 'setup-orca-loop' 2>/dev/null | grep -v '^\.ticket-loop/kit\.json$' || true)"
[[ -z "$stale" ]] || warn "These files still point at the old paths (.agent-loop / setup-agent-loop, or .orca-loop / setup-orca-loop) — change them to .ticket-loop / setup-ticket-loop:
$(printf '  %s\n' $stale)"

step() { printf '  %s%s.%s %s\n' "$C_C" "$1" "$C_0" "$2"; }
printf '\n%sNext steps%s\n' "$C_B" "$C_0"
step 1 "In Claude Code: ${C_C}/setup-matt-pocock-skills${C_0} ${C_D}(if docs/agents/issue-tracker.md does not exist yet)${C_0}"
step 2 "In Claude Code: ${C_C}/setup-ticket-loop${C_0} — fills in the verify command, orca.yaml, CI and worker rules for this repo and opens a PR"
step 3 "Orca Settings → Projects → <repo> → Worktree Hooks → Advanced:"
printf '     Command Source %s"orca.yaml only"%s, enable %s"Wait for setup to complete before starting agent"%s\n' "$C_C" "$C_0" "$C_C" "$C_0"
step 4 "After the PR is merged: ${C_C}bash scripts/ticket-loop.sh --dry-run${C_0}, then ${C_C}--max 1${C_0}"
printf '\n%sChanged files:%s git status\n' "$C_D" "$C_0"
