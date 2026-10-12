#!/usr/bin/env bash
set -euo pipefail

# 키트 자체 검사: 문법, 부록 D 일치, 임시 저장소에 두 번 설치(네트워크·GitHub·Orca 없이)
#   bash tests/smoke.sh

KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for f in "$KIT"/install.sh "$KIT"/files/scripts/*.sh "$KIT"/docs/build-pdf.sh; do
  bash -n "$f" || fail "문법 오류 $f"
done
echo "ok  bash -n"
node --check "$KIT/bin/ticket-loop-kit.js" || fail "bin/ticket-loop-kit.js 문법 오류"
[[ "$(jq -r .version "$KIT/package.json")" == "$(cat "$KIT/VERSION")" ]] || fail "package.json version 과 VERSION 이 다르다"
[[ "$(node "$KIT/bin/ticket-loop-kit.js" --version)" == "$(cat "$KIT/VERSION")" ]] || fail "--version 이 VERSION 과 다르다"
echo "ok  npx 껍질 문법·버전"

python3 - "$KIT" <<'EOF' || fail "docs/guide.html 부록 D가 files/scripts/ticket-loop.sh와 다르다"
import html, re, sys
kit = sys.argv[1]
h = open(f"{kit}/docs/guide.html", encoding="utf-8").read()
m = re.search(r'<h3>D\..*?<pre class="script"><code>(.*?)</code></pre>', h, re.S)
s = open(f"{kit}/files/scripts/ticket-loop.sh", encoding="utf-8").read().rstrip("\n")
sys.exit(0 if m and html.unescape(m.group(1)) == s else 1)
EOF
echo "ok  부록 D 일치"

T="$(mktemp -d "${TMPDIR:-/tmp}/ticket-loop-kit-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git -C "$T" init -q -b main
git -C "$T" commit -q --allow-empty -m init
run() { (cd "$T" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca >/dev/null); }

run
for f in scripts/ticket-loop.sh scripts/ticket-state.sh scripts/sync-mattpocock-skills.sh \
         .claude/skills/setup-ticket-loop/SKILL.md .claude/skills/implement/SKILL.md .claude/skills/pr/SKILL.md \
         .ticket-loop/worker-rules.md .ticket-loop/kit.json docs/loop-reports/README.md; do
  [[ -f "$T/$f" ]] || fail "설치 뒤 $f 없음"
done
[[ -x "$T/scripts/ticket-loop.sh" ]] || fail "ticket-loop.sh 실행 권한 없음"
jq -e '.permissions.deny | index("Bash(gh pr merge:*)")' "$T/.claude/settings.json" >/dev/null || fail "deny 병합 안 됨"
grep -qxF '/.ticket-loop/*.log' "$T/.gitignore" || fail ".gitignore 줄 없음"
grep -qxF '/.ticket-loop/*.jsonl' "$T/.gitignore" || fail ".gitignore jsonl 줄 없음"
echo "ok  첫 설치"

# 프로젝트 소유 파일은 두 번째 설치에서 유지돼야 한다
echo "project edit" >> "$T/.ticket-loop/worker-rules.md"
jq '.permissions.deny += ["Bash(rm -rf:*)"]' "$T/.claude/settings.json" > "$T/s.json" && mv "$T/s.json" "$T/.claude/settings.json"
cp "$T/.claude/settings.json" "$T/before.json"; cp "$T/.gitignore" "$T/before.gitignore"
run
grep -q "project edit" "$T/.ticket-loop/worker-rules.md" || fail "재설치가 프로젝트 소유 파일을 덮어씀"
cmp -s "$T/before.json" "$T/.claude/settings.json" || fail "재설치가 settings.json을 바꿈"
cmp -s "$T/before.gitignore" "$T/.gitignore" || fail "재설치가 .gitignore에 줄을 또 넣음"
echo "ok  재설치 멱등"

# 0.2 이하가 설치한 저장소(.orca-loop/, setup-orca-loop, 옛 .gitignore 줄)를 옮긴다. 프로젝트 소유 편집과 로그는 따라간다
M="$T/migrate"; mkdir -p "$M/.orca-loop" "$M/.claude/skills/setup-orca-loop"; git -C "$M" init -q -b main
printf 'old rules\n' > "$M/.orca-loop/worker-rules.md"; printf 'CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}"\n' > "$M/.orca-loop/loop.env"
printf 'log line\n' > "$M/.orca-loop/loop-1012.log"; echo old > "$M/.claude/skills/setup-orca-loop/SKILL.md"
printf '/.orca-loop/*.log\n/.orca-loop/*.jsonl\n' > "$M/.gitignore"
git -C "$M" add -A >/dev/null; git -C "$M" -c user.name=t -c user.email=t@t commit -q -m old
(cd "$M" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca >/dev/null 2>&1) || fail "마이그레이션 설치 실패"
[[ ! -e "$M/.orca-loop" && -d "$M/.ticket-loop" ]] || fail ".orca-loop → .ticket-loop 이동 안 됨"
grep -q 'old rules' "$M/.ticket-loop/worker-rules.md" || fail "마이그레이션이 프로젝트 소유 worker-rules.md 를 잃음"
grep -q 'CI_SKIP_REGEX' "$M/.ticket-loop/loop.env" || fail "마이그레이션이 loop.env 를 잃음"
[[ -f "$M/.ticket-loop/loop-1012.log" ]] || fail "마이그레이션이 로그를 잃음"
[[ ! -e "$M/.claude/skills/setup-orca-loop" && -f "$M/.claude/skills/setup-ticket-loop/SKILL.md" ]] || fail "옛 스킬이 남았거나 새 스킬이 없음"
grep -q '^/\.orca-loop/' "$M/.gitignore" && fail ".gitignore 에 옛 줄이 남음"
grep -qxF '/.ticket-loop/*.log' "$M/.gitignore" || fail ".gitignore 에 새 줄이 없음"
git -C "$M" status --porcelain | grep -q '^R  .orca-loop/worker-rules.md -> .ticket-loop/worker-rules.md' || fail "git mv 로 옮기지 않음(이력 끊김)"
echo "ok  0.2 → .ticket-loop 마이그레이션"

# 0.3 이 설치한 저장소(.agent-loop/, setup-agent-loop, 옛 .gitignore 줄)도 같은 길로 옮긴다
M3="$T/migrate3"; mkdir -p "$M3/.agent-loop" "$M3/.claude/skills/setup-agent-loop"; git -C "$M3" init -q -b main
printf 'old rules\n' > "$M3/.agent-loop/worker-rules.md"; printf 'BACKEND="${BACKEND:-cmux}"\n' > "$M3/.agent-loop/loop.env"
printf '{"issue":1}\n' > "$M3/.agent-loop/tickets.jsonl"; echo old > "$M3/.claude/skills/setup-agent-loop/SKILL.md"
printf '/.agent-loop/*.log\n/.agent-loop/*.jsonl\n' > "$M3/.gitignore"
mkdir -p "$M3/docs/agents"; printf '설정은 .agent-loop/loop.env 에 있다\n' > "$M3/docs/agents/ticket-loop.md"   # 옛 경로를 가리키는 프로젝트 문서
git -C "$M3" add -A >/dev/null; git -C "$M3" -c user.name=t -c user.email=t@t commit -q -m old
out="$(cd "$M3" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "0.3 마이그레이션 설치 실패"
grep -q 'old paths' <<<"$out" && grep -q 'docs/agents/ticket-loop.md' <<<"$out" || fail "옛 경로를 가리키는 docs/agents/ticket-loop.md 경고가 없음"
[[ ! -e "$M3/.agent-loop" && -d "$M3/.ticket-loop" ]] || fail ".agent-loop → .ticket-loop 이동 안 됨"
grep -q 'old rules' "$M3/.ticket-loop/worker-rules.md" || fail "0.3 마이그레이션이 worker-rules.md 를 잃음"
grep -qxF 'BACKEND="${BACKEND:-cmux}"' "$M3/.ticket-loop/loop.env" || fail "0.3 마이그레이션이 loop.env 를 잃음"
[[ -f "$M3/.ticket-loop/tickets.jsonl" ]] || fail "0.3 마이그레이션이 기록을 잃음"
[[ ! -e "$M3/.claude/skills/setup-agent-loop" && -f "$M3/.claude/skills/setup-ticket-loop/SKILL.md" ]] || fail "옛 setup-agent-loop 가 남았거나 새 스킬이 없음"
grep -q '^/\.agent-loop/' "$M3/.gitignore" && fail ".gitignore 에 /.agent-loop/ 줄이 남음"
grep -qxF '/.ticket-loop/*.jsonl' "$M3/.gitignore" || fail ".gitignore 에 새 jsonl 줄이 없음"
git -C "$M3" status --porcelain | grep -q '^R  .agent-loop/worker-rules.md -> .ticket-loop/worker-rules.md' || fail "0.3: git mv 로 옮기지 않음(이력 끊김)"
# 둘 다 있고 새 경로는 없으면 첫 번째(.agent-loop)만 옮기고 .orca-loop 는 경고와 함께 남긴다
M4="$T/migrate4"; mkdir -p "$M4/.agent-loop" "$M4/.orca-loop"; git -C "$M4" init -q -b main; git -C "$M4" commit -q --allow-empty -m init
echo new > "$M4/.agent-loop/loop.env"; echo older > "$M4/.orca-loop/loop.env"
out="$(cd "$M4" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "두 옛 경로 마이그레이션 설치 실패"
[[ "$(cat "$M4/.ticket-loop/loop.env")" == new && -d "$M4/.orca-loop" ]] || fail ".agent-loop 가 아니라 .orca-loop 를 옮겼거나 .orca-loop 를 지움"
grep -q 'Both .orca-loop/ and .ticket-loop/ exist' <<<"$out" || fail "남은 .orca-loop 에 경고가 없음"
echo "ok  0.3 → .ticket-loop 마이그레이션 · 두 옛 경로"

(cd "$T" && bash scripts/ticket-loop.sh --help >/dev/null) || fail "ticket-loop.sh --help"
echo "ok  ticket-loop.sh --help"

# 백엔드마다 같은 함수 집합을 구현해야 한다(공통부는 backend_* 만 부른다)
for b in orca cmux; do
  for f in check worktree_create worktree_remove send type interrupt wait_idle tail set_status; do
    grep -qE "^${b}_${f}\(\)" "$KIT/files/scripts/ticket-loop.sh" || fail "백엔드 ${b} 에 ${b}_${f} 함수가 없다"
  done
done
grep -qE '^backend_[a-z_]+\(\)' "$KIT/files/scripts/ticket-loop.sh" || fail "backend_* 디스패치 함수가 없다"
# 공통부에서 백엔드 CLI를 직접 부르면 안 된다(백엔드 절 밖의 orca_json / "$CMUX_CLI")
awk '/^# ---------- 백엔드 ----------/{on=1} /^# ----- 공통 -----/{on=0} !on && !/^\s*#/ && /orca_json|\$CMUX_CLI|\$ORCA_CLI/' \
  "$KIT/files/scripts/ticket-loop.sh" | grep -v '^ORCA_CLI=\|^elif\|^if \[\[ -n "\${ORCA_CLI\|CMUX_CLI="' | grep -q . \
  && fail "백엔드 절 밖에서 백엔드 CLI를 직접 부른다: $(awk '/^# ---------- 백엔드 ----------/{on=1} /^# ----- 공통 -----/{on=0} !on && !/^\s*#/ && /orca_json|\$CMUX_CLI/' "$KIT/files/scripts/ticket-loop.sh" | head -3)"
echo "ok  백엔드 함수 집합·분리"

# Orca 백엔드 함수를 가짜 orca 로 한 번씩 부른다 — set -u 아래에서 미정의 변수·인용 실수를 잡는다(실제 티켓에서만 도는 경로)
F="$T/fake"; mkdir -p "$F"
cat > "$F/orca" <<'SH'
#!/bin/bash
echo '{"ok":true,"result":{"send":{"accepted":true},"terminal":{"tail":["Claude Code","[Opus 5.5 | Max]"]},"wait":{"satisfied":true},"worktree":{"id":"wt1::/tmp/wt1"},"agentTerminalHandle":"t1","repos":[{"id":"r1","gitRemoteIdentity":{"canonicalKey":"github.com/o/r"}}]}}'
SH
chmod +x "$F/orca"
sed -n '/^# ---------- 백엔드 ----------/,/^# ----- 공통 -----/p' "$KIT/files/scripts/ticket-loop.sh" > "$F/backend.sh"
cat > "$F/run.sh" <<'SH'
set -euo pipefail
BACKEND=orca; ORCA_CLI=orca; CMUX_CLI=cmux; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude
AGENT_RESTART_CMD=claude; TERMINAL_RETRY=1; TERMINAL_RETRY_SEC=0; IDLE_POLL_SEC=0; WORKTREE_DIR=""; WORKTREE_SETUP_CMD=""
log() { :; }; die() { echo "die: $*" >&2; exit 1; }
source "$1"
orca_check; [[ "$REPO_ID" == r1 ]] || die "REPO_ID"
orca_set_status wt1 in-progress; orca_set_status wt1 todo "" "comment"; orca_set_status wt1 in-review 7 "PR #7"; orca_set_status wt1 completed 7 "done"
orca_send t1 "hello"; orca_type t1 "claude x"; orca_interrupt t1; orca_wait_idle t1 1000; [[ "$(orca_tail t1 | tail -n1)" == "[Opus 5.5 | Max]" ]] || die "tail"
orca_worktree_remove wt1 /tmp/wt1
cmux_set_status ws1 in-review 7 "x" || true   # cmux 는 소켓이 없어 실패해도 되지만 unbound 는 안 된다
echo ok
SH
(cd "$F" && PATH="$F:$PATH" bash run.sh "$F/backend.sh" >/dev/null) || fail "Orca 백엔드 함수 호출 실패(set -u)"
echo "ok  Orca 백엔드 함수 가짜 호출"

# 스펙 리포트 jq 프로그램을 고정 자료로 그려 본다(GitHub 없이). 병합·중단·기록 없음 세 경우가 표에 나와야 한다
REPORT_JQ="$(sed -n "/^read -r -d '' REPORT_JQ <<'JQ'/,/^JQ\$/p" "$KIT/files/scripts/ticket-loop.sh" | sed '1d;$d')"
[[ -n "$REPORT_JQ" ]] || fail "REPORT_JQ 블록을 찾지 못함"
jq -rn --arg prefix issue- --arg now "2026-10-12 09:00" \
  --argjson spec '{"number":40,"title":"스펙","state":"OPEN","url":"https://x/40"}' \
  --argjson issues '[{"number":41,"title":"T01: 하나","state":"closed","url":"https://x/41","assignees":0},
                     {"number":42,"title":"T02: 둘","state":"open","url":"https://x/42","assignees":1},
                     {"number":43,"title":"T03: 셋","state":"closed","url":"https://x/43","assignees":0}]' \
  --argjson prs '[{"number":50,"title":"T01 PR","body":"- [x] a\n- [ ] b","state":"MERGED","url":"https://x/p50","createdAt":"2026-10-12T00:00:00Z","mergedAt":"2026-10-12T00:30:00Z","headRefName":"issue-41-one"},
                  {"number":51,"title":"T03 PR","body":"","state":"MERGED","url":"https://x/p51","createdAt":"2026-10-11T00:00:00Z","mergedAt":"2026-10-11T01:00:00Z","headRefName":"issue-43-three"}]' \
  --argjson recs '[{"spec":40,"issue":41,"title":"T01: 하나","result":"merged","started":"2026-10-12T00:00:00Z","finished":"2026-10-12T00:31:00Z","wall_sec":1860,"repairs":1,"idle_false_positives":0,"agent":"claude","pr":50,"ci_sec":200,"post_merge":"통과 90초","model":"Opus 5.5"},
                   {"spec":40,"issue":42,"title":"T02: 둘","result":"stopped","reason":"워커가 PR 없이 멈췄습니다","started":"2026-10-12T01:00:00Z","finished":"2026-10-12T01:10:00Z","wall_sec":600,"repairs":0,"idle_false_positives":2,"agent":"claude"}]' \
  "$REPORT_JQ" > "$T/report.html" || fail "스펙 리포트 jq 실패"
for want in '<!doctype html>' 'PR #50' '인수 조건 1/2' '>병합<' '>중단<' '워커가 PR 없이 멈췄습니다' 'Opus 5.5' 'PR 생성→병합 기준' '미기록' '수리 1회'; do
  grep -qF "$want" "$T/report.html" || fail "스펙 리포트에 '$want' 없음"
done
echo "ok  스펙 리포트 렌더"

# npx 껍질: 새 저장소에 --yes 로 설치하면 install.sh 결과에 더해 loop.env(BACKEND 줄)와 kit.json(커밋·ref)이 생긴다.
# 두 번째 실행은 loop.env 를 건드리지 않고, cmux 는 아직 거절한다
N="$T/npx"; mkdir -p "$N"; git -C "$N" init -q -b main; git -C "$N" commit -q --allow-empty -m init
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 init 실패"
[[ -x "$N/scripts/ticket-loop.sh" && -f "$N/.claude/skills/setup-ticket-loop/SKILL.md" ]] || fail "npx 껍질이 install.sh 를 부르지 않음"
grep -qxF 'BACKEND="${BACKEND:-orca}"' "$N/.ticket-loop/loop.env" || fail "loop.env 에 BACKEND 줄 없음"
[[ "$(jq -r .commit "$N/.ticket-loop/kit.json")" == "$(git -C "$KIT" rev-parse HEAD)" ]] || fail "kit.json commit 이 키트 HEAD 와 다르다"
[[ "$(jq -r .ref "$N/.ticket-loop/kit.json")" == "local" ]] || fail "kit.json ref 가 local 이 아니다"
printf 'CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}"\n' >> "$N/.ticket-loop/loop.env"; cp "$N/.ticket-loop/loop.env" "$N/before.env"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 재실행 실패"
cmp -s "$N/before.env" "$N/.ticket-loop/loop.env" || fail "재실행이 loop.env 를 바꿈"
sed -i.bak '/^BACKEND=/d' "$N/.ticket-loop/loop.env"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 세 번째 실행 실패"
grep -qxF 'BACKEND="${BACKEND:-orca}"' "$N/.ticket-loop/loop.env" || fail "BACKEND 줄이 없는 loop.env 에 줄을 덧붙이지 않음"
grep -q 'CI_SKIP_REGEX' "$N/.ticket-loop/loop.env" || fail "BACKEND 줄을 덧붙이며 기존 줄을 잃음"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --backend bogus >/dev/null 2>&1) && fail "모르는 백엔드를 거절해야 한다"
C="$T/npx-cmux"; mkdir -p "$C"; git -C "$C" init -q -b main; git -C "$C" commit -q --allow-empty -m init
(cd "$C" && node "$KIT/bin/ticket-loop-kit.js" init --yes --backend cmux --no-skills --no-github --no-git-credential >/dev/null) || fail "cmux 백엔드 init 실패"
grep -qxF 'BACKEND="${BACKEND:-cmux}"' "$C/.ticket-loop/loop.env" || fail "cmux 선택이 loop.env 에 반영되지 않음"
grep -q 'WORKTREE_SETUP_CMD' "$C/.ticket-loop/loop.env" || fail "cmux loop.env 에 WORKTREE_SETUP_CMD 안내가 없음"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --bogus >/dev/null 2>&1) && fail "모르는 인자를 거절해야 한다"
echo "ok  npx 껍질 설치·재실행·백엔드 선택·거절"
echo "smoke 통과"
