#!/usr/bin/env bash
set -euo pipefail

# ticket-loop.sh — GitHub 이슈 티켓을 Orca 워크트리에서 한 건씩 무인 처리한다.
# 가이드: 「Orca 티켓 무인 루프 가이드북」 3판 (agent-loop-kit docs/). 이 파일은 agent-loop-kit이 관리한다 — 고치면 키트에서 고친다.
#
# 티켓 하나당:
#   1. 기본 브랜치에서 Orca 워크트리를 새로 만들고 에이전트(Claude Code)에 `/implement N`을 보낸다
#      (티켓마다 새 프로세스라 컨텍스트가 비어 있다)
#   2. 워커가 `<BRANCH_PREFIX>N-<slug>` 브랜치로 PR을 열 때까지 기다린다
#   3. CI를 기다리고, 충돌·CI 실패는 같은 워커에 REPAIR_ROUNDS회까지 고치게 한다
#   4. PR을 병합한다 → 본문의 `Closes #N`으로 이슈가 닫힌다
#   5. (선택) 병합된 기본 브랜치로 POST_MERGE_CMD를 한 번 돌린다 — 워커가 못 돌리는 무거운 검증. 실패하면 멈춘다
#   6. 워크트리·브랜치를 지우고, 티켓 요약 한 줄을 로그에, 기록 한 줄을 RECORDS_FILE에 남기고, 다음 티켓으로 간다
#      (자동 선택이면 대상 재계산)
#   7. `--parent` 실행이 정상 종료하면 스펙 리포트 HTML(티켓별 결과·경과 시간·모델 표)을 REPORT_DIR/spec-<N>.html에 쓴다
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
# 전제: Orca 앱 실행 중, Orca CLI 등록, `gh auth status` 로그인, 저장소 안에서 실행.
# 진행 로그는 기본으로 .orca-loop/loop-MMDD.log에 덧붙인다(.gitignore에 /.orca-loop/*.log 권장).
# 티켓마다 "#N 요약: …" 한 줄(벽시계·PR·CI 소요·수리·idle 오판·병합 뒤 검증)을 남겨 /retro가 읽는다.
# 같은 내용 + 모델을 RECORDS_FILE(JSONL)에도 남기고, 스펙 리포트가 GitHub의 PR과 합쳐 표로 만든다.
# 저장소별 설정은 .orca-loop/loop.env에 둔다(있으면 읽는다). 그 파일은 `VAR="${VAR:-값}"` 꼴로 써서
# 실행할 때 준 환경변수가 이기게 한다. 예: CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}" POST_MERGE_PORT="${POST_MERGE_PORT:-3000}"
#
# 환경변수(선택):
#   ORCA_CLI            Orca CLI 실행 파일 (기본: ORCA_CLI_COMMAND → Linux면 orca-ide → orca)
#   SPEC_ISSUE          --parent 기본값
#   SCOPE_LABEL         함께 요구할 라벨(--label 기본값)
#   READY_LABEL         대상 라벨 (기본 ready-for-agent)
#   IN_REVIEW_LABEL     PR이 열린 티켓 라벨 (기본 in-review)
#   BRANCH_PREFIX       이슈 브랜치 접두사 (기본 issue-)
#   BASE_BRANCH         기준 브랜치 (기본: 저장소 기본 브랜치)
#   ORDER_REGEX         제목에서 순번을 뽑는 정규식, 이름 있는 그룹 n (기본 ^T(?<n>[0-9]+))
#   WORKER_RULES_FILE   워커가 추가로 따를 규칙 파일 (기본 .orca-loop/worker-rules.md)
#   AGENT               Orca 에이전트 ID (기본 claude)
#   AGENT_BANNER_REGEX  에이전트가 떴는지 확인할 화면 문구 (기본: Claude Code 배너·모델명)
#   AGENT_RESTART_CMD   에이전트가 뜨지 않았을 때 셸에서 다시 띄울 명령. 프롬프트는 인자로 붙는다
#                       (기본 claude --dangerously-skip-permissions — Orca가 워커를 띄우는 방식과 같게)
#   TICKET_TIMEOUT_SEC  티켓 한 건 제한 시간 (기본 14400 = 4시간)
#   MERGE_METHOD        merge | squash | rebase (기본 merge)
#   REPAIR_ROUNDS       충돌·CI 수리 횟수 합계 (기본 1)
#   CI_SKIP_REGEX       바뀐 파일이 전부 이 정규식(ERE)에 맞으면 CI가 안 붙는 게 정상인 PR로 보고 체크 없이 병합한다.
#                       ci.yml의 paths-ignore와 같게 맞춘다 (기본 없음 = 모든 PR에서 체크를 기다린다)
#   POST_MERGE_CMD      병합 뒤 기본 브랜치에서 돌릴 명령, 예 "npm ci && npm run test:e2e" (기본 없음 = 끔)
#   POST_MERGE_COPY     POST_MERGE_CMD 전에 메인 체크아웃에서 복사할 파일들(공백 구분), 예 ".env.local"
#   POST_MERGE_PORT     POST_MERGE_CMD가 쓰는 포트. 지정하면 비기를 기다린다(기본 없음)
#   POST_MERGE_WORKTREE POST_MERGE_CMD를 돌릴 워크트리 (기본 ~/.cache/ticket-loop/<owner-repo>/post-merge, 저장소 밖)
#   LOG_FILE            진행 로그 파일 (기본 .orca-loop/loop-MMDD.log, /dev/null이면 끔)
#   RECORDS_FILE        티켓별 기록 JSONL (기본 .orca-loop/tickets.jsonl, 기계별 — 커밋하지 않는다)
#   REPORT_DIR          스펙 리포트 HTML 디렉터리 (기본 docs/loop-reports — 리포트는 사람이 PR로 커밋)
#   MODEL_REGEX         워커 터미널에서 모델 이름을 뽑는 정규식(ERE). 기본은 Claude Code 상태줄·배너의 "Opus 5.5" 꼴
#
# 멈추는 조건(루프 종료, 워크트리는 조사용으로 남긴다):
#   - 워커가 PR 없이 멈춤(질문·실패) / 티켓 타임아웃 / Orca 터미널 끊김 / 에이전트 기동 실패
#   - 수리 REPAIR_ROUNDS회 뒤에도 CI 실패 또는 충돌
#   - 병합 뒤 POST_MERGE_CMD 실패, 또는 POST_MERGE_PORT가 10분 안에 비지 않음(기다리는 동안은 로그 한 줄 뒤 조용하다 — 멈춤이 아니다)
# 자동 선택은 선행 이슈가 열렸거나, PR이 이미 있거나, 담당자가 있거나, 하위 이슈를 가진(스펙) 이슈를 건너뛴다.

LOOP_ENV="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.orca-loop/loop.env"
# shellcheck source=/dev/null
[[ ! -f "$LOOP_ENV" ]] || source "$LOOP_ENV"

if [[ -n "${ORCA_CLI:-}" ]]; then :
elif [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then ORCA_CLI="$ORCA_CLI_COMMAND"
elif [[ "$(uname -s)" == "Linux" ]]; then ORCA_CLI="orca-ide"   # Linux의 orca는 GNOME 스크린리더다
else ORCA_CLI="orca"
fi
PARENT="${SPEC_ISSUE:-}"
SCOPE_LABEL="${SCOPE_LABEL:-}"
READY_LABEL="${READY_LABEL:-ready-for-agent}"
IN_REVIEW_LABEL="${IN_REVIEW_LABEL:-in-review}"
BRANCH_PREFIX="${BRANCH_PREFIX:-issue-}"
BASE_BRANCH="${BASE_BRANCH:-}"
ORDER_REGEX="${ORDER_REGEX:-^T(?<n>[0-9]+)}"
WORKER_RULES_FILE="${WORKER_RULES_FILE:-.orca-loop/worker-rules.md}"
AGENT="${AGENT:-claude}"
AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-Claude Code|Opus|Sonnet|Fable|Haiku}"
AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-claude --dangerously-skip-permissions}"
TICKET_TIMEOUT_SEC="${TICKET_TIMEOUT_SEC:-14400}"
MERGE_METHOD="${MERGE_METHOD:-merge}"
REPAIR_ROUNDS="${REPAIR_ROUNDS:-1}"
CI_SKIP_REGEX="${CI_SKIP_REGEX:-}"
POST_MERGE_CMD="${POST_MERGE_CMD:-}"
POST_MERGE_COPY="${POST_MERGE_COPY:-}"
POST_MERGE_PORT="${POST_MERGE_PORT:-}"
POST_MERGE_WORKTREE="${POST_MERGE_WORKTREE:-}"
LOG_FILE="${LOG_FILE:-.orca-loop/loop-$(date +%m%d).log}"
RECORDS_FILE="${RECORDS_FILE:-.orca-loop/tickets.jsonl}"
REPORT_DIR="${REPORT_DIR:-docs/loop-reports}"
MODEL_REGEX="${MODEL_REGEX:-(Opus|Sonnet|Haiku|Fable|Mythos)[[:space:]]+[0-9]+(\.[0-9]+)?}"
IDLE_WAIT_MS=600000       # tui-idle 1회 대기 상한
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

for tool in "$ORCA_CLI" gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || die "${tool} 이(가) 없습니다."
done

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
REPO_ID="$("$ORCA_CLI" repo list --json \
  | jq -r --arg key "github.com/${OWNER_REPO}" \
      '.result.repos[] | select(.gitRemoteIdentity.canonicalKey == $key) | .id' | head -n1)"
[[ -n "$REPO_ID" ]] || die "Orca에 ${OWNER_REPO} 저장소가 없습니다. '${ORCA_CLI} repo add --path ${ROOT} --json'으로 등록하세요."

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

# ---------- Orca ----------

orca_json() { "$ORCA_CLI" "$@" --json; }

terminal_idle() {
  # 반환 0: idle 확인, 1: 타임아웃(아직 작업 중), 3: Orca 터미널에 닿지 못함(앱 종료 등)
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

terminal_tail() {
  orca_json terminal read --terminal "$1" | jq -r '.result.terminal.tail[]?' | tail -n 25
}

send_prompt() {
  orca_json terminal send --terminal "$1" --text "$2" --enter --wait-submit 15 \
    | jq -e '.result.send.accepted == true' >/dev/null \
    || die "프롬프트 전송이 수락되지 않았습니다 (terminal $1)"
}

worker_prompt() {
  # 한 줄로 보낸다 — TUI에서는 줄바꿈이 곧 제출이다.
  # 절차(선행 확인·브랜치·seam·리뷰·PR 본문·라벨·병합 금지)는 저장소의 implement 스킬이 단일 진실이다.
  # 여기에는 무인 실행에서만 참인 것만 둔다 — 질문 금지, 막히면 코멘트 후 멈춤, 규칙 파일.
  local n="$1" rules=""
  [[ ! -f "$ROOT/$WORKER_RULES_FILE" ]] || rules=" 저장소의 ${WORKER_RULES_FILE} 규칙도 따라라."
  printf '%s' "/implement ${n} — 무인 루프(ticket-loop.sh)에서 실행 중이다. 사람이 답할 수 없으니 질문(AskUserQuestion)하지 말고 스스로 결정해 끝까지 진행해라. PR은 병합하지 마라 — 루프가 CI 뒤에 병합한다. 진행이 불가능하면(열린 선행 이슈 포함) 이슈 #${n}에 이유를 코멘트로 남기고 PR 없이 멈춰라.${rules}"
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
    promptfile="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-prompt-${n}.XXXXXX")"
    worker_prompt "${n}" > "${promptfile}"
    orca_json terminal send --terminal "${handle}" --text $'\x03' >/dev/null || true   # Ctrl-C로 입력 줄 비움
    sleep 1
    orca_json terminal send --terminal "${handle}" --text "${AGENT_RESTART_CMD} \"\$(cat ${promptfile})\"" --enter >/dev/null \
      || die "#${n}: 재기동 명령 전송 실패"
  done
  die "#${n}: 에이전트가 터미널 ${handle}에서 뜨지 않습니다"
}

# PR이 생길 때까지(또는 워커가 멈출 때까지) 기다린다. 성공 시 PR 번호를 stdout에 쓴다.
# 반환: 0 PR 열림, 1 PR 없이 멈춤, 2 타임아웃, 3 Orca 터미널 끊김
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
    [[ $idle -ne 3 ]] || die "Orca 터미널 ${handle} 에 닿지 못했습니다 (Orca 앱 종료?)"
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

# 반환 0: CI가 도는 PR, 1: 바뀐 파일이 전부 CI_SKIP_REGEX에 맞아 체크가 안 붙는 게 정상인 PR.
# 판정이 안 되면 0(기다리는 쪽).
ci_expected() {
  local files
  [[ -n "$CI_SKIP_REGEX" ]] || return 0
  files="$(gh pr diff "$1" --name-only 2>/dev/null)" || return 0
  [[ -n "$files" ]] || return 0
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

# 워커 터미널의 에이전트 상태줄·배너에서 모델 이름을 뽑는다(Claude Code: "[Opus 5.5 | Max]"). 못 찾으면 빈 값.
detect_model() { terminal_tail "$1" 2>/dev/null | grep -oE "$MODEL_REGEX" | tail -n1 || true; }

# 티켓이 속한 스펙 이슈 번호 — --parent가 없으면(이슈 번호 직접 지정) GitHub의 부모 이슈를 묻는다. 없으면 0.
spec_of_ticket() {
  [[ -z "$PARENT" ]] || { printf '%s' "$PARENT"; return; }
  gh api graphql -f query="{ repository(owner: \"${OWNER_REPO%%/*}\", name: \"${OWNER_REPO#*/}\") { issue(number: $1) { parent { number } } } }" \
    --jq '.data.repository.issue.parent.number // 0' 2>/dev/null || echo 0
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
read -r -d '' REPORT_JQ <<'JQ' || true
def dur: if . == null then "—" elif . >= 3600 then "\(. / 3600 | floor)시간 \((. % 3600) / 60 | floor)분"
         elif . >= 60 then "\(. / 60 | floor)분" else "\(. | floor)초" end;
def epoch: if . == null or . == "" then null else (sub("\\.[0-9]+Z$"; "Z") | fromdate) end;
def when: epoch | if . == null then "—" else strflocaltime("%Y-%m-%d %H:%M") end;
def order: (.title | capture("^T(?<n>[0-9]+)") | .n | tonumber) // 999999;
# jq(Oniguruma Perl 문법)의 ^는 줄 머리가 아니라 문자열 머리다 — 앞에 \n을 붙여 줄 머리를 \n으로 잡는다
def checks: ("\n" + .) | {checked: ([scan("\n[ \t]*[-*] \\[x\\]"; "i")] | length), total: ([scan("\n[ \t]*[-*] \\[[ x]\\]"; "i")] | length)};
def badge: {merged: ["병합", "ok"], "closed-without-pr": ["PR 없이 닫힘", "muted"], "pr-open": ["PR 열림", "warn"],
            "in-progress": ["진행 중", "warn"], stopped: ["중단", "bad"], pending: ["미착수", "muted"]}[.];
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
     model: ($r.model // "미기록")})) as $rows
| ($rows | map(select(.status == "merged")) | length) as $merged
| ($rows | map(select(.issue.state == "closed")) | length) as $closed
| ($rows | map(select(.wall.src == "loop") | .wall.sec) | add // 0) as $total
| ($rows | map(.model) | map(select(. != "미기록")) | unique | join(", ")) as $models
| "<!doctype html>\n<html lang=\"ko\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  + @html "<title>#\($spec.number) \($spec.title) — 루프 리포트</title>"
  + "<style>:root{--ink:#1c1f24;--muted:#5b6270;--line:#d9dde3;--soft:#f4f6f8;--bg:#fff;--accent:#2457c5;--ok:#1f7a4d;--ok-soft:#e6f4ec;--warn:#9a6700;--warn-soft:#fff6d6;--bad:#b4441c;--bad-soft:#fbeee8}"
  + "@media (prefers-color-scheme:dark){:root{--ink:#e6e8eb;--muted:#9aa3ad;--line:#3a4047;--soft:#22262b;--bg:#15181b;--accent:#7ea2ff;--ok:#5fcf8f;--ok-soft:#1c3327;--warn:#e3b341;--warn-soft:#3a3012;--bad:#ff8a65;--bad-soft:#3b2219}}"
  + "*{box-sizing:border-box}body{margin:0;padding:24px 16px 48px;color:var(--ink);background:var(--bg);font-family:\"Apple SD Gothic Neo\",\"Noto Sans KR\",system-ui,sans-serif;font-size:14px;line-height:1.55}"
  + "main{max-width:1200px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}a{color:var(--accent);text-decoration:none}.kicker{color:var(--accent);font-weight:700;font-size:12px;letter-spacing:.06em}"
  + ".meta{color:var(--muted);font-size:13px;margin:0 0 18px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin:0 0 20px}"
  + ".kpi{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:10px 12px}.kpi .v{font-size:20px;font-weight:700}.kpi .l{color:var(--muted);font-size:12px}"
  + ".wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{border:1px solid var(--line);padding:8px 10px;vertical-align:top;text-align:left}th{background:var(--soft);white-space:nowrap}"
  + "td.nw{white-space:nowrap}.bits{margin-top:4px;color:var(--muted);font-size:12px}.reason{margin-top:4px;color:var(--bad);font-size:12px}.muted{color:var(--muted)}.small{font-size:12px}"
  + ".badge{display:inline-block;font-size:12px;font-weight:700;border-radius:10px;padding:0 8px;border:1px solid var(--line);white-space:nowrap}.badge.ok{color:var(--ok);background:var(--ok-soft)}"
  + ".badge.warn{color:var(--warn);background:var(--warn-soft)}.badge.bad{color:var(--bad);background:var(--bad-soft)}.badge.muted{color:var(--muted);background:var(--soft)}footer{margin-top:20px;color:var(--muted);font-size:12px}</style></head>"
  + "<body><main><div class=\"kicker\">ORCA 티켓 무인 루프 · 스펙 리포트</div>"
  + @html "<h1><a href=\"\($spec.url)\">#\($spec.number)</a> \($spec.title)</h1>"
  + "<p class=\"meta\">스펙 " + (if ($rows | length) > 0 and $closed == ($rows | length) then "완료(하위 티켓 전부 닫힘)" else "진행 중(\($closed)/\($rows | length) 닫힘)" end)
  + " · 생성 \($now) · 스펙 이슈 " + (if $spec.state == "CLOSED" then "닫힘" else "열림" end) + "</p>"
  + "<div class=\"kpis\"><div class=\"kpi\"><div class=\"v\">\($rows | length)</div><div class=\"l\">티켓</div></div><div class=\"kpi\"><div class=\"v\">\($merged)</div><div class=\"l\">병합</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($total | dur)</div><div class=\"l\">루프 벽시계 합계(기록 있는 티켓)</div></div>"
  + @html "<div class=\"kpi\"><div class=\"v\">\(if $models == "" then "미기록" else $models end)</div><div class=\"l\">사용 모델</div></div></div>"
  + "<div class=\"wrap\"><table><thead><tr><th>이슈</th><th>티켓</th><th>상태</th><th>작업 결과 브리프</th><th>경과 시간</th><th>사용 모델</th><th>마친 시각</th></tr></thead><tbody>"
  + ($rows | map(
      @html "<tr><td class=\"nw\"><a href=\"\(.issue.url)\">#\(.issue.number)</a></td><td>\(.issue.title)</td>"
      + "<td><span class=\"badge \(.status | badge | .[1])\">\(.status | badge | .[0])</span></td><td>"
      + (if .pr then @html "<div><a href=\"\(.pr.url)\">PR #\(.pr.number)</a> \(.pr.title)</div>"
                      + ((.pr.body // "" | checks) | if .total > 0 then "<div>인수 조건 \(.checked)/\(.total)</div>" else "" end)
         elif .rec == null then "<span class=\"muted\">기록 없음</span>" else "" end)
      + (if .rec.result == "stopped" and .status != "merged" then @html "<div class=\"reason\">중단 사유: \(.rec.reason // "—")</div>" else "" end)
      + (if .rec then "<div class=\"bits\">" + ([
            (if .rec.ci_sec == null then empty elif .rec.ci_sec < 0 then "CI 없음(CI 제외 경로)" else "CI \(.rec.ci_sec | dur)" end),
            "수리 \(.rec.repairs // 0)회",
            (if .rec.post_merge then @html "병합 뒤 검증 \(.rec.post_merge)" else empty end),
            (if .attempts > 1 then "시도 \(.attempts)회" else empty end)] | join(" · ")) + "</div>" else "" end)
      + "</td><td class=\"nw\">" + (if .wall == null then "—" else (.wall.sec | dur) + (if .wall.src == "pr" then "<div class=\"muted small\">PR 생성→병합 기준</div>" else "" end) end) + "</td>"
      + @html "<td class=\"nw\">\(.model)</td>"
      + "<td class=\"nw\">" + (if .rec then (.rec.finished | when) elif .pr.mergedAt then (.pr.mergedAt | when) else "—" end) + "</td></tr>") | join("\n"))
  + "</tbody></table></div><footer>경과 시간은 루프가 워크트리를 만든 때부터 병합·정리를 마친 때까지의 벽시계다. 루프 기록이 없는 티켓은 PR 생성→병합 시간으로 대신한다.</footer></main></body></html>"
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

  local created wt wt_path orca_branch handle
  created="$(orca_json worktree create --repo "id:$REPO_ID" --name "${BRANCH_PREFIX}${n}" --no-parent \
    --base-branch "origin/${BASE_BRANCH}" --issue "${n}" --agent "$AGENT" \
    --prompt "$(worker_prompt "${n}")" --comment "티켓 루프: /implement ${n} 진행 중")"
  jq -e '.ok == true' <<<"$created" >/dev/null || die "워크트리 생성 실패: $(jq -c '.error' <<<"$created")"
  wt="$(jq -r '.result.worktree.id' <<<"$created")"
  wt_path="${wt#*::}"
  handle="$(jq -r '.result.agentTerminalHandle // .result.startupTerminal.handle // empty' <<<"$created")"
  [[ -n "${handle}" ]] || die "에이전트 터미널 핸들을 받지 못했습니다 (${wt})"
  # Orca가 워크트리용으로 만든 브랜치(설정에 따라 `issue-N` 또는 `<git 사용자>/issue-N`) — 워커가 브랜치를 바꾸기 전에 기록한다
  orca_branch="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  orca_json worktree set --worktree "id:${wt}" --workspace-status in-progress >/dev/null || true
  log "#${n}: 워크트리 ${wt} / 터미널 ${handle}"
  ensure_agent_started "${n}" "${handle}"
  CUR_MODEL="$(detect_model "${handle}")"

  local pr rc=0 model_now
  pr="$(wait_for_pr "${n}" "${handle}" "$deadline")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "#${n}: 워커 출력 꼬리 ---"; terminal_tail "${handle}" >&2 || true
    orca_json worktree set --worktree "id:${wt}" --unread --workspace-status todo \
      --comment "루프 중단: PR 없이 멈춤 — 확인 필요" >/dev/null || true
    [[ $rc -ne 2 ]] || die "#${n}: 티켓 타임아웃(${TICKET_TIMEOUT_SEC}s)"
    [[ $rc -ne 3 ]] || die "#${n}: Orca 터미널 ${handle} 에 닿지 못했습니다 (Orca 앱 종료?). 워크트리는 디스크에 남아 있습니다."
    die "#${n}: 워커가 PR 없이 멈췄습니다 (질문·실패 가능). Orca에서 ${BRANCH_PREFIX}${n} 워크트리를 확인하세요."
  fi
  log "#${n}: PR #${pr} 열림"
  CUR_PR="$pr"; model_now="$(detect_model "${handle}")"; [[ -z "$model_now" ]] || CUR_MODEL="$model_now"
  orca_json worktree set --worktree "id:${wt}" --pr "${pr}" --workspace-status in-review \
    --comment "PR #${pr} — CI 대기" >/dev/null || true

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
      log "#${n}: CI_SKIP_REGEX 경로만 바뀐 PR — CI 없이 병합한다 (PR #${pr})"
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

  # 병합된 기본 브랜치로 무거운 검증 — CI가 안 붙는 문서 PR은 건너뛴다. 실패하면 기본 브랜치가 깨진 것이므로
  # 다음 티켓을 쌓지 않고 멈춘다(워커 워크트리는 이미 병합됐으니 정리하고, 검증 워크트리와 로그를 남긴다).
  local post_rc=0
  if [[ $POST_MERGE -eq 1 && $ci_sec -ge 0 ]]; then
    run_post_merge "${n}" || post_rc=$?
  fi

  local branch; branch="$(gh pr view "${pr}" --json headRefName -q .headRefName)"
  orca_json worktree set --worktree "id:${wt}" --workspace-status completed --comment "PR #${pr} 병합 완료" >/dev/null || true
  orca_json worktree rm --worktree "id:${wt}" --force >/dev/null || log "#${n}: 워크트리 삭제 실패 — 수동 정리 필요 (${wt})"
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

targets="$(pick_targets)"
log "저장소 ${OWNER_REPO} / 기준 브랜치 ${BASE_BRANCH} / 라벨 ${READY_LABEL}${SCOPE_LABEL:+ + ${SCOPE_LABEL}}${PARENT:+ / 스펙 #${PARENT}의 하위 이슈}"
log "병합 뒤 검증: $([[ $POST_MERGE -eq 1 ]] && echo "실행 — ${POST_MERGE_CMD}" || echo "끔")"
if [[ $POST_MERGE -eq 1 && -n "$POST_MERGE_PORT" ]] && port_in_use "$POST_MERGE_PORT"; then
  log "주의: 포트 ${POST_MERGE_PORT} 사용 중($(port_holder "$POST_MERGE_PORT" || true)) — 루프가 도는 동안 비워 두세요. 그대로면 병합마다 비기를 최대 $((PORT_WAIT_SEC / 60))분 기다린다(끄려면 --skip-post-merge)"
fi
# 티켓이 더 없어도 --parent면 리포트는 다시 만든다(끝난 스펙의 리포트를 다시 뽑는 길)
[[ -n "$targets" ]] || { log "처리할 티켓이 없습니다."; [[ $DRY_RUN -eq 1 ]] || write_spec_report; exit 0; }
log "대상(현재 선행 이슈가 모두 닫힌 것):"; printf '%s\n' "$targets" | sed 's/^/  #/' >&2
[[ $DRY_RUN -eq 0 ]] || exit 0

# 목록을 stdin으로 물리지 않는다 — 루프 안의 gh·orca·git이 stdin을 읽으면 다음 티켓이 사라진다.
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

write_spec_report
log "완료: ${done_count}건"
notify "티켓 루프 종료" "${done_count}건 완료"
