#!/usr/bin/env bash
set -uo pipefail

# 멈춘 티켓 하나의 상태를 한눈에 본다(이슈·PR·원격 브랜치·워크트리·루프 잠금).
# 판정표와 복구 절차: 「티켓 무인 루프 가이드북」 10장 (ticket-loop-kit docs/).
#   bash scripts/ticket-state.sh 41

n="${1:?사용법: ticket-state.sh <이슈 번호>}"; n="${n#\#}"
# 티켓의 브랜치는 워커가 만든 issue-N-<slug>이거나, 워커가 루프의 워크트리 브랜치에 그대로 커밋했으면 issue-N 이다.
# 정확히 같거나 `N-`로 시작하는 것만 본다(issue-1020 은 #102 가 아니다)
b="${BRANCH_PREFIX:-issue-}${n}"
OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo "== 이슈"
gh issue view "$n" --json state,labels,assignees \
  -q '"\(.state) | 라벨: \([.labels[].name] | join(", ")) | 담당: \([.assignees[].login] | join(", "))"'
echo "== 열린 선행 이슈"
gh api "repos/${OWNER_REPO}/issues/${n}/dependencies/blocked_by" --paginate \
  --jq '.[] | select(.state == "open") | "#\(.number) \(.title)"' | sed 's/^/  /'
echo "== PR"
gh pr list --state all --limit 100 --json number,state,headRefName \
  | jq -r --arg b "$b" '.[] | select(.headRefName == $b or (.headRefName | startswith($b + "-"))) | "#\(.number) \(.state) \(.headRefName)"'
echo "== 원격 브랜치"
git ls-remote --heads origin "refs/heads/${b}" "refs/heads/${b}-*"
echo "== 워크트리"
git worktree list | grep -E "/${BRANCH_PREFIX:-issue-}${n}( |-|$)" || echo "(없음)"
echo "== 루프 잠금"
ls -d "$(git rev-parse --path-format=absolute --git-common-dir)/ticket-loop.lock" 2>/dev/null || echo "(없음)"
pgrep -fl ticket-loop || true
