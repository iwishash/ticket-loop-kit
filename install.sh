#!/usr/bin/env bash
set -euo pipefail

# agent-loop-kit 설치·업데이트 — 대상 저장소 루트에서 실행한다. 여러 번 실행해도 결과가 같다.
#
#   npx github:iwishash/agent-loop-kit init           # 권장 — 백엔드를 묻고 이 스크립트를 부른다 (bin/agent-loop-kit.js)
#   bash <(gh api repos/iwishash/agent-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
#   bash /path/to/agent-loop-kit/install.sh          # 키트를 clone해 둔 경우
#
# 하는 일(프로젝트마다 똑같은 부분):
#   1. 관리 파일을 덮어쓴다: scripts/ticket-loop.sh, scripts/ticket-state.sh, scripts/sync-mattpocock-skills.sh,
#      .claude/skills/setup-orca-loop/
#   2. 템플릿은 없을 때만 놓는다(이후 프로젝트 소유): .claude/skills/implement·pr, .orca-loop/worker-rules.md,
#      docs/loop-reports/README.md
#   3. mattpocock 스킬을 .claude/skills/에 벤더링한다(code-review → ticket-review)
#   4. .gitignore에 /.orca-loop/*.log·/.orca-loop/*.jsonl, .claude/settings.json deny에 병합·강제 push·기본 브랜치 직접 push 차단
#   5. GitHub 라벨 6개, 저장소 범위 git 자격 증명(gh), Orca 저장소 등록
#   6. .orca-loop/kit.json에 키트 커밋을 남긴다
# 프로젝트를 읽어야 정하는 부분(검증 명령, orca.yaml, CI, 워커 규칙)은 설치 뒤 Claude Code에서 /setup-orca-loop가 한다.
#
# 옵션:
#   --ref <ref>          키트의 태그·브랜치·커밋 (기본 main)
#   --no-skills          mattpocock 스킬 동기화를 건너뛴다
#   --no-github          라벨을 만들지 않는다
#   --no-git-credential  저장소 git 자격 증명을 바꾸지 않는다
#   --no-orca            Orca 저장소 등록을 건너뛴다
# 환경변수: KIT_REPO (기본 iwishash/agent-loop-kit), KIT_DIR (키트 로컬 경로 — 주면 clone하지 않는다),
#          KIT_COMMIT (kit.json에 남길 키트 커밋 — npx 껍질이 .git 없는 패키지에서 넘겨 준다)

KIT_REPO="${KIT_REPO:-iwishash/agent-loop-kit}"
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

say() { printf '\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

for tool in git jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool 이(가) 없습니다."; done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "git 저장소 안에서 실행하세요."
cd "$ROOT"

# ---------- 키트 받기 ----------
if [[ -z "$KIT_DIR" ]]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$self_dir" && -f "$self_dir/files/scripts/ticket-loop.sh" ]]; then
    KIT_DIR="$self_dir"
  else
    command -v gh >/dev/null 2>&1 || die "gh가 없습니다. 키트를 clone한 뒤 KIT_DIR=<경로>로 실행하세요."
    KIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-kit.XXXXXX")"
    trap 'rm -rf "$KIT_DIR"' EXIT
    gh repo clone "$KIT_REPO" "$KIT_DIR" -- -q || die "$KIT_REPO 를 받지 못했습니다 (gh auth status 확인)."
    git -C "$KIT_DIR" checkout -q "$REF" || die "키트 ref $REF 가 없습니다."
  fi
fi
[[ -f "$KIT_DIR/files/scripts/ticket-loop.sh" ]] || die "키트 경로가 올바르지 않습니다: $KIT_DIR"
KIT_COMMIT="${KIT_COMMIT:-$(git -C "$KIT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
KIT_VERSION="$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)"
say "agent-loop-kit ${KIT_VERSION} (${KIT_COMMIT:0:7}) → ${ROOT}"

# 기본 브랜치: origin/HEAD → gh → main
BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [[ -z "$BASE" ]] && command -v gh >/dev/null 2>&1; then
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi
BASE="${BASE:-main}"

# ---------- 1. 관리 파일 (매번 덮어쓴다) ----------
managed=()
while IFS= read -r -d '' f; do
  rel="${f#"$KIT_DIR/files/"}"
  mkdir -p "$(dirname "$rel")"
  cp "$f" "$rel"
  [[ "$rel" != *.sh ]] || chmod +x "$rel"
  managed+=("$rel")
done < <(find "$KIT_DIR/files" -type f -print0 | sort -z)
say "관리 파일 ${#managed[@]}개 갱신"

# ---------- 2. 템플릿 (없을 때만) ----------
while IFS= read -r -d '' f; do
  rel="${f#"$KIT_DIR/templates/"}"
  if [[ -e "$rel" ]]; then
    echo "  유지 $rel (프로젝트 소유)"
  else
    mkdir -p "$(dirname "$rel")"
    cp "$f" "$rel"
    echo "  추가 $rel (템플릿 — /setup-orca-loop가 채운다)"
  fi
done < <(find "$KIT_DIR/templates" -type f -print0 | sort -z)

# ---------- 3. mattpocock 스킬 ----------
if [[ $DO_SKILLS -eq 1 ]]; then
  if command -v rsync >/dev/null 2>&1; then
    say "mattpocock 스킬 동기화"
    bash scripts/sync-mattpocock-skills.sh || warn "스킬 동기화 실패 — 나중에 bash scripts/sync-mattpocock-skills.sh"
  else
    warn "rsync가 없어 스킬 동기화를 건너뜁니다."
  fi
fi

# ---------- 4. .gitignore · settings.json ----------
touch .gitignore
grep -qxF '/.orca-loop/*.log' .gitignore || printf '\n# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다\n/.orca-loop/*.log\n' >> .gitignore
grep -qxF '/.orca-loop/*.jsonl' .gitignore || printf '# 티켓 루프의 티켓별 기록(RECORDS_FILE) — 기계별 원자료. 스펙 리포트(docs/loop-reports/)만 커밋한다\n/.orca-loop/*.jsonl\n' >> .gitignore

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
say ".claude/settings.json deny 병합 (기본 브랜치 ${BASE})"

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
    say "GitHub 라벨 6개 (${OWNER_REPO})"
  else
    warn "GitHub 저장소를 찾지 못해 라벨을 건너뜁니다 (gh repo view 실패)."
  fi
fi

# 무인 세션의 git push가 키체인 확인 창을 기다리며 멈추지 않게, 이 저장소에서는 gh 토큰만 쓴다
# (빈 값으로 상위 설정의 helper 목록을 비운 뒤 gh를 넣는다. 워크트리가 이 설정을 공유한다)
if [[ $DO_CREDENTIAL -eq 1 ]] && command -v gh >/dev/null 2>&1; then
  if ! git config --local --get-all credential.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
    git config --local --unset-all credential.helper 2>/dev/null || true
    git config --local --add credential.helper ''
    git config --local --add credential.helper '!gh auth git-credential'
    say "git 자격 증명: 이 저장소는 gh 토큰 사용 (되돌리기: git config --local --unset-all credential.helper)"
  fi
fi

if [[ $DO_ORCA -eq 1 ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then ORCA_CLI="${ORCA_CLI:-orca-ide}"; else ORCA_CLI="${ORCA_CLI:-orca}"; fi
  if ! command -v "$ORCA_CLI" >/dev/null 2>&1; then
    warn "Orca CLI($ORCA_CLI)가 없어 저장소 등록을 건너뜁니다 (Orca Settings → General → Orca CLI)."
  elif [[ -n "$OWNER_REPO" ]]; then
    if "$ORCA_CLI" repo list --json 2>/dev/null | jq -e --arg key "github.com/${OWNER_REPO}" \
         '.result.repos[] | select(.gitRemoteIdentity.canonicalKey == $key)' >/dev/null 2>&1; then
      echo "  Orca에 이미 등록됨"
    elif "$ORCA_CLI" repo add --path "$ROOT" --json >/dev/null 2>&1; then
      say "Orca 저장소 등록"
    else
      warn "Orca 등록 실패 — Orca 앱을 켠 뒤 '$ORCA_CLI repo add --path $ROOT --json'"
    fi
  fi
fi

# ---------- 6. 매니페스트 ----------
mkdir -p .orca-loop
jq -n --arg repo "$KIT_REPO" --arg ref "$REF" --arg commit "$KIT_COMMIT" --arg version "$KIT_VERSION" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson managed "$(printf '%s\n' "${managed[@]}" | jq -R . | jq -s .)" \
  '{kit: $repo, ref: $ref, commit: $commit, version: $version, installed_at: $at, managed: $managed}' > .orca-loop/kit.json

cat <<EOF

다음 단계
  1. Claude Code에서 /setup-matt-pocock-skills (docs/agents/issue-tracker.md가 아직 없으면)
  2. Claude Code에서 /setup-orca-loop — 검증 명령·orca.yaml·CI·워커 규칙을 이 저장소에 맞춰 채우고 PR을 연다
  3. Orca Settings → Projects → <저장소> → Worktree Hooks → Advanced
     Command Source "orca.yaml only", "Wait for setup to complete before starting agent" 켜기
  4. PR 병합 뒤: bash scripts/ticket-loop.sh --dry-run → --max 1 로 시험

바뀐 파일: git status
EOF
