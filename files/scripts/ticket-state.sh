#!/usr/bin/env bash
set -uo pipefail

# 멈춘 티켓 하나의 상태를 한눈에 본다(이슈·PR·원격 브랜치·워크트리·워커 세션·루프 잠금).
# PR이 병합됐는데 남은 것이 있으면 정리 명령도 찍는다 — 찍기만 하고 지우지 않는다.
# 판정표와 복구 절차: 「티켓 무인 루프 가이드북」 10장 (ticket-loop-kit docs/).
#   bash scripts/ticket-state.sh 41

n="${1:?사용법: ticket-state.sh <이슈 번호>}"; n="${n#\#}"
# 루프와 같은 설정을 읽는다(BACKEND·BRANCH_PREFIX·WORKTREE_DIR·CLI 경로) — 사용자 파일이 먼저 읽혀 이긴다(ticket-loop.sh와 같다)
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
for f in "${XDG_CONFIG_HOME:-$HOME/.config}/ticket-loop/loop.env" "$ROOT/.ticket-loop/loop.env"; do
  # shellcheck source=/dev/null
  [[ ! -f "$f" ]] || source "$f"
done
# 티켓의 브랜치는 워커가 만든 issue-N-<slug>이거나, 워커가 루프의 워크트리 브랜치에 그대로 커밋했으면 issue-N 이다.
# 정확히 같거나 `N-`로 시작하는 것만 본다(issue-1020 은 #102 가 아니다)
b="${BRANCH_PREFIX:-issue-}${n}"
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
BACKEND="${BACKEND:-orca}"
if [[ -z "${CMUX_CLI:-}" ]]; then
  if command -v cmux >/dev/null 2>&1; then CMUX_CLI="cmux"; else CMUX_CLI="/Applications/cmux.app/Contents/Resources/bin/cmux"; fi
fi
TMUX_CLI="${TMUX_CLI:-tmux}"
MAIN_WT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"

echo "== 이슈"
gh issue view "$n" --json state,labels,assignees \
  -q '"\(.state) | 라벨: \([.labels[].name] | join(", ")) | 담당: \([.assignees[].login] | join(", "))"'
echo "== 열린 선행 이슈"
gh api "repos/${OWNER_REPO}/issues/${n}/dependencies/blocked_by" --paginate \
  --jq '.[] | select(.state == "open") | "#\(.number) \(.title)"' | sed 's/^/  /'
echo "== PR"
prs="$(gh pr list --state all --limit 100 --json number,state,headRefName \
  | jq -r --arg b "$b" '.[] | select(.headRefName == $b or (.headRefName | startswith($b + "-"))) | "#\(.number) \(.state) \(.headRefName)"')"
[[ -z "$prs" ]] || printf '%s\n' "$prs"
echo "== 원격 브랜치"
remote="$(git ls-remote --heads origin "refs/heads/${b}" "refs/heads/${b}-*")"
[[ -z "$remote" ]] || printf '%s\n' "$remote"
echo "== 워크트리"
git worktree list | grep -E "/${BRANCH_PREFIX:-issue-}${n}( |-|$)" || echo "(없음)"

# 워커 워크트리의 경로 — 디렉터리가 이미 지워졌어도 워크스페이스·프로세스는 그 경로 문자열로 찾는다. 등록된 워크트리, 루프가 만드는 자리
# (cmux·tmux의 WORKTREE_DIR), 이 티켓의 멈춤 기록에 적힌 경로를 모은다
paths="$({ git worktree list --porcelain | sed -n 's/^worktree //p' | grep -E "/${b}$"
           printf '%s\n' "${WORKTREE_DIR:-$HOME/.cache/ticket-loop/${OWNER_REPO//\//-}/worktrees}/${b}"
           cat "${MAIN_WT:-$ROOT}"/.ticket-loop/stops/*.json 2>/dev/null | jq -r --arg n "$n" 'select((.issue | tostring) == $n) | .worker_worktree // empty' 2>/dev/null
         } | awk 'NF && !seen[$0]++')"
# stdin의 "키<TAB>글" 줄에서, 글 안에 그 경로가 온전히 든 것(뒤가 끝·/·공백·따옴표 — issue-15 가 issue-153 에 걸리지 않게)의 키
under_paths() {
  PATHS="$paths" awk -F'\t' 'BEGIN { k = split(ENVIRON["PATHS"], P, "\n") }
    { for (i = 1; i <= k; i++) { if (P[i] == "") continue; at = index($2, P[i]); if (!at) continue
        c = substr($2, at + length(P[i]), 1); if (c == "" || c == "/" || c == " " || c == "\"" || c == "\047") { print $1; next } } }'
}

echo "== 워커 세션"
# 백엔드 워크스페이스 — "id<TAB>이름<TAB>지금 디렉터리<TAB>어떻게 찾았나(path | name)". 이름만 같은 것은 다른 저장소의 것일 수 있다
ws=""
case "$BACKEND" in
  cmux)
    if out="$(CMUX_QUIET=1 "$CMUX_CLI" workspace list --id-format uuids --json 2>/dev/null)"; then
      all="$(jq -r '.workspaces[]? | [.id, (.custom_title // ""), (.current_directory // "")] | @tsv' <<<"$out" 2>/dev/null)"
    else
      all=""; echo "(cmux 앱에 닿지 못함 — cmux 터미널 안에서 돌려야 워크스페이스가 보인다)"
    fi ;;
  tmux) all="$("$TMUX_CLI" list-windows -a -F "#{window_id}"$'\t'"#{window_name}"$'\t'"#{pane_current_path}" 2>/dev/null)" ;;
  *) all="" ;;   # Orca는 워크트리가 곧 워크스페이스다 — 위 "워크트리" 칸이 전부다
esac
if [[ -n "$all" ]]; then
  by_path="$(awk -F'\t' '{ print $1 "\t" $3 }' <<<"$all" | under_paths)"
  ws="$(BY_PATH="$by_path" awk -F'\t' -v name="$b" 'BEGIN { k = split(ENVIRON["BY_PATH"], B, "\n"); for (i = 1; i <= k; i++) hit[B[i]] = 1 }
    hit[$1] { print $0 "\tpath"; next }
    $2 == name || index($2, name " ") == 1 { print $0 "\tname" }' <<<"$all")"
fi
if [[ -n "$ws" ]]; then
  awk -F'\t' -v be="$BACKEND" '{ printf "%s %s %s \"%s\" %s%s\n", be, (be == "tmux" ? "창" : "워크스페이스"), $1, $2, $3, ($4 == "name" ? "  (이름만 같다 — 다른 저장소의 것일 수 있다)" : "") }' <<<"$ws"
fi
# 에이전트 프로세스 — 그 경로를 지금 디렉터리로 두었거나(디렉터리가 지워져도 lsof·/proc는 그 경로를 보인다) 명령 인자에 그 경로가 든 것
procs="$({ if command -v lsof >/dev/null 2>&1; then
             lsof -d cwd -Fpn 2>/dev/null | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid "\t" substr($0, 2) }'
           else
             for d in /proc/[0-9]*; do c="$(readlink "$d/cwd" 2>/dev/null)" && printf '%s\t%s\n' "${d#/proc/}" "${c% (deleted)}"; done
           fi
           ps -axo pid=,command= 2>/dev/null | awk '{ pid = $1; sub(/^ *[0-9]+ /, ""); print pid "\t" $0 }'
         } | under_paths | sort -un | while read -r pid; do
           [[ "$pid" == "$$" ]] || ps -o pid=,command= -p "$pid" 2>/dev/null | grep -v 'ticket-state\.sh' | sed 's/^ *//' | cut -c1-200
         done)"
[[ -z "$procs" ]] || printf '%s\n' "$procs"
[[ -n "$ws" || -n "$procs" ]] || echo "(없음)"

echo "== 루프 잠금"
ls -d "$(git rev-parse --path-format=absolute --git-common-dir)/ticket-loop.lock" 2>/dev/null || echo "(없음)"
# 루프 본체만 — bash가 ticket-loop.sh를 스크립트로 실행하는 프로세스. 워커의 프롬프트에도 "ticket-loop.sh"라는 글자가 들어 있어
# `pgrep -fl ticket-loop`는 워커를 루프로 찍었다(#68)
ps -axo pid=,command= 2>/dev/null | awk '$2 ~ /(^|\/)-?(ba)?sh$/ { for (i = 3; i <= NF; i++) { if ($i ~ /^-/) continue; if ($i ~ /(^|\/)ticket-loop\.sh$/) print; break } }' | sed 's/^ *//'

# PR이 병합됐고 열린 PR이 없는데 남은 것이 있으면, 루프가 병합 뒤에 하는 정리와 같은 순서의 명령을 찍는다(ticket-loop.sh ticket_cleanup —
# 워크스페이스 → 워크트리 → 로컬 브랜치 → 원격 브랜치). 워크스페이스를 닫으면 그 안의 워커 프로세스도 끝난다
merged="$(awk '$2 == "MERGED"' <<<"$prs")"
if [[ -n "$merged" ]] && ! grep -q ' OPEN ' <<<"$prs"; then
  cmds=""
  while IFS=$'\037' read -r id title _ how; do   # 탭으로 읽으면 빈 칸(지금 디렉터리 없음)이 합쳐진다
    [[ -n "$id" ]] || continue
    case "$BACKEND" in
      tmux) cmds+="${TMUX_CLI} kill-window -t $(printf %q "$id")" ;;
      *) cmds+="$(printf %q "$CMUX_CLI") workspace close ${id} --force" ;;
    esac
    [[ "$how" != name ]] || cmds+="   # \"${title}\" — 이름만 같다. 이 저장소의 것인지 먼저 확인"
    cmds+=$'\n'
  done <<<"$(tr '\t' '\037' <<<"$ws")"
  wts=""
  while IFS= read -r p; do
    [[ -n "$p" && -d "$p" ]] || continue
    if [[ "$BACKEND" == orca ]]; then wts+="${ORCA_CLI:-orca} worktree rm --worktree $(printf %q "path:$p") --force"$'\n'
    else wts+="git worktree remove --force $(printf %q "$p")"$'\n'; fi
  done <<<"$paths"
  # 닫을 워크스페이스가 없는데 프로세스만 남았으면 직접 끝낸다. Orca는 워크트리를 지울 때 그 터미널도 닫는다
  [[ -n "$ws" || -z "$procs" || ( "$BACKEND" == orca && -n "$wts" ) ]] || cmds+="$(awk '{ printf "kill %s   # 워크스페이스 없이 남은 프로세스\n", $1 }' <<<"$procs")"$'\n'
  cmds+="$wts"
  [[ -z "$wts" ]] && ! git worktree list --porcelain | grep -E "^worktree .*/${b}$" >/dev/null || cmds+="git worktree prune"$'\n'
  heads="$(awk '$2 == "MERGED" { print $3 }' <<<"$prs")"
  while IFS= read -r br; do
    [[ -n "$br" ]] && git show-ref --verify -q "refs/heads/${br}" || continue
    cmds+="git branch -D $(printf %q "$br")"$'\n'
  done <<<"$(printf '%s\n%s\n' "$heads" "$b" | awk 'NF && !seen[$0]++')"
  while IFS= read -r br; do
    [[ -n "$br" ]] && grep -q "refs/heads/${br}$" <<<"$remote" || continue
    cmds+="git push origin --delete $(printf %q "$br")"$'\n'
  done <<<"$heads"
  if [[ -n "$cmds" ]]; then
    echo "== 정리 — $(awk '{ printf "%s%s", (k++ ? ", " : ""), $1 }' <<<"$merged") 병합됨, 남은 것이 있다"
    echo "(루프가 병합 뒤에 하는 순서다. 이 티켓의 멈춤 기록이 있으면 다음 루프 실행이 시작할 때 스스로 정리한다)"
    printf '%s' "$cmds" | sed 's/^/  /'
  fi
fi
