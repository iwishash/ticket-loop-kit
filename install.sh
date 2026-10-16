#!/usr/bin/env bash
set -euo pipefail

# ticket-loop-kit install / update — run in the target repository root. Running it again gives the same result.
#
#   npx github:iwishash/ticket-loop-kit init           # recommended — asks for the backend, then runs this script (bin/ticket-loop-kit.js)
#   bash <(curl -fsSL https://raw.githubusercontent.com/iwishash/ticket-loop-kit/main/install.sh)
#   bash /path/to/ticket-loop-kit/install.sh          # from a local clone of the kit
#
# What it does (the part that is the same for every project):
#   0. Migrates a 0.3 or 0.2 install: git mv .agent-loop/ (or .orca-loop/) to .ticket-loop/, removes the old setup-agent-loop /
#      setup-orca-loop skill and the old .gitignore lines
#      0.7: moves skills from .claude/skills/<name> to .agents/skills/<name> and leaves a symbolic link behind (see below)
#   1. Overwrites the managed files: scripts/ticket-loop.sh, scripts/ticket-state.sh, scripts/sync-mattpocock-skills.sh,
#      .agents/skills/setup-ticket-loop/, .agents/skills/loop-triage/ (what the loop's triage session runs when it stops)
#   2. Places templates only when missing (project-owned afterwards): .agents/skills/implement and pr, .codex/rules/ticket-loop.rules
#      (default branch filled in), .ticket-loop/worker-rules.md, docs/loop-reports/README.md, docs/agents/issue-tracker.md
#      (GitHub tracker facts the vendored skills read)
#   3. Vendors the mattpocock skills the loop uses into .agents/skills/: always tdd and code-review (→ ticket-review), which the
#      implement skill calls; the planning set (grill-with-docs, to-spec, to-tickets, retro + their 3 dependencies) only with
#      --workflow-skills (default: keep what the previous install chose). Skills an earlier install vendored outside those sets
#      are kept and synced, never removed, unless --prune-skills is given. Before touching anything it checks for the same skills
#      installed another way (plugin, ~/.claude/skills, `npx skills`) and stops when two tools would fight over the same files
#   4. Adds /.ticket-loop/*.log, /.ticket-loop/*.jsonl and /.ticket-loop/stops/ to .gitignore; merges deny rules into .claude/settings.json
#      (no gh pr merge, no force push, no direct push to the default branch). The Codex counterpart is .codex/rules (step 2)
#   5. Creates the 6 GitHub labels, sets the repo-scoped git credential helper (gh), registers the repo with Orca
#   6. Records the kit commit in .ticket-loop/kit.json
# The project-specific part (verify command, orca.yaml, CI, worker rules) is done afterwards by the setup-ticket-loop skill
# (/setup-ticket-loop in Claude Code, $setup-ticket-loop in Codex).
#
# Skill layout (0.7): skills live in .agents/skills/<name>, which Codex reads, and .claude/skills/<name> is a symbolic link to it,
# which Claude Code reads (the layout `npx skills add` uses). One copy, both agents. The checks below treat a link that points at
# this repo's .agents/skills/<name> as the kit's own; a link anywhere else means another tool manages the skill.
#
# Options:
#   --ref <ref>          kit tag, branch or commit (default main)
#   --agent <name>       claude (default) | codex — the worker the loop will start. Decides which skill-conflict checks apply
#                        (plugin and ~/.claude/skills only matter for claude) and what the next steps say. The loop reads AGENT
#                        from .ticket-loop/loop.env; the npx shell writes it there, this script does not
#   --no-skills          skip the mattpocock skill sync
#   --workflow-skills    also vendor the planning skills (grill-with-docs, to-spec, to-tickets, retro + deps); --no-workflow-skills removes them
#   --force-skills       vendor even when another tool (npx skills) manages mattpocock skills in this repo
#   --prune-skills       remove skills an earlier install vendored outside the selected sets (default: keep and sync them)
#   --no-github          do not create the labels
#   --no-git-credential  leave the repo's git credential helper alone
#   --no-orca            skip registering the repo with Orca
# Environment: KIT_REPO (default iwishash/ticket-loop-kit), KIT_DIR (local kit path — skips the clone),
#              KIT_COMMIT (kit commit to record in kit.json — the npx shell passes it for a package without .git)

KIT_REPO="${KIT_REPO:-iwishash/ticket-loop-kit}"
KIT_DIR="${KIT_DIR:-}"
REF="main"
AGENT="claude"
DO_SKILLS=1
WORKFLOW_FLAG=""
FORCE_SKILLS=0
PRUNE_FLAG=""
DO_GITHUB=1
DO_CREDENTIAL=1
DO_ORCA=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --agent) AGENT="$2"; shift ;;
    --no-skills) DO_SKILLS=0 ;;
    --workflow-skills) WORKFLOW_FLAG="--workflow" ;;
    --no-workflow-skills) WORKFLOW_FLAG="--no-workflow" ;;
    --force-skills) FORCE_SKILLS=1 ;;
    --prune-skills) PRUNE_FLAG="--prune" ;;
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
case "$AGENT" in claude|codex) ;; *) die "Unknown agent $AGENT (claude | codex)." ;; esac
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this inside a git repository."
cd "$ROOT"

# ---------- 키트 받기 ----------
if [[ -z "$KIT_DIR" ]]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$self_dir" && -f "$self_dir/files/scripts/ticket-loop.sh" ]]; then
    KIT_DIR="$self_dir"
  else
    KIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ticket-loop-kit.XXXXXX")"
    trap 'rm -rf "$KIT_DIR"' EXIT
    # Public repository: plain HTTPS clone, no credentials needed. gh is a fallback for forks that are private.
    git clone -q "https://github.com/$KIT_REPO.git" "$KIT_DIR" 2>/dev/null \
      || { command -v gh >/dev/null 2>&1 && gh repo clone "$KIT_REPO" "$KIT_DIR" -- -q; } \
      || die "Could not clone $KIT_REPO. Clone it yourself and run with KIT_DIR=<path>."
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

# ---------- 스킬 충돌 검사 (아무것도 바꾸기 전에) ----------
# 같은 mattpocock 스킬이 플러그인·~/.claude/skills·`npx skills` 로 이미 있으면 알린다. Claude Code 는 중복을 경고하지 않는다.
# 다른 도구가 .claude/skills 를 관리하는 경우(차단)는 설치를 멈춘다 — 두 도구가 같은 파일을 번갈아 덮어쓰기 때문이다
if [[ $DO_SKILLS -eq 1 ]]; then
  rc=0
  bash "$KIT_DIR/files/scripts/sync-mattpocock-skills.sh" --check --agent "$AGENT" $WORKFLOW_FLAG $PRUNE_FLAG || rc=$?
  if [[ $rc -eq 3 && $FORCE_SKILLS -eq 0 ]]; then
    die "Another tool manages mattpocock skills in this repo (see above). Remove that install, or rerun with --force-skills, or skip vendoring with --no-skills."
  elif [[ $rc -ne 0 ]]; then
    warn "Skill conflicts found (above) — the vendored copies are still installed; fix the listed items so the loop runs the committed versions."
  fi
fi

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
    if git ls-files --error-unmatch ".claude/skills/$old" >/dev/null 2>&1; then git rm -rq ".claude/skills/$old"; else rm -rf ".claude/skills/$old"; fi
    say "Removed the old $old skill (replaced by setup-ticket-loop)"
  fi
done
# 옛 경로 줄과 함께 그 위에 키트가 썼던 주석 두 줄도 지운다(4단계가 새 경로와 같이 다시 쓴다). 사용자가 쓴 다른 줄은 그대로
if [[ -f .gitignore ]] && grep -qE '^/\.(agent|orca)-loop/' .gitignore; then
  tmp="$(mktemp)"
  grep -vE '^/\.(agent|orca)-loop/' .gitignore \
    | grep -vxF -e '# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다' -e '# 티켓 루프의 티켓별 기록(RECORDS_FILE) — 기계별 원자료. 스펙 리포트(docs/loop-reports/)만 커밋한다' > "$tmp" || true
  mv "$tmp" .gitignore
  say "Removed the /.agent-loop/ and /.orca-loop/ lines (and the kit's comments above them) from .gitignore"
fi

# ---------- 0'. 스킬 배치 (0.6 이하: .claude/skills/<name> 실제 디렉터리 → .agents/skills/<name> + 링크) ----------
# 키트가 놓는 스킬(관리 1개 + 템플릿 2개)만 여기서 옮긴다. 벤더링한 mattpocock 스킬은 sync-mattpocock-skills.sh 가 자기 매니페스트로 옮긴다
link_skill() {   # .claude/skills/<name> → ../../.agents/skills/<name>. 실제 디렉터리가 남아 있으면 지우고 링크를 둔다(옮긴 뒤라 사본이다)
  local n="$1" l=".claude/skills/$1"
  [[ -d ".agents/skills/$n" ]] || return 0
  if [[ -L "$l" ]]; then
    [[ "$(readlink "$l")" == "../../.agents/skills/$n" ]] && return 0
    rm "$l"
  elif [[ -d "$l" ]]; then
    if git ls-files --error-unmatch "$l" >/dev/null 2>&1; then git rm -rq "$l"; else rm -rf "$l"; fi
  fi
  mkdir -p .claude/skills
  ln -s "../../.agents/skills/$n" "$l"
}
kit_skills=()
while IFS= read -r d; do kit_skills+=("$(basename "$d")"); done < <(find "$KIT_DIR/files/.agents/skills" "$KIT_DIR/templates/.agents/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
moved=()
for n in "${kit_skills[@]}"; do
  if [[ -d ".claude/skills/$n" && ! -L ".claude/skills/$n" && ! -e ".agents/skills/$n" ]]; then
    mkdir -p .agents/skills
    if git ls-files --error-unmatch ".claude/skills/$n" >/dev/null 2>&1; then git mv ".claude/skills/$n" ".agents/skills/$n"; else mv ".claude/skills/$n" ".agents/skills/$n"; fi
    moved+=("$n")
  fi
done
[[ ${#moved[@]} -eq 0 ]] || say "Moved ${moved[*]} from .claude/skills/ to .agents/skills/ (Codex reads .agents/skills; .claude/skills keeps a link)"

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
    if [[ "$rel" == .codex/rules/* ]]; then
      sed -i.bak "s/__BASE__/${BASE}/g" "$rel" && rm -f "$rel.bak"
      echo "  added $rel (Codex command rules — default branch ${BASE} filled in)"
    elif [[ "$rel" == */agents/openai.yaml ]]; then
      echo "  added $rel (Codex skill metadata)"
    else
      echo "  added $rel (template — the setup-ticket-loop skill fills it in)"
    fi
  fi
done < <(find "$KIT_DIR/templates" -type f -print0 | sort -z)
for n in "${kit_skills[@]}"; do link_skill "$n"; done
echo "  linked .claude/skills/{$(IFS=,; echo "${kit_skills[*]}")} → .agents/skills/"

# ---------- 3. mattpocock 스킬 ----------
if [[ $DO_SKILLS -eq 1 ]]; then
  say "Syncing the mattpocock skills"
  force=""; [[ $FORCE_SKILLS -eq 1 ]] && force="--force"
  bash scripts/sync-mattpocock-skills.sh --no-check --agent "$AGENT" $WORKFLOW_FLAG $PRUNE_FLAG $force \
    || warn "Skill sync failed — run bash scripts/sync-mattpocock-skills.sh --agent ${AGENT} ${WORKFLOW_FLAG} ${PRUNE_FLAG} later"
fi

# ---------- 4. .gitignore · settings.json ----------
touch .gitignore
if ! grep -qxF '/.ticket-loop/*.log' .gitignore; then
  sep=$'\n'                                                                    # 앞 내용과 빈 줄 하나로 띄운다
  if [[ ! -s .gitignore || -z "$(tail -n1 .gitignore)" ]]; then sep=""          # 비었거나 이미 빈 줄로 끝난다
  elif [[ -n "$(tail -c1 .gitignore)" ]]; then sep=$'\n\n'; fi                  # 마지막 줄에 개행이 없다
  printf '%s# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다\n/.ticket-loop/*.log\n' "$sep" >> .gitignore
fi
grep -qxF '/.ticket-loop/*.jsonl' .gitignore || printf '# 티켓 루프의 티켓별 기록(RECORDS_FILE) — 기계별 원자료. 스펙 리포트(docs/loop-reports/)만 커밋한다\n/.ticket-loop/*.jsonl\n' >> .gitignore
grep -qxF '/.ticket-loop/stops/' .gitignore || printf '# 티켓 루프의 멈춤 기록과 수습 판정 — 기계별. /loop-triage가 읽는다\n/.ticket-loop/stops/\n' >> .gitignore

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
say "Merged deny rules into .claude/settings.json (default branch ${BASE}; Codex: .codex/rules/ticket-loop.rules)"

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
if [[ "$AGENT" == codex ]]; then
  step 1 "In Codex (or Claude Code): ${C_C}\$setup-ticket-loop${C_0} — fills in the verify command, orca.yaml, CI and worker rules for this repo and opens a PR"
  printf '     Codex as the worker is a preset that has not been verified on a real ticket yet. Trust this repo in Codex so .codex/rules applies; keep GitHub branch protection on\n'
else
  step 1 "In Claude Code: ${C_C}/setup-ticket-loop${C_0} — fills in the verify command, orca.yaml, CI and worker rules for this repo and opens a PR"
fi
if [[ $DO_ORCA -eq 1 ]]; then
  step 2 "Orca Settings → Projects → <repo> → Worktree Hooks → Advanced:"
  printf '     Command Source %s"orca.yaml only"%s, enable %s"Wait for setup to complete before starting agent"%s\n' "$C_C" "$C_0" "$C_C" "$C_0"
else
  step 2 "Open this checkout once in Claude Code and trust the folder (worktrees inherit the trust; the loop checks it at startup)"
  printf '     cmux: run the loop inside a cmux terminal. tmux: run it anywhere and watch with %stmux attach -t ticket-loop%s\n' "$C_C" "$C_0"
fi
step 3 "After the PR is merged: ${C_C}bash scripts/ticket-loop.sh --dry-run${C_0}, then ${C_C}--max 1${C_0}"
printf '\n%sChanged files:%s git status\n' "$C_D" "$C_0"
