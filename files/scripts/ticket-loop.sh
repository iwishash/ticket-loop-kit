#!/usr/bin/env bash
set -euo pipefail

# ticket-loop.sh — GitHub 이슈 티켓을 워크트리에서 한 건씩 무인 처리한다. 워크트리와 에이전트 터미널은 백엔드(Orca 또는 cmux)가 맡는다.
# 가이드: 「티켓 무인 루프 가이드북」 3판 (ticket-loop-kit docs/). 이 파일은 ticket-loop-kit이 관리한다 — 고치면 키트에서 고친다.
#
# 티켓 하나당:
#   1. 기본 브랜치에서 워크트리를 새로 만들고 에이전트(Claude Code 또는 Codex)에 `/implement N`(Codex는 `$implement N`)을 보낸다
#      (티켓마다 새 프로세스라 컨텍스트가 비어 있다)
#   2. 워커가 `<BRANCH_PREFIX>N-<slug>` 브랜치로 PR을 열 때까지 기다린다
#   3. CI를 기다리고, 충돌·CI 실패는 같은 워커에 REPAIR_ROUNDS회까지 고치게 한다
#   4. PR을 병합한다 → 본문의 `Closes #N`으로 이슈가 닫힌다. 그 티켓이 속한 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈도 닫는다
#   5. (선택) 병합된 기본 브랜치로 POST_MERGE_CMD를 한 번 돌린다 — 워커가 못 돌리는 무거운 검증. 실패하면 멈춘다
#   6. 워크트리·브랜치를 지우고, 티켓 요약 한 줄을 로그에, 기록 한 줄을 RECORDS_FILE에 남기고, 다음 티켓으로 간다
#      (자동 선택이면 대상 재계산)
#   7. `--parent` 실행이 정상 종료하면 하위 이슈가 모두 닫힌 스펙 이슈를 닫고(아직 열려 있으면), 스펙 리포트 HTML(티켓별 결과·경과 시간·
#      모델 표)을 REPORT_DIR/spec-<N>.html에 쓴다
#   8. 이번 실행에서 끝난 스펙이 있으면 회고를 권하는 안내 한 줄을 남긴다(/retro로 읽을 자료 안내). 권고일 뿐 아무것도 실행하지 않는다 —
#      회고는 사람이 후보를 보고 고르는 단계라 무인으로 돌리지 않는다
#
# 사용법:
#   ticket-loop.sh                     # 준비된 티켓 전부
#   ticket-loop.sh --parent 40         # 스펙 이슈 #40의 하위 이슈만
#   ticket-loop.sh --label bug         # 라벨로 좁히기(SCOPE_LABEL과 같다)
#   ticket-loop.sh 12 15               # 지정한 이슈만, 적은 순서대로(라벨은 보지 않는다)
#   ticket-loop.sh --dry-run           # 대상 목록만 출력
#   ticket-loop.sh --max 1             # 최대 1건
#   ticket-loop.sh --no-merge 12       # CI 통과까지만, 병합은 사람이
#   ticket-loop.sh --skip-post-merge   # POST_MERGE_CMD를 이번 실행에서 끈다
#
# 전제: 백엔드 앱 실행 중(Orca: CLI 등록 / cmux: cmux 터미널 안에서 실행하거나 소켓 모드를 열어 둠), `gh auth status` 로그인, 저장소 안에서 실행.
# 진행 로그는 기본으로 .ticket-loop/loop-MMDD.log에 덧붙인다(.gitignore에 /.ticket-loop/*.log 권장).
# 티켓마다 "#N 요약: …" 한 줄(벽시계·PR·CI 소요·수리·idle 오판·병합 뒤 검증)을 남겨 /retro가 읽는다.
# 같은 내용 + 모델을 RECORDS_FILE(JSONL)에도 남기고, 스펙 리포트가 GitHub의 PR과 합쳐 표로 만든다.
# 저장소별 설정은 .ticket-loop/loop.env에 둔다(있으면 읽는다). 그 파일은 `VAR="${VAR:-값}"` 꼴로 써서
# 실행할 때 준 환경변수가 이기게 한다. 예: CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}" POST_MERGE_PORT="${POST_MERGE_PORT:-3000}"
#
# 환경변수(선택):
#   BACKEND             orca | cmux (기본 orca). 워크트리 생성·에이전트 터미널·idle 판정·상태 표시를 누가 하나. 아래 "백엔드" 절
#   ORCA_CLI            Orca CLI 실행 파일 (기본: ORCA_CLI_COMMAND → Linux면 orca-ide → orca)
#   CMUX_CLI            cmux CLI 실행 파일 (기본: PATH의 cmux → /Applications/cmux.app/Contents/Resources/bin/cmux)
#   WORKTREE_DIR        cmux 백엔드가 워크트리를 둘 디렉터리 (기본 ~/.cache/ticket-loop/<owner-repo>/worktrees). Orca는 자기 자리에 둔다
#   WORKTREE_SETUP_CMD  cmux 백엔드가 새 워크트리에서 에이전트를 띄우기 전에 돌릴 명령(의존성 설치·env 복사 — Orca의 orca.yaml setup에
#                       해당). LOOP_ROOT_PATH·LOOP_WORKTREE_PATH를 환경변수로 준다. 예 "pnpm install && cp \"$LOOP_ROOT_PATH/.env.local\" ."
#   SPEC_ISSUE          --parent 기본값
#   SCOPE_LABEL         함께 요구할 라벨(--label 기본값)
#   READY_LABEL         대상 라벨 (기본 ready-for-agent)
#   IN_REVIEW_LABEL     PR이 열린 티켓 라벨 (기본 in-review)
#   BRANCH_PREFIX       이슈 브랜치 접두사 (기본 issue-)
#   BASE_BRANCH         기준 브랜치 (기본: 저장소 기본 브랜치)
#   ORDER_REGEX         제목에서 순번을 뽑는 정규식, 이름 있는 그룹 n (기본 ^T(?<n>[0-9]+))
#   WORKER_RULES_FILE   워커가 추가로 따를 규칙 파일 (기본 .ticket-loop/worker-rules.md)
#   AGENT               claude | codex (기본 claude). Orca가 띄울 에이전트 ID이자 기록의 agent 필드. 아래 네 값의 기본을 정하는
#                       프리셋이다(아래 "에이전트 프리셋" 절). 다른 값이면 네 값을 직접 적어야 한다
#   AGENT_RESTART_CMD   에이전트를 셸에서 띄우는 명령. 프롬프트는 인자로 붙는다 (claude: claude --dangerously-skip-permissions,
#                       codex: codex --dangerously-bypass-approvals-and-sandbox). Orca는 뜨지 않았을 때만, cmux는 처음부터 이 명령으로 띄운다
#   AGENT_BANNER_REGEX  에이전트가 떴는지 확인할 화면 문구(ERE) (claude: Claude Code 배너·모델명, codex: "OpenAI Codex"·gpt- 모델명)
#   SKILL_PREFIX        워커 프롬프트에서 스킬을 부르는 접두사 (claude: / → /implement N, codex: $ → $implement N)
#   TICKET_TIMEOUT_SEC  티켓 한 건 제한 시간 (기본 14400 = 4시간)
#   MERGE_METHOD        merge | squash | rebase (기본 merge)
#   REPAIR_ROUNDS       충돌·CI 수리 횟수 합계 (기본 1)
#   CI_SKIP_REGEX       저장소 CI가 경로 필터(paths / paths-ignore)로 일부 PR에서 돌지 않을 때, 그 필터를 루프에 알려 주는 값.
#                       바뀐 파일이 전부 이 정규식(ERE)에 맞으면 체크가 안 붙는 게 정상인 PR로 보고 체크 없이 병합한다.
#                       루프가 정하는 규칙이 아니라 워크플로의 필터를 따라 하는 것이다 — 필터가 없으면 비워 둔다 (기본 없음 = 모든 PR에서 체크를 기다린다)
#   CI_SKIP_CMD         같은 목적의 명령 — 순서 규칙이 있는 paths 목록처럼 정규식 하나로 못 쓰는 필터용. 바뀐 파일 목록을 stdin으로
#                       (한 줄에 하나) 받아 CI가 돌면 "run", 전부 제외 경로면 "skip"을 출력한다. 저장소 루트에서 실행되고, 있으면
#                       CI_SKIP_REGEX보다 먼저 본다. 실패하거나 다른 출력이면 체크를 기다리는 쪽으로 간다
#   POST_MERGE_CMD      병합 뒤 기본 브랜치에서 돌릴 명령, 예 "npm ci && npm run test:e2e" (기본 없음 = 끔)
#   POST_MERGE_COPY     POST_MERGE_CMD 전에 메인 체크아웃에서 복사할 파일들(공백 구분), 예 ".env.local"
#   POST_MERGE_PORT     POST_MERGE_CMD가 쓰는 포트. 지정하면 비기를 기다린다(기본 없음)
#   POST_MERGE_WORKTREE POST_MERGE_CMD를 돌릴 워크트리 (기본 ~/.cache/ticket-loop/<owner-repo>/post-merge, 저장소 밖)
#   LOG_FILE            진행 로그 파일 (기본 .ticket-loop/loop-MMDD.log, /dev/null이면 끔)
#   RECORDS_FILE        티켓별 기록 JSONL (기본 .ticket-loop/tickets.jsonl, 기계별 — 커밋하지 않는다)
#   REPORT_DIR          스펙 리포트 HTML 디렉터리 (기본 docs/loop-reports — 리포트는 사람이 PR로 커밋)
#   MODEL_REGEX         워커 터미널에서 모델 이름을 뽑는 정규식(ERE) (claude: 상태줄·배너의 "Opus 5.5" 꼴, codex: "gpt-5.1-codex" 꼴).
#                       못 찾으면 리포트에 not recorded
#
# 멈추는 조건(루프 종료, 워크트리는 조사용으로 남긴다):
#   - 워커가 PR 없이 멈춤(질문·실패) / 티켓 타임아웃 / 백엔드 터미널 끊김 / 에이전트 기동 실패
#   - 수리 REPAIR_ROUNDS회 뒤에도 CI 실패 또는 충돌
#   - 병합 뒤 POST_MERGE_CMD 실패, 또는 POST_MERGE_PORT가 10분 안에 비지 않음(기다리는 동안은 로그 한 줄 뒤 조용하다 — 멈춤이 아니다)
# 자동 선택은 선행 이슈가 열렸거나, PR이 이미 있거나, 담당자가 있거나, 하위 이슈를 가진(스펙) 이슈를 건너뛴다.

LOOP_ENV="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.ticket-loop/loop.env"
# shellcheck source=/dev/null
[[ ! -f "$LOOP_ENV" ]] || source "$LOOP_ENV"

BACKEND="${BACKEND:-orca}"
if [[ -n "${ORCA_CLI:-}" ]]; then :
elif [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then ORCA_CLI="$ORCA_CLI_COMMAND"
elif [[ "$(uname -s)" == "Linux" ]]; then ORCA_CLI="orca-ide"   # Linux의 orca는 GNOME 스크린리더다
else ORCA_CLI="orca"
fi
if [[ -z "${CMUX_CLI:-}" ]]; then
  if command -v cmux >/dev/null 2>&1; then CMUX_CLI="cmux"; else CMUX_CLI="/Applications/cmux.app/Contents/Resources/bin/cmux"; fi
fi
WORKTREE_DIR="${WORKTREE_DIR:-}"
WORKTREE_SETUP_CMD="${WORKTREE_SETUP_CMD:-}"
PARENT="${SPEC_ISSUE:-}"
CLOSED_SPECS=""   # 이번 실행에서 닫은 스펙 이슈 번호들(끝날 때 회고 안내에 쓴다)
SCOPE_LABEL="${SCOPE_LABEL:-}"
READY_LABEL="${READY_LABEL:-ready-for-agent}"
IN_REVIEW_LABEL="${IN_REVIEW_LABEL:-in-review}"
BRANCH_PREFIX="${BRANCH_PREFIX:-issue-}"
BASE_BRANCH="${BASE_BRANCH:-}"
ORDER_REGEX="${ORDER_REGEX:-^T(?<n>[0-9]+)}"
WORKER_RULES_FILE="${WORKER_RULES_FILE:-.ticket-loop/worker-rules.md}"
AGENT="${AGENT:-claude}"
TICKET_TIMEOUT_SEC="${TICKET_TIMEOUT_SEC:-14400}"
MERGE_METHOD="${MERGE_METHOD:-merge}"
REPAIR_ROUNDS="${REPAIR_ROUNDS:-1}"
CI_SKIP_REGEX="${CI_SKIP_REGEX:-}"
CI_SKIP_CMD="${CI_SKIP_CMD:-}"
POST_MERGE_CMD="${POST_MERGE_CMD:-}"
POST_MERGE_COPY="${POST_MERGE_COPY:-}"
POST_MERGE_PORT="${POST_MERGE_PORT:-}"
POST_MERGE_WORKTREE="${POST_MERGE_WORKTREE:-}"
LOG_FILE="${LOG_FILE:-.ticket-loop/loop-$(date +%m%d).log}"
RECORDS_FILE="${RECORDS_FILE:-.ticket-loop/tickets.jsonl}"
REPORT_DIR="${REPORT_DIR:-docs/loop-reports}"
# ----- 에이전트 프리셋 -----
# AGENT가 기동 명령·배너·모델 정규식·스킬 접두사의 기본값을 정한다. loop.env나 환경변수로 준 값이 이긴다.
#   claude  Claude Code. 스킬은 /이름. 모델명은 상태줄·배너의 "Opus 5.5" 꼴
#   codex   Codex CLI. 스킬은 $이름 — Codex는 .claude/skills/ 를 읽지 않고 .agents/skills/ 를 읽는다(배치는 키트 다음 단계). 배너 "OpenAI Codex",
#           모델명 "gpt-5.1-codex" 꼴(상태줄 설정에 따라 안 보일 수 있다 → not recorded). --dangerously-bypass-approvals-and-sandbox(=--yolo)는
#           Claude의 --dangerously-skip-permissions에 해당한다 — 더 좁은 --sandbox workspace-write는 네트워크를 막아 push·gh pr create가 안 된다.
#           .claude/settings.json의 deny(gh pr merge)는 Codex에 안 걸린다 — 병합 금지는 프롬프트와 GitHub 브랜치 보호에 기댄다
#   그 외   프리셋 없음. AGENT_RESTART_CMD·AGENT_BANNER_REGEX(·MODEL_REGEX·SKILL_PREFIX)를 loop.env에 적는다. 비어 있으면 시작 때 멈춘다
case "$AGENT" in
  claude)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-claude --dangerously-skip-permissions}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-Claude Code|Opus|Sonnet|Fable|Haiku}"
    MODEL_REGEX="${MODEL_REGEX:-(Opus|Sonnet|Haiku|Fable|Mythos)[[:space:]]+[0-9]+(\.[0-9]+)?}"
    SKILL_PREFIX="${SKILL_PREFIX:-/}" ;;
  codex)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-codex --dangerously-bypass-approvals-and-sandbox}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-OpenAI Codex|gpt-[0-9]}"
    MODEL_REGEX="${MODEL_REGEX:-gpt-[0-9]+(\.[0-9]+)?(-[[:alnum:]]+)*}"
    SKILL_PREFIX="${SKILL_PREFIX:-\$}" ;;
  *)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-}"
    MODEL_REGEX="${MODEL_REGEX:-}"
    SKILL_PREFIX="${SKILL_PREFIX:-/}" ;;
esac
# ----- 에이전트 프리셋 끝 -----
IDLE_WAIT_MS=600000       # idle 1회 대기 상한(Orca: terminal wait 한 번, cmux: 폴링 한 바퀴)
IDLE_POLL_SEC=5           # cmux 백엔드가 lifecycle을 다시 읽는 간격
TERMINAL_RETRY=5          # wait가 이상하게 끝났을 때 터미널 읽기를 다시 해 보는 횟수
TERMINAL_RETRY_SEC=10
IDLE_STRIKES=3            # PR 없이 연속 idle이면 멈춤으로 본다
IDLE_RECHECK_SEC=30
STARTUP_GRACE_SEC=120     # 기동 직후에는 프롬프트 처리 전에도 idle로 잡힌다
AGENT_START_WAIT_SEC=90   # 에이전트 배너가 보이기까지 기다리는 상한(1회), 넘기면 한 번 다시 띄운다
CI_APPEAR_TIMEOUT_SEC=900
PORT_WAIT_SEC=600         # POST_MERGE_PORT가 비기를 기다리는 상한. 기다리는 동안은 30초마다 다시 본다(멈춤이 아니다)

DRY_RUN=0
NO_MERGE=0
POST_MERGE=1
MAX=0
TICKETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-merge) NO_MERGE=1 ;;
    --skip-post-merge) POST_MERGE=0 ;;
    --max) MAX="$2"; shift ;;
    --parent) PARENT="${2#\#}"; shift ;;
    --label) SCOPE_LABEL="$2"; shift ;;
    --help|-h) awk 'NR > 2 && /^#/ { on = 1; sub(/^# ?/, ""); print; next } on { exit }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TICKETS+=("${1#\#}") ;;
  esac
  shift
done
[[ -n "$POST_MERGE_CMD" ]] || POST_MERGE=0

# --dry-run은 로그를 남기지 않는다(목록 확인만). 실행 로그는 다음 /retro가 읽는 1차 자료다.
if [[ $DRY_RUN -eq 0 && "$LOG_FILE" != "/dev/null" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec 2> >(tee -a "$LOG_FILE" >&2)
fi

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
notify() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1 || true
  fi
}
# 티켓 처리 중(CUR_N이 있을 때) 멈추면 그 티켓을 "stopped"로 기록해 스펙 리포트에 시도로 남긴다
die() { log "ERROR: $*"; [[ -z "${CUR_N:-}" ]] || record_ticket "stopped" "$*"; notify "티켓 루프 중단" "$*"; exit 1; }
fmt_epoch() { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S'; }   # macOS / Linux

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || die "${tool} 이(가) 없습니다."
done
[[ -n "$AGENT_RESTART_CMD" && -n "$AGENT_BANNER_REGEX" ]] \
  || die "AGENT=${AGENT} 에는 프리셋이 없습니다 (claude | codex). AGENT_RESTART_CMD·AGENT_BANNER_REGEX 를 .ticket-loop/loop.env 에 적으세요."

ROOT="$(git rev-parse --show-toplevel)"
MAIN_WT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
# 루프는 저장소당 하나만 — 두 루프가 같은 티켓을 집지 않게 한다
LOCK_DIR="$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)/ticket-loop.lock"
if [[ $DRY_RUN -eq 0 ]]; then
  mkdir "$LOCK_DIR" 2>/dev/null || die "다른 루프가 실행 중입니다 (${LOCK_DIR}). 실행 중인 루프가 없으면(pgrep -fl ticket-loop) 그 디렉터리를 지우세요."
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"

# ---------- GitHub 조회 ----------

# 열린 선행 이슈 수. issue_dependencies_summary.blocked_by는 선행 이슈가 닫힌 뒤에도
# 최대 ~20분 옛 값을 돌려준 실측이 있어, 목록에서 열린 것만 센다.
blocked_by() {
  gh api "repos/${OWNER_REPO}/issues/$1/dependencies/blocked_by" --paginate \
    --jq '[.[] | select(.state == "open")] | length' 2>/dev/null | awk '{s += $1} END {print s + 0}'
}

# 하위 이슈 수 — 스펙 이슈(/to-spec이 ready-for-agent를 붙인다)를 티켓처럼 집지 않게 한다
sub_issue_count() { gh api "repos/${OWNER_REPO}/issues/$1" --jq '.sub_issues_summary.total // 0'; }

open_pr_for() {
  gh pr list --state open --json number,headRefName \
    | jq -r --arg p "${BRANCH_PREFIX}$1-" 'map(select(.headRefName | startswith($p))) | .[0].number // empty'
}

issue_title() { gh issue view "$1" --json title -q .title; }

candidates() {
  # READY_LABEL(+SCOPE_LABEL)(+PARENT의 하위 이슈), IN_REVIEW_LABEL 없음, 제목 순번 → 이슈 번호 순
  local list kids
  local args=(--label "$READY_LABEL" --state open --limit 200 --json number,title,labels,assignees)
  [[ -z "$SCOPE_LABEL" ]] || args+=(--label "$SCOPE_LABEL")
  list="$(gh issue list "${args[@]}")"
  if [[ -n "$PARENT" ]]; then
    kids="$(gh api "repos/${OWNER_REPO}/issues/${PARENT}/sub_issues" --paginate --jq '[.[].number]' | jq -s 'add // []')"
    list="$(jq --argjson kids "$kids" 'map(select(.number as $n | $kids | index($n)))' <<<"$list")"
  fi
  jq -r --arg re "$ORDER_REGEX" --arg rv "$IN_REVIEW_LABEL" '
      map(select((.labels | map(.name) | index($rv)) == null))
      | map(. + {o: ([.title | capture($re) | .n] | first)})
      | sort_by([(if .o then 0 else 1 end), ((.o // .number) | tonumber)])
      | .[] | "\(.number)\t\(.assignees | length)\t\(.title)"' <<<"$list"
}

pick_targets() {
  if [[ ${#TICKETS[@]} -gt 0 ]]; then
    for n in "${TICKETS[@]}"; do printf '%s\t%s\n' "${n}" "$(issue_title "${n}")"; done
    return
  fi
  local n assignees title
  while IFS=$'\t' read -r n assignees title; do
    [[ -n "${n}" ]] || continue
    if [[ "${assignees}" != "0" ]]; then log "skip #${n} (${title}): 담당자 있음(진행 중이거나 사람이 맡음)"; continue; fi
    if [[ "$(sub_issue_count "${n}")" != "0" ]]; then log "skip #${n} (${title}): 하위 이슈가 있는 스펙 이슈"; continue; fi
    if [[ "$(blocked_by "${n}")" != "0" ]]; then log "skip #${n} (${title}): 선행 이슈 열림"; continue; fi
    if [[ -n "$(open_pr_for "${n}")" ]]; then log "skip #${n} (${title}): PR 이미 열림"; continue; fi
    printf '%s\t%s\n' "${n}" "${title}"
  done < <(candidates)
}

# ---------- 백엔드 ----------
# 루프가 워크트리·에이전트 터미널에 대해 하는 일은 아래 아홉 가지뿐이다. 백엔드마다 같은 이름의 함수(<backend>_*)를 구현하고
# BACKEND로 고른다. 티켓 선택·PR·CI·수리·병합·병합 뒤 검증·기록·리포트는 백엔드와 무관하게 한 벌이다.
#   _check                       시작 때 한 번: CLI가 있고 앱에 닿는지, 저장소가 등록돼 있는지
#   _worktree_create N PROMPT    기본 브랜치에서 워크트리를 만들고 에이전트를 띄운다. 전역 WT(백엔드의 워크트리/워크스페이스 id),
#                                WT_PATH, WT_BRANCH(백엔드가 만든 브랜치 — 워커가 바꾸기 전 이름), HANDLE(에이전트 터미널)을 채운다
#   _worktree_remove WT WT_PATH  워크트리를 지운다(브랜치 정리는 공통부가 한다)
#   _send HANDLE TEXT            프롬프트 한 줄을 에이전트 입력에 넣고 제출한다. 수락되지 않으면 비0
#   _type HANDLE TEXT            셸 명령 한 줄을 입력하고 Enter(에이전트 재기동용 — 에이전트 입력 검사 없이)
#   _interrupt HANDLE            Ctrl-C
#   _wait_idle HANDLE MS         반환 0: idle 확인, 1: 타임아웃(아직 작업 중), 3: 터미널에 닿지 못함(앱 종료 등)
#   _tail HANDLE                 화면 마지막 25줄
#   _set_status WT STATUS [PR] [COMMENT]   STATUS: in-progress | in-review | todo(확인 필요) | completed. 실패해도 루프는 간다
backend_check()           { "${BACKEND}_check" "$@"; }
backend_worktree_create() { "${BACKEND}_worktree_create" "$@"; }
backend_worktree_remove() { "${BACKEND}_worktree_remove" "$@"; }
backend_send()            { "${BACKEND}_send" "$@"; }
backend_type()            { "${BACKEND}_type" "$@"; }
backend_interrupt()       { "${BACKEND}_interrupt" "$@"; }
backend_wait_idle()       { "${BACKEND}_wait_idle" "$@"; }
backend_tail()            { "${BACKEND}_tail" "$@"; }
backend_set_status()      { "${BACKEND}_set_status" "$@"; }
case "$BACKEND" in orca|cmux) ;; *) die "BACKEND=${BACKEND} 를 모릅니다 (orca | cmux)." ;; esac
BACKEND_NAME="$([[ "$BACKEND" == orca ]] && echo Orca || echo cmux)"

# 프롬프트를 셸 명령 인자로 넘길 때는 파일을 거친다(따옴표·백틱이 섞여도 안전). 파일은 티켓이 끝나도 지우지 않는다(디버그용, tmp)
prompt_file() { local f; f="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-prompt-$1.XXXXXX")"; printf '%s' "$2" > "$f"; printf '%s' "$f"; }
agent_launch_cmd() { printf '%s "$(cat %q)"' "$AGENT_RESTART_CMD" "$1"; }   # 셸이 해석할 한 줄: claude|codex … "$(cat /tmp/…)"

# ----- Orca: 워크트리·터미널·idle 대기를 모두 Orca CLI가 한다 -----

orca_json() { "$ORCA_CLI" "$@" --json; }

orca_check() {
  command -v "$ORCA_CLI" >/dev/null 2>&1 || die "Orca CLI(${ORCA_CLI})가 없습니다 (Orca Settings → General → Orca CLI)."
  # canonicalKey는 보통 github.com/<owner>/<repo>지만, SSH 별칭 호스트(~/.ssh/config의 github.com-<계정>)를 쓰면
  # github.com-<계정>/<owner>/<repo>가 된다(2026-10-12 실측). 호스트는 보지 않고 /<owner>/<repo>로 끝나는지만 본다
  REPO_ID="$("$ORCA_CLI" repo list --json \
    | jq -r --arg suffix "/${OWNER_REPO}" \
        '.result.repos[] | select((.gitRemoteIdentity.canonicalKey // "") | endswith($suffix)) | .id' | head -n1)"
  [[ -n "$REPO_ID" ]] || die "Orca에 ${OWNER_REPO} 저장소가 없습니다. '${ORCA_CLI} repo add --path ${ROOT} --json'으로 등록하세요."
}

orca_worktree_create() {
  local n="$1" prompt="$2" created
  created="$(orca_json worktree create --repo "id:$REPO_ID" --name "${BRANCH_PREFIX}${n}" --no-parent \
    --base-branch "origin/${BASE_BRANCH}" --issue "${n}" --agent "$AGENT" \
    --prompt "$prompt" --comment "티켓 루프: ${SKILL_PREFIX}implement ${n} 진행 중")"
  jq -e '.ok == true' <<<"$created" >/dev/null || die "워크트리 생성 실패: $(jq -c '.error' <<<"$created")"
  WT="$(jq -r '.result.worktree.id' <<<"$created")"
  WT_PATH="${WT#*::}"
  HANDLE="$(jq -r '.result.agentTerminalHandle // .result.startupTerminal.handle // empty' <<<"$created")"
  [[ -n "${HANDLE}" ]] || die "에이전트 터미널 핸들을 받지 못했습니다 (${WT})"
  # Orca가 워크트리용으로 만든 브랜치(설정에 따라 `issue-N` 또는 `<git 사용자>/issue-N`) — 워커가 브랜치를 바꾸기 전에 기록한다
  WT_BRANCH="$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
}

orca_worktree_remove() { orca_json worktree rm --worktree "id:$1" --force >/dev/null; }

orca_send() {
  orca_json terminal send --terminal "$1" --text "$2" --enter --wait-submit 15 \
    | jq -e '.result.send.accepted == true' >/dev/null
}
orca_type()      { orca_json terminal send --terminal "$1" --text "$2" --enter >/dev/null; }
orca_interrupt() { orca_json terminal send --terminal "$1" --text $'\x03' >/dev/null; }

orca_wait_idle() {
  # `orca terminal wait`는 타임아웃이면 {ok:false, error.code:"timeout"}과 함께 exit 1을 돌려준다(Orca 1.4.223 실측).
  # exit 코드만 보면 "닿지 못함"으로 오판해 일하는 워커를 두고 루프가 죽는다 — JSON으로 가른다.
  # 그 밖의 응답(빈 출력·다른 error.code)은 한 번으로 "닿지 못함"이라 판정하지 않는다. 사람이 Orca 앱에서 워커
  # 워크트리를 열면 세션이 다시 붙으며(데몬 로그 session-attached) 기다리던 wait가 그렇게 끝난다 — 2026-10-12 #72
  # (Orca 1.4.224)에서 일하던 워커를 두고 루프가 죽었다. 터미널을 읽을 수 있으면 아직 작업 중(1)으로 보고,
  # TERMINAL_RETRY번 연달아 읽지도 못할 때만 3이다. 터미널이 사라지면 read가 ok:false(terminal_handle_stale)다.
  local out code i
  out="$(orca_json terminal wait --terminal "$1" --for tui-idle --timeout-ms "$2" 2>/dev/null)" || true
  jq -e '.result.wait.satisfied == true' <<<"$out" >/dev/null 2>&1 && return 0
  code="$(jq -r '.error.code // empty' <<<"$out" 2>/dev/null)"
  [[ "$code" == "timeout" ]] && return 1
  for i in $(seq 1 "$TERMINAL_RETRY"); do
    sleep "$TERMINAL_RETRY_SEC"
    if orca_json terminal read --terminal "$1" 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then
      log "터미널 $1: wait 응답 이상(${code:-빈 출력}) — 터미널은 살아 있어 계속 기다린다"
      return 1
    fi
  done
  return 3
}

orca_tail() { orca_json terminal read --terminal "$1" | jq -r '.result.terminal.tail[]?' | tail -n 25; }

orca_set_status() {
  # local 한 문장 안에서 선언한 변수를 같은 문장에서 쓰면 set -u 에 걸린다(2026-10-12 boiler-webapp #34 실측) — 줄을 나눈다
  local wt="$1" status="$2" pr="${3:-}" comment="${4:-}"
  local args=(--worktree "id:${wt}" --workspace-status "$status")
  [[ -z "$pr" ]] || args+=(--pr "$pr")
  [[ -z "$comment" ]] || args+=(--comment "$comment")
  [[ "$status" != "todo" ]] || args+=(--unread)
  orca_json worktree set "${args[@]}" >/dev/null
}

# ----- cmux: 워크트리는 루프가 git으로 만들고, 터미널은 cmux 워크스페이스다 (cmux 0.65 실측) -----
# cmux에는 워크트리 생성 명령도, idle까지 블로킹하는 명령도 없다. 그래서
#   - `git worktree add` 뒤 WORKTREE_SETUP_CMD(orca.yaml setup에 해당)를 돌리고 `cmux workspace create --cwd … --command "<AGENT_RESTART_CMD> …"`
#     --command는 워크스페이스의 로그인 셸(zsh)이 실행하고, 그 셸의 PATH 앞에 cmux의 에이전트 shim(claude·codex)이 있어 lifecycle 훅이 자동으로 붙는다
#   - idle은 `cmux rpc surface.input_state`가 돌려주는 lifecycle(running | idle | needsInput | unknown — 에이전트 훅이 보고. Claude Code 실측,
#     Codex는 shim이 같은 훅을 주입하지만 아직 실측 전)을
#     IDLE_POLL_SEC마다 읽어 판정한다. 이벤트 스트림(`cmux events`)의 이름에 기대지 않는다
#   - 소켓 모드가 cmuxOnly(기본)면 cmux 터미널 밖에서는 "액세스 거부"다. 루프를 cmux 터미널 안에서 돌린다
#   - 백그라운드 idle 에이전트를 하이버네이션할 수 있어, 프롬프트를 보내기 전에 깨운다
# 실측한 것: `--json`은 명령 뒤에 둬야 JSON이 나온다(앞에 두면 "OK workspace:N" 한 줄). `workspace create --json --id-format uuids`는
# {workspace_id, surface_id, window_id, group_id}. `workspace status set`의 lane은 todo|working|needs-attention|review|done|auto.
# `workspace close`는 프로세스가 살아 있으면 --force 없이 거부한다. 옛 이름(new-workspace 등)은 deprecation 한 줄을 찍으니 쓰지 않는다.

cmux_j() { CMUX_QUIET=1 "$CMUX_CLI" "$@" --json; }

cmux_check() {
  [[ -x "$CMUX_CLI" ]] || command -v "$CMUX_CLI" >/dev/null 2>&1 || die "cmux CLI(${CMUX_CLI})가 없습니다 (CMUX_CLI=경로)."
  "$CMUX_CLI" identify --json >/dev/null 2>&1 \
    || die "cmux 소켓에 닿지 못했습니다. cmux 터미널 안에서 실행하거나 소켓 모드를 바꾸세요 ('${CMUX_CLI} socket-status --json')."
  [[ -n "$WORKTREE_DIR" ]] || WORKTREE_DIR="$HOME/.cache/ticket-loop/${OWNER_REPO//\//-}/worktrees"
}

cmux_worktree_create() {
  local n="$1" prompt="$2" path out pf
  path="${WORKTREE_DIR}/${BRANCH_PREFIX}${n}"
  [[ ! -e "$path" ]] || die "워크트리 경로가 이미 있습니다: ${path} (지난 실행의 잔재면 'git worktree remove --force' 뒤 다시)"
  mkdir -p "$WORKTREE_DIR"
  git -C "$ROOT" branch -D "${BRANCH_PREFIX}${n}" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree add -q -b "${BRANCH_PREFIX}${n}" "$path" "origin/${BASE_BRANCH}" || die "git worktree add 실패 (${path})"
  if [[ -n "$WORKTREE_SETUP_CMD" ]]; then
    log "#${n}: 워크트리 준비 — ${WORKTREE_SETUP_CMD}"
    (cd "$path" && LOOP_ROOT_PATH="$MAIN_WT" LOOP_WORKTREE_PATH="$path" bash -c "$WORKTREE_SETUP_CMD") \
      || die "#${n}: WORKTREE_SETUP_CMD 실패 (${path})"
  fi
  pf="$(prompt_file "$n" "$prompt")"
  out="$(cmux_j workspace create --name "${BRANCH_PREFIX}${n}" --cwd "$path" --focus false --id-format uuids \
           --command "$(agent_launch_cmd "$pf")" 2>/dev/null)" || die "cmux workspace create 실패"
  WT="$(jq -r '.workspace_id // empty' <<<"$out" 2>/dev/null || true)"
  HANDLE="$(jq -r '.surface_id // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$WT" && -n "$HANDLE" ]] || die "cmux workspace create 응답에서 workspace_id/surface_id를 찾지 못했습니다: ${out}"
  WT_PATH="$path"
  WT_BRANCH="${BRANCH_PREFIX}${n}"
}

cmux_worktree_remove() {
  # 에이전트 프로세스가 살아 있는 워크스페이스라 --force가 필요하다(없으면 confirmation_required로 거부)
  CMUX_QUIET=1 "$CMUX_CLI" workspace close "$1" --force >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$2"
}

cmux_send() {
  "$CMUX_CLI" agent-hibernation wake "$1" >/dev/null 2>&1 || true
  # paste --submit: 한 줄을 붙여 넣고 제출. 에이전트 입력에 초안이나 대화상자가 있으면 거부(비0)한다 — 사람이 끼어든 것이니 보내지 않는다
  "$CMUX_CLI" paste --surface "$1" --submit "$2" >/dev/null
}
cmux_type()      { "$CMUX_CLI" send --surface "$1" --force "$2" >/dev/null && "$CMUX_CLI" send-key --surface "$1" enter >/dev/null; }
cmux_interrupt() { "$CMUX_CLI" send-key --surface "$1" ctrl+c >/dev/null; }

cmux_lifecycle() {   # running | idle | needsInput | unknown, 소켓에 닿지 못하면 빈 값
  "$CMUX_CLI" rpc surface.input_state "{\"surface_id\":\"$1\"}" 2>/dev/null | jq -r '.lifecycle // empty' 2>/dev/null || true
}

cmux_wait_idle() {
  local handle="$1" deadline_ms=$(( $(date +%s) * 1000 + $2 )) lc fails=0
  while :; do
    lc="$(cmux_lifecycle "$handle")"
    case "$lc" in
      idle|needsInput) return 0 ;;    # needsInput: 질문·권한 대화상자 — 공통부가 PR 유무와 화면으로 "멈춤"을 가른다
      running|unknown) fails=0 ;;
      *) fails=$((fails + 1)); [[ $fails -lt $TERMINAL_RETRY ]] || return 3 ;;
    esac
    [[ $(( $(date +%s) * 1000 )) -lt $deadline_ms ]] || return 1
    sleep "$IDLE_POLL_SEC"
  done
}

cmux_tail() { "$CMUX_CLI" read-screen --surface "$1" --lines 25; }

cmux_set_status() {
  local wt="$1" status="$2" pr="${3:-}" comment="${4:-}" lane
  case "$status" in in-progress) lane=working ;; in-review) lane=review ;; completed) lane=done ;; *) lane=todo ;; esac
  "$CMUX_CLI" workspace status set "$lane" --workspace "$wt" >/dev/null 2>&1 || true
  [[ -z "$pr" ]] || "$CMUX_CLI" pr "$pr" --workspace "$wt" >/dev/null 2>&1 || true
  [[ -z "$comment" ]] || "$CMUX_CLI" log --workspace "$wt" "$comment" >/dev/null 2>&1 || true
}

# ----- 공통 -----

terminal_idle() { backend_wait_idle "$@"; }
terminal_tail() { backend_tail "$@"; }
send_prompt() { backend_send "$1" "$2" || die "프롬프트 전송이 수락되지 않았습니다 (terminal $1)"; }

worker_prompt() {
  # 한 줄로 보낸다 — TUI에서는 줄바꿈이 곧 제출이다.
  # 절차(선행 확인·브랜치·seam·리뷰·PR 본문·라벨·병합 금지)는 저장소의 implement 스킬이 단일 진실이다.
  # 여기에는 무인 실행에서만 참인 것만 둔다 — 질문 금지, 막히면 코멘트 후 멈춤, 규칙 파일. 특정 에이전트의 도구·명령 이름은 쓰지 않는다(SKILL_PREFIX만 다르다).
  local n="$1" rules=""
  [[ ! -f "$ROOT/$WORKER_RULES_FILE" ]] || rules=" 저장소의 ${WORKER_RULES_FILE} 규칙도 따라라."
  printf '%s' "${SKILL_PREFIX}implement ${n} — 무인 루프(ticket-loop.sh)에서 실행 중이다. 사람이 답할 수 없으니 사람에게 묻거나 확인을 구하지 말고(질문 도구도 쓰지 말고) 스스로 결정해 끝까지 진행해라. PR은 병합하지 마라 — 루프가 CI 뒤에 병합한다. 진행이 불가능하면(열린 선행 이슈 포함) 이슈 #${n}에 이유를 코멘트로 남기고 PR 없이 멈춰라.${rules}"
}

# 에이전트가 실제로 떴는지 확인한다. Orca가 셸에 기동 명령을 넣을 때 앞 글자가 빠져
# (`laude …`) 셸 프롬프트에 멈춘 실측이 있다(4연속). 배너가 안 보이면 입력 줄을 지우고 한 번 다시 띄운다.
agent_banner_seen() { terminal_tail "$1" 2>/dev/null | grep -Eq "$AGENT_BANNER_REGEX"; }

ensure_agent_started() {
  local n="$1" handle="$2" i attempt promptfile
  for attempt in 1 2; do
    for i in $(seq 1 $(( AGENT_START_WAIT_SEC / 3 ))); do
      agent_banner_seen "${handle}" && return 0
      sleep 3
    done
    [[ $attempt -eq 1 ]] || break
    log "#${n}: 에이전트가 뜨지 않음 — 터미널에서 다시 띄운다"
    promptfile="$(prompt_file "${n}" "$(worker_prompt "${n}")")"
    backend_interrupt "${handle}" || true   # Ctrl-C로 입력 줄 비움
    sleep 1
    backend_type "${handle}" "$(agent_launch_cmd "${promptfile}")" || die "#${n}: 재기동 명령 전송 실패"
  done
  die "#${n}: 에이전트가 터미널 ${handle}에서 뜨지 않습니다"
}

# PR이 생길 때까지(또는 워커가 멈출 때까지) 기다린다. 성공 시 PR 번호를 stdout에 쓴다.
# 반환: 0 PR 열림, 1 PR 없이 멈춤, 2 타임아웃, 3 백엔드 터미널 끊김
wait_for_pr() {
  local n="$1" handle="$2" deadline="$3" strikes=0 pr started idle last_screen="" screen
  started="$(date +%s)"
  while :; do
    pr="$(open_pr_for "${n}")"
    if [[ -n "${pr}" ]]; then
      # PR 직후 라벨·체크박스 정리까지 끝나도록 한 번 더 idle을 기다린다
      terminal_idle "${handle}" "$IDLE_WAIT_MS" || true
      echo "${pr}"; return 0
    fi
    [[ "$(date +%s)" -lt "$deadline" ]] || return 2
    idle=0; terminal_idle "${handle}" "$IDLE_WAIT_MS" || idle=$?
    [[ $idle -ne 3 ]] || return 3
    if [[ $idle -eq 0 ]]; then
      if [[ $(( $(date +%s) - started )) -lt $STARTUP_GRACE_SEC ]]; then sleep "$IDLE_RECHECK_SEC"; continue; fi
      # PR을 연 직후에는 idle이 PR 조회보다 먼저 잡힌다(매 티켓 실측) — 잠깐 뒤 PR부터 다시 본다
      sleep "$IDLE_RECHECK_SEC"
      [[ -z "$(open_pr_for "${n}")" ]] || { IDLE_FALSE_POSITIVES=$((IDLE_FALSE_POSITIVES + 1)); continue; }
      # 지난 idle 이후 화면이 바뀌었으면 그사이 일했다는 뜻 — 연속 횟수를 새로 센다
      screen="$(terminal_tail "${handle}" | cksum | cut -d' ' -f1)"
      if [[ "$screen" != "$last_screen" ]]; then strikes=0; last_screen="$screen"; fi
      strikes=$((strikes + 1))
      log "#${n}: 워커 idle, PR 없음 (${strikes}/${IDLE_STRIKES})"
      [[ ${strikes} -lt $IDLE_STRIKES ]] || return 1
      sleep "$IDLE_RECHECK_SEC"
    else
      strikes=0
    fi
  done
}

# 수리 프롬프트를 보내고 워커가 다시 idle이 될 때까지 기다린다
repair() {
  local handle="$1" text="$2" deadline="$3" idle
  send_prompt "${handle}" "$text"
  while :; do
    idle=0; terminal_idle "${handle}" "$IDLE_WAIT_MS" || idle=$?
    [[ $idle -ne 0 ]] || return 0
    [[ $idle -ne 3 ]] || die "${BACKEND_NAME} 터미널 ${handle} 에 닿지 못했습니다 (${BACKEND_NAME} 앱 종료?)"
    [[ "$(date +%s)" -lt "$deadline" ]] || return 1
  done
}

# ---------- CI · 병합 ----------

wait_checks_appear() {
  local pr="$1" until=$(( $(date +%s) + CI_APPEAR_TIMEOUT_SEC ))
  while [[ "$(gh pr checks "${pr}" --json name --jq 'length' 2>/dev/null || echo 0)" == "0" ]]; do
    [[ "$(date +%s)" -lt "$until" ]] || return 1
    sleep 30
  done
}

ci_passed() {
  wait_checks_appear "$1" || { log "PR #$1: 체크가 등록되지 않았습니다"; return 1; }
  gh pr checks "$1" --watch --fail-fast >/dev/null   # 끝날 때까지 블록, 실패 시 비0
}

pr_head_sha() { gh pr view "$1" --json headRefOid -q .headRefOid; }

# 반환 0: CI가 도는 PR, 1: 저장소 CI의 경로 필터에 걸려 체크가 안 붙는 게 정상인 PR(CI_SKIP_CMD가 "skip", 또는 바뀐 파일이 전부
# CI_SKIP_REGEX에 맞음). 둘 다 없거나 판정이 안 되면 0(기다리는 쪽).
ci_expected() {
  local files verdict
  [[ -n "$CI_SKIP_CMD" || -n "$CI_SKIP_REGEX" ]] || return 0
  files="$(gh pr diff "$1" --name-only 2>/dev/null)" || return 0
  [[ -n "$files" ]] || return 0
  if [[ -n "$CI_SKIP_CMD" ]]; then
    verdict="$(cd "$ROOT" && printf '%s\n' "$files" | bash -c "$CI_SKIP_CMD" 2>/dev/null)" || return 0
    [[ "$verdict" != "skip" ]]
    return
  fi
  grep -Evq "$CI_SKIP_REGEX" <<<"$files"
}

mergeable_state() {
  # MERGEABLE | CONFLICTING | UNKNOWN(계산 중)
  local pr="$1" s i
  for i in 1 2 3 4 5 6; do
    s="$(gh pr view "${pr}" --json mergeable -q .mergeable)"
    [[ "$s" == "UNKNOWN" ]] || { echo "$s"; return; }
    sleep 10
  done
  echo "UNKNOWN"
}

# ---------- 병합 뒤 검증 ----------
# 워커가 돌리기 어려운 검증(실제 서버·공유 DB·고정 포트를 쓰는 통합·E2E 테스트)을 병합된 기본 브랜치로
# 한 번 돌린다. 루프는 직렬이라 여기서 돌리면 워커끼리 부딪히지 않는다. 저장소 밖 전용 워크트리를 쓴다.

port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
port_holder() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" pid "$2}'; }   # 예: "node pid 48213"

post_merge_worktree_path() {
  if [[ -n "$POST_MERGE_WORKTREE" ]]; then printf '%s' "$POST_MERGE_WORKTREE"; return; fi
  printf '%s/.cache/ticket-loop/%s/post-merge' "$HOME" "${OWNER_REPO//\//-}"
}

# 반환 0: 통과, 1: 실패(로그 꼬리를 남긴다)
run_post_merge() {
  local n="$1" wt logfile started f port_deadline holder
  wt="$(post_merge_worktree_path)"
  if [[ ! -d "$wt/.git" && ! -f "$wt/.git" ]]; then
    mkdir -p "$(dirname "$wt")"
    git -C "$ROOT" worktree add -q --detach "$wt" "origin/${BASE_BRANCH}" || { log "#${n}: 병합 뒤 검증 워크트리 생성 실패 (${wt})"; return 1; }
  fi
  git -C "$ROOT" fetch -q origin "$BASE_BRANCH"
  git -C "$wt" checkout -q --detach "origin/${BASE_BRANCH}" || { log "#${n}: 검증 워크트리를 origin/${BASE_BRANCH}으로 못 옮김"; return 1; }
  for f in $POST_MERGE_COPY; do
    [[ ! -f "$MAIN_WT/$f" ]] || cp "$MAIN_WT/$f" "$wt/$f"
  done
  if [[ -n "$POST_MERGE_PORT" ]]; then
    port_deadline=$(( $(date +%s) + PORT_WAIT_SEC ))
    # 기다리는 동안 아무것도 찍지 않으면 루프가 멈춘 것처럼 보인다(실측: 사람이 띄운 개발 서버가 포트를 쥔 채 4분을
    # 조용히 기다렸다). 처음 한 번 점유 프로세스와 기한을 적는다 — 그 서버를 끄면 30초 안에 이어 간다
    if port_in_use "$POST_MERGE_PORT"; then
      holder="$(port_holder "$POST_MERGE_PORT")"
      log "#${n}: 포트 ${POST_MERGE_PORT} 사용 중(${holder:-?}) — 비기를 $(fmt_epoch "$port_deadline")까지 기다린다. 그 서버를 끄면 바로 이어 간다"
    fi
    while port_in_use "$POST_MERGE_PORT"; do
      [[ "$(date +%s)" -lt "$port_deadline" ]] || { log "#${n}: 포트 ${POST_MERGE_PORT}이 비지 않았다 — 루프가 도는 동안 그 포트를 비우거나 --skip-post-merge"; return 1; }
      sleep 30
    done
  fi
  logfile="${TMPDIR:-/tmp}/ticket-loop-post-merge-${n}.log"
  [[ "$LOG_FILE" == "/dev/null" ]] || logfile="$(dirname "$LOG_FILE")/post-merge-${n}.log"
  started="$(date +%s)"
  log "#${n}: 병합 뒤 검증 시작 (${wt}, 로그 ${logfile})"
  if (cd "$wt" && bash -c "$POST_MERGE_CMD" >"$logfile" 2>&1); then
    POST_MERGE_RESULT="통과 $(( $(date +%s) - started ))초"
    log "#${n}: 병합 뒤 검증 ${POST_MERGE_RESULT}"
    return 0
  fi
  POST_MERGE_RESULT="실패 $(( $(date +%s) - started ))초"
  log "#${n}: 병합 뒤 검증 실패 — 꼬리 ---"; tail -n 40 "$logfile" >&2 || true
  return 1
}

# ---------- 티켓 기록 · 스펙 리포트 ----------
# 루프의 상태는 GitHub에만 두지만(기억 없음), 벽시계·CI 소요·수리 횟수·병합 뒤 검증 결과·모델은 GitHub에 없다. 티켓
# 하나가 끝날 때(병합·--no-merge·중단) RECORDS_FILE에 한 줄을 덧붙이고, --parent 실행이 정상 종료하면 그 기록과 GitHub
# (하위 이슈·PR 본문)을 합쳐 REPORT_DIR/spec-<N>.html을 만든다. 기록이 없는 티켓(다른 PC·사람 처리)은 PR 시각으로 대신한다.

CUR_N=""; CUR_TITLE=""; CUR_STARTED=0; CUR_STARTED_ISO=""; CUR_PR=""; CUR_MODEL=""; CUR_CI_SEC=""; CUR_ROUND=0

# 워커 터미널의 에이전트 상태줄·배너에서 모델 이름을 뽑는다(Claude Code: "[Opus 5.5 | Max]", Codex: 기동 블록의 "model: gpt-5.1-codex"). 못 찾으면 빈 값.
detect_model() { [[ -n "$MODEL_REGEX" ]] || return 0; terminal_tail "$1" 2>/dev/null | grep -oE "$MODEL_REGEX" | tail -n1 || true; }

# 티켓이 속한 스펙 이슈 번호 — --parent가 없으면(이슈 번호 직접 지정) GitHub의 부모 이슈를 묻는다. 없으면 0.
spec_of_ticket() {
  [[ -z "$PARENT" ]] || { printf '%s' "$PARENT"; return; }
  gh api graphql -f query="{ repository(owner: \"${OWNER_REPO%%/*}\", name: \"${OWNER_REPO#*/}\") { issue(number: $1) { parent { number } } } }" \
    --jq '.data.repository.issue.parent.number // 0' 2>/dev/null || echo 0
}

# 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈를 닫는다. 요약 값 sub_issues_summary.completed 대신 목록을 센다
# (blocked_by 요약처럼 늦게 바뀔 수 있다). 하위 이슈가 없거나 하나라도 열려 있거나 스펙이 이미 닫혔으면 아무것도 하지 않는다.
close_spec_if_done() {
  local spec="${1:-}" counts total open
  [[ -n "$spec" && "$spec" != "0" ]] || return 0
  [[ "$(gh issue view "$spec" --json state -q .state 2>/dev/null)" == "OPEN" ]] || return 0
  counts="$(gh api "repos/${OWNER_REPO}/issues/${spec}/sub_issues?per_page=100" --paginate 2>/dev/null \
    | jq -rs 'add // [] | "\(length) \(map(select(.state == "open")) | length)"')" || return 0
  read -r total open <<<"$counts"
  [[ "${total:-0}" -gt 0 && "${open:-1}" -eq 0 ]] || return 0
  if gh issue close "$spec" --comment "하위 이슈 ${total}건이 모두 닫혀 완료 (ticket-loop)" >/dev/null 2>&1; then
    log "스펙 #${spec}: 하위 이슈 ${total}건 모두 닫힘 → 스펙 이슈를 닫았다"
    CLOSED_SPECS="${CLOSED_SPECS:-} ${spec}"
  else
    log "스펙 #${spec}: 하위 이슈 ${total}건이 모두 닫혔지만 스펙 이슈를 닫지 못했다 — gh issue close ${spec}"
  fi
}

# 끝난 스펙이 있으면 회고를 권한다 — 안내일 뿐, 아무것도 실행하지 않는다. /retro 는 사람이 후보를 보고 고르는 스킬이라 무인 단계로 두지 않는다
suggest_retro() {
  local spec report skill="${SKILL_PREFIX:-/}retro" log_src
  [[ -n "${CLOSED_SPECS// /}" ]] || return 0
  [[ -d "${ROOT:-.}/.claude/skills/retro" ]] || skill="${skill}(이 저장소에는 아직 없다 — 키트 설치 때 --workflow-skills 로 들일 수 있다)"
  log_src="$LOG_FILE"; [[ "$LOG_FILE" != "/dev/null" ]] || log_src="(로그를 꺼 둬서 없음)"
  for spec in $CLOSED_SPECS; do
    report="$REPORT_DIR/spec-${spec}.html"
    if [[ -f "$report" || -f "${ROOT:-.}/$report" ]]; then report="리포트 ${report}"
    else report="리포트는 ticket-loop.sh --parent ${spec} 로 뽑을 수 있다"; fi
    log "스펙 #${spec} 완료. 원하면 ${skill}로 이번 묶음을 돌아보세요 — 읽을 자료: 로그 ${log_src}, ${report}, 병합된 PR 본문의 '남은 판단 사항'·'검증하지 못한 것'. 환경(스킬·worker-rules.md·자동 검사)을 고치게 되면 PR로 올리는 것을 권합니다"
  done
}

record_ticket() {
  local result="$1" reason="${2:-}" file="$RECORDS_FILE" spec
  [[ "$LOG_FILE" != "/dev/null" ]] || return 0
  [[ "$file" == /* ]] || file="$ROOT/$file"
  mkdir -p "$(dirname "$file")"
  spec="$(spec_of_ticket "$CUR_N")"
  jq -cn --argjson spec "${spec:-0}" --argjson issue "$CUR_N" --arg title "$CUR_TITLE" --arg result "$result" --arg reason "$reason" \
    --arg pr "$CUR_PR" --arg started "$CUR_STARTED_ISO" --arg finished "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson wall "$(( $(date +%s) - CUR_STARTED ))" --arg ci "$CUR_CI_SEC" --argjson repairs "$CUR_ROUND" \
    --argjson idle "${IDLE_FALSE_POSITIVES:-0}" --arg post "${POST_MERGE_RESULT:-}" --arg model "$CUR_MODEL" --arg agent "$AGENT" '
    {spec: $spec, issue: $issue, title: $title, result: $result, started: $started, finished: $finished, wall_sec: $wall,
     repairs: $repairs, idle_false_positives: $idle, agent: $agent}
    + (if $reason != "" then {reason: $reason} else {} end)
    + (if $pr != "" then {pr: ($pr | tonumber)} else {} end)
    + (if $ci != "" then {ci_sec: ($ci | tonumber)} else {} end)
    + (if $post != "" then {post_merge: $post} else {} end)
    + (if $model != "" then {model: $model} else {} end)' >> "$file" 2>/dev/null \
    || log "#${CUR_N}: 티켓 기록을 남기지 못했습니다 (${file})"
}

# 스펙 리포트 HTML — jq 하나로 그린다(의존 도구를 늘리지 않는다). 표: 이슈·티켓·상태·결과 브리프(PR 제목, 본문의
# 인수 조건 체크 수, 중단 사유, CI·수리·병합 뒤 검증)·경과 시간·모델·마친 시각. 문자열은 전부 @html로 이스케이프한다.
# 리포트의 고정 문구는 영어, GitHub에서 가져온 값(이슈·PR 제목, 본문)과 기록의 중단 사유는 그대로(한국어면 한국어) 둔다.
# 기록의 post_merge("통과 N초"·"실패 N초"·"건너뜀")는 표시할 때만 영어로 바꾼다(기록 파일은 그대로).
read -r -d '' REPORT_JQ <<'JQ' || true
def dur: if . == null then "—" elif . >= 3600 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
         elif . >= 60 then "\(. / 60 | floor)m" else "\(. | floor)s" end;
def epoch: if . == null or . == "" then null else (sub("\\.[0-9]+Z$"; "Z") | fromdate) end;
def when: epoch | if . == null then "—" else strflocaltime("%Y-%m-%d %H:%M") end;
def order: (.title | capture("^T(?<n>[0-9]+)") | .n | tonumber) // 999999;
# jq(Oniguruma Perl 문법)의 ^는 줄 머리가 아니라 문자열 머리다 — 앞에 \n을 붙여 줄 머리를 \n으로 잡는다
def checks: ("\n" + .) | {checked: ([scan("\n[ \t]*[-*] \\[x\\]"; "i")] | length), total: ([scan("\n[ \t]*[-*] \\[[ x]\\]"; "i")] | length)};
def badge: {merged: ["Merged", "ok"], "closed-without-pr": ["Closed without PR", "muted"], "pr-open": ["PR open", "warn"],
            "in-progress": ["In progress", "warn"], stopped: ["Stopped", "bad"], pending: ["Not started", "muted"]}[.];
# 기록의 post_merge 값을 표시용 영어로. 모르는 값은 그대로.
def post: if . == "건너뜀" then "skipped"
          else (capture("^(?<k>통과|실패) (?<s>[0-9]+)초$") // null) as $m
          | if $m == null then . else "\(if $m.k == "통과" then "passed" else "failed" end) in \($m.s)s" end end;
($issues | sort_by(order, .number) | map(. as $i
  | ($recs | map(select(.issue == $i.number)) | sort_by(.finished)) as $rs | ($rs | last) as $r
  | ($prs | map(select(.headRefName | startswith($prefix + ($i.number | tostring) + "-")))
     | (map(select(.state == "MERGED")) + .) | (map(select(.number == $r.pr)) + .) | first) as $pr
  | {issue: $i, pr: $pr, rec: $r, attempts: ($rs | length),
     status: (if $pr.state == "MERGED" then "merged" elif $i.state == "closed" then "closed-without-pr"
              elif $pr.state == "OPEN" then "pr-open" elif $r.result == "stopped" then "stopped"
              elif ($i.assignees // 0) > 0 then "in-progress" else "pending" end),
     wall: (if $r.wall_sec != null then {sec: $r.wall_sec, src: "loop"}
            elif $pr.mergedAt != null then {sec: (($pr.mergedAt | epoch) - ($pr.createdAt | epoch)), src: "pr"} else null end),
     model: ($r.model // "not recorded")})) as $rows
| ($rows | map(select(.status == "merged")) | length) as $merged
| ($rows | map(select(.issue.state == "closed")) | length) as $closed
| ($rows | map(select(.wall.src == "loop") | .wall.sec) | add // 0) as $total
| ($rows | map(.model) | map(select(. != "not recorded")) | unique | join(", ")) as $models
| "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  + @html "<title>#\($spec.number) \($spec.title) — Loop report</title>"
  + "<style>:root{--ink:#1c1f24;--muted:#5b6270;--line:#d9dde3;--soft:#f4f6f8;--bg:#fff;--accent:#2457c5;--ok:#1f7a4d;--ok-soft:#e6f4ec;--warn:#9a6700;--warn-soft:#fff6d6;--bad:#b4441c;--bad-soft:#fbeee8}"
  + "@media (prefers-color-scheme:dark){:root{--ink:#e6e8eb;--muted:#9aa3ad;--line:#3a4047;--soft:#22262b;--bg:#15181b;--accent:#7ea2ff;--ok:#5fcf8f;--ok-soft:#1c3327;--warn:#e3b341;--warn-soft:#3a3012;--bad:#ff8a65;--bad-soft:#3b2219}}"
  + "*{box-sizing:border-box}body{margin:0;padding:24px 16px 48px;color:var(--ink);background:var(--bg);font-family:system-ui,-apple-system,\"Segoe UI\",\"Apple SD Gothic Neo\",\"Noto Sans KR\",sans-serif;font-size:14px;line-height:1.55}"
  + "main{max-width:1200px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}a{color:var(--accent);text-decoration:none}.kicker{color:var(--accent);font-weight:700;font-size:12px;letter-spacing:.06em}"
  + ".meta{color:var(--muted);font-size:13px;margin:0 0 18px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin:0 0 20px}"
  + ".kpi{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:10px 12px}.kpi .v{font-size:20px;font-weight:700}.kpi .l{color:var(--muted);font-size:12px}"
  + ".wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{border:1px solid var(--line);padding:8px 10px;vertical-align:top;text-align:left}th{background:var(--soft);white-space:nowrap}"
  + "td.nw{white-space:nowrap}.bits{margin-top:4px;color:var(--muted);font-size:12px}.reason{margin-top:4px;color:var(--bad);font-size:12px}.muted{color:var(--muted)}.small{font-size:12px}"
  + ".badge{display:inline-block;font-size:12px;font-weight:700;border-radius:10px;padding:0 8px;border:1px solid var(--line);white-space:nowrap}.badge.ok{color:var(--ok);background:var(--ok-soft)}"
  + ".badge.warn{color:var(--warn);background:var(--warn-soft)}.badge.bad{color:var(--bad);background:var(--bad-soft)}.badge.muted{color:var(--muted);background:var(--soft)}footer{margin-top:20px;color:var(--muted);font-size:12px}</style></head>"
  + "<body><main><div class=\"kicker\">Unattended ticket loop · Spec report</div>"
  + @html "<h1><a href=\"\($spec.url)\">#\($spec.number)</a> \($spec.title)</h1>"
  + "<p class=\"meta\">Spec " + (if ($rows | length) > 0 and $closed == ($rows | length) then "complete (all sub-tickets closed)" else "in progress (\($closed)/\($rows | length) closed)" end)
  + " · generated \($now) · spec issue " + (if $spec.state == "CLOSED" then "closed" else "open" end) + "</p>"
  + "<div class=\"kpis\"><div class=\"kpi\"><div class=\"v\">\($rows | length)</div><div class=\"l\">Tickets</div></div><div class=\"kpi\"><div class=\"v\">\($merged)</div><div class=\"l\">Merged</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($total | dur)</div><div class=\"l\">Total loop wall-clock (recorded tickets)</div></div>"
  + @html "<div class=\"kpi\"><div class=\"v\">\(if $models == "" then "not recorded" else $models end)</div><div class=\"l\">Models used</div></div></div>"
  + "<div class=\"wrap\"><table><thead><tr><th>Issue</th><th>Ticket</th><th>Status</th><th>Result brief</th><th>Elapsed</th><th>Model</th><th>Finished</th></tr></thead><tbody>"
  + ($rows | map(
      @html "<tr><td class=\"nw\"><a href=\"\(.issue.url)\">#\(.issue.number)</a></td><td>\(.issue.title)</td>"
      + "<td><span class=\"badge \(.status | badge | .[1])\">\(.status | badge | .[0])</span></td><td>"
      + (if .pr then @html "<div><a href=\"\(.pr.url)\">PR #\(.pr.number)</a> \(.pr.title)</div>"
                      + ((.pr.body // "" | checks) | if .total > 0 then "<div>Acceptance criteria \(.checked)/\(.total)</div>" else "" end)
         elif .rec == null then "<span class=\"muted\">no record</span>" else "" end)
      + (if .rec.result == "stopped" and .status != "merged" then @html "<div class=\"reason\">Stop reason: \(.rec.reason // "—")</div>" else "" end)
      + (if .rec then "<div class=\"bits\">" + ([
            (if .rec.ci_sec == null then empty elif .rec.ci_sec < 0 then "no CI (path excluded from CI)" else "CI \(.rec.ci_sec | dur)" end),
            "\(.rec.repairs // 0) repair\(if (.rec.repairs // 0) == 1 then "" else "s" end)",
            (if .rec.post_merge then @html "post-merge check \(.rec.post_merge | post)" else empty end),
            (if .attempts > 1 then "\(.attempts) attempts" else empty end)] | join(" · ")) + "</div>" else "" end)
      + "</td><td class=\"nw\">" + (if .wall == null then "—" else (.wall.sec | dur) + (if .wall.src == "pr" then "<div class=\"muted small\">PR created→merged</div>" else "" end) end) + "</td>"
      + @html "<td class=\"nw\">\(.model)</td>"
      + "<td class=\"nw\">" + (if .rec then (.rec.finished | when) elif .pr.mergedAt then (.pr.mergedAt | when) else "—" end) + "</td></tr>") | join("\n"))
  + "</tbody></table></div><footer>Elapsed is wall-clock time from when the loop created the worktree to when merge and cleanup finished. Tickets with no loop record use PR created→merged time instead.</footer></main></body></html>"
JQ

# --parent 실행이 정상 종료하면 스펙 리포트 HTML을 쓴다. 생성 실패는 루프 결과를 바꾸지 않는다(로그만).
# 리포트는 커밋하지 않는다 — 사람이 보고 PR로 올린다(루프가 도는 동안 기본 브랜치 직접 커밋 금지).
write_spec_report() {
  [[ -n "$PARENT" ]] || return 0
  local out="$REPORT_DIR/spec-${PARENT}.html" records="$RECORDS_FILE" spec issues prs recs
  [[ "$out" == /* ]] || out="$ROOT/$out"
  [[ "$records" == /* ]] || records="$ROOT/$records"
  if spec="$(gh issue view "$PARENT" --json number,title,state,url)" \
    && issues="$(gh api "repos/${OWNER_REPO}/issues/${PARENT}/sub_issues?per_page=100" --paginate \
         --jq '.[] | {number, title, state, url: .html_url, assignees: (.assignees | length)}' | jq -s '.')" \
    && prs="$(gh pr list --state all --limit 300 --json number,title,body,state,url,createdAt,mergedAt,headRefName)" \
    && recs="$( { [[ -f "$records" ]] && grep '^{' "$records" || true; } | jq -s --argjson spec "$PARENT" 'map(select(.spec == $spec))')" \
    && mkdir -p "$(dirname "$out")" \
    && jq -rn --argjson spec "$spec" --argjson issues "$issues" --argjson prs "$prs" --argjson recs "$recs" \
         --arg prefix "$BRANCH_PREFIX" --arg now "$(date '+%Y-%m-%d %H:%M')" "$REPORT_JQ" > "$out"; then
    log "스펙 #${PARENT} 리포트: ${out#"$ROOT"/} — 확인 뒤 PR로 커밋하세요"
  else
    log "스펙 #${PARENT} 리포트 생성 실패 — ticket-loop.sh --parent ${PARENT}를 다시 돌리면 다시 만든다"
  fi
}

# ---------- 티켓 하나 ----------

run_ticket() {
  local n="$1" title="$2"
  local deadline=$(( $(date +%s) + TICKET_TIMEOUT_SEC )) started_at ci_sec=0 ci_started
  started_at="$(date +%s)"
  IDLE_FALSE_POSITIVES=0
  POST_MERGE_RESULT="건너뜀"
  log "=== #${n} ${title} ==="
  CUR_N="$n"; CUR_TITLE="$title"; CUR_STARTED="$started_at"; CUR_STARTED_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  CUR_PR=""; CUR_MODEL=""; CUR_CI_SEC=""; CUR_ROUND=0

  git -C "$ROOT" fetch -q origin "$BASE_BRANCH"

  local wt wt_path orca_branch handle
  WT=""; WT_PATH=""; WT_BRANCH=""; HANDLE=""
  backend_worktree_create "${n}" "$(worker_prompt "${n}")"
  wt="$WT"; wt_path="$WT_PATH"; orca_branch="$WT_BRANCH"; handle="$HANDLE"
  backend_set_status "${wt}" in-progress || true
  log "#${n}: 워크트리 ${wt} (${wt_path}) / 터미널 ${handle}"
  ensure_agent_started "${n}" "${handle}"
  CUR_MODEL="$(detect_model "${handle}")"

  local pr rc=0 model_now
  pr="$(wait_for_pr "${n}" "${handle}" "$deadline")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "#${n}: 워커 출력 꼬리 ---"; terminal_tail "${handle}" >&2 || true
    backend_set_status "${wt}" todo "" "루프 중단: PR 없이 멈춤 — 확인 필요" || true
    [[ $rc -ne 2 ]] || die "#${n}: 티켓 타임아웃(${TICKET_TIMEOUT_SEC}s)"
    [[ $rc -ne 3 ]] || die "#${n}: ${BACKEND_NAME} 터미널 ${handle} 에 닿지 못했습니다 (${BACKEND_NAME} 앱 종료?). 워크트리는 디스크에 남아 있습니다."
    die "#${n}: 워커가 PR 없이 멈췄습니다 (질문·실패 가능). ${BACKEND_NAME}에서 ${BRANCH_PREFIX}${n} 워크트리를 확인하세요."
  fi
  log "#${n}: PR #${pr} 열림"
  CUR_PR="$pr"; model_now="$(detect_model "${handle}")"; [[ -z "$model_now" ]] || CUR_MODEL="$model_now"
  backend_set_status "${wt}" in-review "${pr}" "PR #${pr} — CI 대기" || true

  local round=0 state before
  while :; do
    state="$(mergeable_state "${pr}")"
    if [[ "$state" == "CONFLICTING" ]]; then
      [[ ${round} -lt $REPAIR_ROUNDS ]] || die "#${n}: PR #${pr} 이 ${BASE_BRANCH}과 충돌합니다 (수리 ${REPAIR_ROUNDS}회 소진)"
      round=$((round + 1)); CUR_ROUND=$round; log "#${n}: 충돌 → 워커에 수리 요청 (${round})"
      repair "${handle}" "PR #${pr} 이 ${BASE_BRANCH}과 충돌한다. \`git fetch origin && git merge origin/${BASE_BRANCH}\`으로 충돌을 해결하고 테스트·lint를 다시 돌린 뒤 같은 브랜치에 push해라. 질문하지 말고 끝까지 해라." "$deadline" \
        || die "#${n}: 충돌 수리 중 타임아웃"
      continue
    fi
    if ! ci_expected "${pr}"; then
      log "#${n}: 저장소 CI의 경로 필터에 걸리는 PR(${CI_SKIP_CMD:+CI_SKIP_CMD}${CI_SKIP_CMD:-CI_SKIP_REGEX}) — 체크 없이 병합한다 (PR #${pr})"
      ci_sec=-1
      break
    fi
    log "#${n}: CI 대기 (PR #${pr})"
    ci_started="$(date +%s)"
    if ci_passed "${pr}"; then ci_sec=$(( $(date +%s) - ci_started )); break; fi
    [[ ${round} -lt $REPAIR_ROUNDS ]] || die "#${n}: PR #${pr} CI 실패 (수리 ${REPAIR_ROUNDS}회 소진). gh pr checks ${pr} 로 확인하세요."
    round=$((round + 1)); CUR_ROUND=$round; log "#${n}: CI 실패 → 워커에 수리 요청 (${round})"
    before="$(pr_head_sha "${pr}")"
    repair "${handle}" "PR #${pr} 의 CI가 실패했다. \`gh pr checks ${pr}\` 와 \`gh run view --log-failed\` 로 원인을 보고 고친 뒤 테스트·lint를 다시 돌리고 같은 브랜치에 push해라. 테스트를 건너뛰거나 지우지 마라. 질문하지 말고 끝까지 해라." "$deadline" \
      || die "#${n}: CI 수리 중 타임아웃"
    [[ "$(pr_head_sha "${pr}")" != "$before" ]] || die "#${n}: 수리 뒤에도 새 커밋이 push되지 않았습니다"
  done
  log "#${n}: CI 통과"
  CUR_CI_SEC="$ci_sec"

  if [[ $NO_MERGE -eq 1 ]]; then
    log "#${n}: --no-merge — PR #${pr} 을 사람이 병합하세요. 워크트리는 남겨 둡니다(${wt})."
    record_ticket "no-merge"; CUR_N=""
    return 0
  fi

  gh pr merge "${pr}" "--$MERGE_METHOD" || die "#${n}: PR #${pr} 병합 실패"
  log "#${n}: PR #${pr} 병합됨"
  sleep 5
  if [[ "$(gh issue view "${n}" --json state -q .state)" != "CLOSED" ]]; then
    gh issue close "${n}" --comment "PR #${pr} 병합으로 완료 (ticket-loop)" || true
  fi
  gh issue edit "${n}" --remove-label "$IN_REVIEW_LABEL" >/dev/null 2>&1 || true
  close_spec_if_done "$(spec_of_ticket "${n}")"

  # 병합된 기본 브랜치로 무거운 검증 — CI가 안 붙는 문서 PR은 건너뛴다. 실패하면 기본 브랜치가 깨진 것이므로
  # 다음 티켓을 쌓지 않고 멈춘다(워커 워크트리는 이미 병합됐으니 정리하고, 검증 워크트리와 로그를 남긴다).
  local post_rc=0
  if [[ $POST_MERGE -eq 1 && $ci_sec -ge 0 ]]; then
    run_post_merge "${n}" || post_rc=$?
  fi

  local branch; branch="$(gh pr view "${pr}" --json headRefName -q .headRefName)"
  backend_set_status "${wt}" completed "${pr}" "PR #${pr} 병합 완료" || true
  backend_worktree_remove "${wt}" "${wt_path}" || log "#${n}: 워크트리 삭제 실패 — 수동 정리 필요 (${wt}, ${wt_path})"
  git -C "$ROOT" worktree prune || true
  git -C "$ROOT" branch -D "${branch}" >/dev/null 2>&1 || true
  if [[ -n "$orca_branch" && "$orca_branch" != "HEAD" && "$orca_branch" != "$BASE_BRANCH" ]]; then
    git -C "$ROOT" branch -D "${orca_branch}" >/dev/null 2>&1 || true
  fi
  git -C "$ROOT" push -q origin --delete "${branch}" >/dev/null 2>&1 || true
  log "#${n} 요약: 벽시계 $(( ($(date +%s) - started_at) / 60 ))분, PR #${pr}, CI $([[ $ci_sec -ge 0 ]] && echo "${ci_sec}초" || echo "없음(CI 제외 경로)"), 수리 ${round}회, idle 오판 ${IDLE_FALSE_POSITIVES}회, 병합 뒤 검증 ${POST_MERGE_RESULT}"
  record_ticket "merged"; CUR_N=""
  [[ $post_rc -eq 0 ]] || die "#${n}: 병합된 ${BASE_BRANCH}에서 병합 뒤 검증이 실패했습니다. 로그와 검증 워크트리($(post_merge_worktree_path))를 확인하고 수정 PR 뒤에 다시 실행하세요."
  notify "티켓 완료" "#${n} ${title}"
}

# ---------- 메인 ----------

backend_check
targets="$(pick_targets)"
log "저장소 ${OWNER_REPO} / 백엔드 ${BACKEND_NAME} / 기준 브랜치 ${BASE_BRANCH} / 라벨 ${READY_LABEL}${SCOPE_LABEL:+ + ${SCOPE_LABEL}}${PARENT:+ / 스펙 #${PARENT}의 하위 이슈}"
log "병합 뒤 검증: $([[ $POST_MERGE -eq 1 ]] && echo "실행 — ${POST_MERGE_CMD}" || echo "끔")"
if [[ $POST_MERGE -eq 1 && -n "$POST_MERGE_PORT" ]] && port_in_use "$POST_MERGE_PORT"; then
  log "주의: 포트 ${POST_MERGE_PORT} 사용 중($(port_holder "$POST_MERGE_PORT" || true)) — 루프가 도는 동안 비워 두세요. 그대로면 병합마다 비기를 최대 $((PORT_WAIT_SEC / 60))분 기다린다(끄려면 --skip-post-merge)"
fi
# 티켓이 더 없어도 --parent면 스펙 닫기·리포트는 다시 한다(사람이 마지막 티켓을 닫은 스펙, 끝난 스펙의 리포트를 다시 뽑는 길)
[[ -n "$targets" ]] || { log "처리할 티켓이 없습니다."; [[ $DRY_RUN -eq 1 ]] || { close_spec_if_done "$PARENT"; write_spec_report; suggest_retro; }; exit 0; }
log "대상(현재 선행 이슈가 모두 닫힌 것):"; printf '%s\n' "$targets" | sed 's/^/  #/' >&2
[[ $DRY_RUN -eq 0 ]] || exit 0

# 목록을 stdin으로 물리지 않는다 — 루프 안의 gh·백엔드 CLI·git이 stdin을 읽으면 다음 티켓이 사라진다.
# 자동 선택이면 티켓 하나가 끝날 때마다 대상을 다시 계산해, 막 풀린 선행 관계를 반영한다.
done_count=0
PROCESSED=""
while :; do
  if [[ ${#TICKETS[@]} -gt 0 ]]; then
    [[ $done_count -lt ${#TICKETS[@]} ]] || break
    n="${TICKETS[$done_count]}"; title="$(issue_title "${n}")"
    [[ "$(blocked_by "${n}")" == "0" ]] || die "#${n}: 선행 이슈가 열려 있습니다"
    [[ -z "$(open_pr_for "${n}")" ]] || die "#${n}: 이미 열린 PR이 있습니다"
  else
    [[ $done_count -eq 0 ]] || targets="$(pick_targets </dev/null)"
    # 이번 실행에서 이미 처리한 티켓은 다시 집지 않는다(이슈 닫힘 반영이 늦는 경우 대비)
    n=""
    while IFS=$'\t' read -r cand ctitle; do
      [[ -n "${cand}" && " ${PROCESSED} " != *" ${cand} "* ]] || continue
      n="${cand}"; title="${ctitle}"; break
    done <<<"$targets"
    [[ -n "${n}" ]] || { log "더 처리할 티켓이 없습니다."; break; }
  fi
  run_ticket "${n}" "${title}" </dev/null
  PROCESSED="${PROCESSED} ${n}"
  done_count=$((done_count + 1))
  [[ $MAX -eq 0 || $done_count -lt $MAX ]] || { log "--max $MAX 도달"; break; }
done

close_spec_if_done "$PARENT"
write_spec_report
suggest_retro
log "완료: ${done_count}건"
notify "티켓 루프 종료" "${done_count}건 완료$([[ -z "${CLOSED_SPECS// /}" ]] || echo " · 스펙${CLOSED_SPECS// / #} 끝 — 원하면 /retro로 회고")"
