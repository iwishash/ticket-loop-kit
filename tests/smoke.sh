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
         .ticket-loop/worker-rules.md .ticket-loop/kit.json docs/loop-reports/README.md docs/agents/issue-tracker.md; do
  [[ -f "$T/$f" ]] || fail "설치 뒤 $f 없음"
done
[[ -x "$T/scripts/ticket-loop.sh" ]] || fail "ticket-loop.sh 실행 권한 없음"
# 0.7 배치: 정본은 .agents/skills/<이름>(Codex), .claude/skills/<이름>은 그 링크(Claude Code). Codex 메타데이터와 명령 규칙도 놓인다
for sk in setup-ticket-loop implement pr; do
  [[ -d "$T/.agents/skills/$sk" && ! -L "$T/.agents/skills/$sk" ]] || fail ".agents/skills/$sk 가 실제 디렉터리가 아님"
  [[ -L "$T/.claude/skills/$sk" && "$(readlink "$T/.claude/skills/$sk")" == "../../.agents/skills/$sk" ]] || fail ".claude/skills/$sk 가 ../../.agents/skills/$sk 링크가 아님"
  [[ -f "$T/.agents/skills/$sk/agents/openai.yaml" ]] || fail ".agents/skills/$sk/agents/openai.yaml 없음"
done
grep -q 'allow_implicit_invocation: false' "$T/.agents/skills/implement/agents/openai.yaml" || fail "implement 의 openai.yaml 에 allow_implicit_invocation: false 없음"
[[ -f "$T/.codex/rules/ticket-loop.rules" ]] && grep -q '"git", "push", "origin", "main"' "$T/.codex/rules/ticket-loop.rules" && ! grep -q '__BASE__' "$T/.codex/rules/ticket-loop.rules" || fail ".codex/rules/ticket-loop.rules 가 없거나 __BASE__ 가 안 채워짐"
grep -q 'Call the Skill tool' "$KIT/templates/.agents/skills/implement/SKILL.md" && fail "implement 템플릿에 Claude 전용 문구(Call the Skill tool)가 남음"
jq -e '.permissions.deny | index("Bash(gh pr merge:*)")' "$T/.claude/settings.json" >/dev/null || fail "deny 병합 안 됨"
grep -qxF '/.ticket-loop/*.log' "$T/.gitignore" || fail ".gitignore 줄 없음"
grep -qxF '/.ticket-loop/*.jsonl' "$T/.gitignore" || fail ".gitignore jsonl 줄 없음"
echo "ok  첫 설치"

# 프로젝트 소유 파일은 두 번째 설치에서 유지돼야 한다
echo "project edit" >> "$T/.ticket-loop/worker-rules.md"
echo "tracker edit" >> "$T/docs/agents/issue-tracker.md"
echo "# rules edit" >> "$T/.codex/rules/ticket-loop.rules"
jq '.permissions.deny += ["Bash(rm -rf:*)"]' "$T/.claude/settings.json" > "$T/s.json" && mv "$T/s.json" "$T/.claude/settings.json"
cp "$T/.claude/settings.json" "$T/before.json"; cp "$T/.gitignore" "$T/before.gitignore"
run
grep -q "project edit" "$T/.ticket-loop/worker-rules.md" || fail "재설치가 프로젝트 소유 파일을 덮어씀"
grep -q "tracker edit" "$T/docs/agents/issue-tracker.md" || fail "재설치가 docs/agents/issue-tracker.md 를 덮어씀"
grep -q "rules edit" "$T/.codex/rules/ticket-loop.rules" || fail "재설치가 .codex/rules 를 덮어씀"
[[ -L "$T/.claude/skills/implement" ]] || fail "재설치 뒤 .claude/skills/implement 링크가 사라짐"
cmp -s "$T/before.json" "$T/.claude/settings.json" || fail "재설치가 settings.json을 바꿈"
cmp -s "$T/before.gitignore" "$T/.gitignore" || fail "재설치가 .gitignore에 줄을 또 넣음"
echo "ok  재설치 멱등"

# 0.6 이하가 설치한 저장소: .claude/skills/<이름> 실제 디렉터리(관리 setup-ticket-loop, 프로젝트 소유 implement·pr) → .agents/skills/ + 링크.
# 프로젝트 소유는 git mv 로 이력을 잇고 내용을 유지한다. 관리 스킬은 새 내용으로 덮인다
L6="$T/layout06"; mkdir -p "$L6/.claude/skills/setup-ticket-loop" "$L6/.claude/skills/implement"; git -C "$L6" init -q -b main
echo old-managed > "$L6/.claude/skills/setup-ticket-loop/SKILL.md"; echo my-implement > "$L6/.claude/skills/implement/SKILL.md"
git -C "$L6" add -A >/dev/null; git -C "$L6" -c user.name=t -c user.email=t@t commit -q -m "0.6 layout"
out="$(cd "$L6" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "0.6 배치 설치 실패: $out"
grep -q 'Moved setup-ticket-loop implement from .claude/skills/' <<<"$out" || fail "배치 이동 안내가 없음: $out"
[[ "$(cat "$L6/.agents/skills/implement/SKILL.md")" == my-implement && -L "$L6/.claude/skills/implement" ]] || fail "프로젝트 소유 implement 가 .agents/skills 로 옮겨지지 않았거나 내용이 바뀜"
grep -q 'ticket-loop-kit 관리 파일' "$L6/.agents/skills/setup-ticket-loop/SKILL.md" && [[ -L "$L6/.claude/skills/setup-ticket-loop" ]] || fail "관리 스킬이 옮겨진 뒤 새 내용으로 덮이지 않음"
[[ -L "$L6/.claude/skills/pr" && -f "$L6/.agents/skills/pr/SKILL.md" ]] || fail "새 템플릿 pr 이 .agents/skills 에 놓이고 링크되지 않음"
git -C "$L6" status --porcelain | grep -q '^R  .claude/skills/implement/SKILL.md -> .agents/skills/implement/SKILL.md' || fail "0.6 배치: implement 를 git mv 로 옮기지 않음(이력 끊김)"
echo "ok  0.6 → .agents/skills 배치 마이그레이션(설치기)"

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
printf '# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다\n/.agent-loop/*.log\n# 티켓 루프의 티켓별 기록(RECORDS_FILE) — 기계별 원자료. 스펙 리포트(docs/loop-reports/)만 커밋한다\n/.agent-loop/*.jsonl\nkeep-me\n' > "$M3/.gitignore"   # 0.3 설치기가 쓴 주석 + 사용자 줄
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
[[ "$(grep -cxF '# 티켓 루프 로그 — 규칙·설정 파일만 커밋한다' "$M3/.gitignore")" == 1 ]] || fail ".gitignore 에 키트 주석이 고아로 남았거나 없음(0.7.0 회귀)"
grep -qxF 'keep-me' "$M3/.gitignore" || fail ".gitignore 의 사용자 줄을 지움"
awk 'prev == "" && $0 == "" { bad = 1 } { prev = $0 } END { exit bad }' "$M3/.gitignore" || fail ".gitignore 에 빈 줄이 연달아 남음"
git -C "$M3" status --porcelain | grep -q '^D  .claude/skills/setup-agent-loop/SKILL.md' || fail "옛 setup-agent-loop 삭제가 git rm 으로 스테이징되지 않음"
git -C "$M3" status --porcelain | grep -q '^R  .agent-loop/worker-rules.md -> .ticket-loop/worker-rules.md' || fail "0.3: git mv 로 옮기지 않음(이력 끊김)"
# 둘 다 있고 새 경로는 없으면 첫 번째(.agent-loop)만 옮기고 .orca-loop 는 경고와 함께 남긴다
M4="$T/migrate4"; mkdir -p "$M4/.agent-loop" "$M4/.orca-loop"; git -C "$M4" init -q -b main; git -C "$M4" commit -q --allow-empty -m init
echo new > "$M4/.agent-loop/loop.env"; echo older > "$M4/.orca-loop/loop.env"
out="$(cd "$M4" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "두 옛 경로 마이그레이션 설치 실패"
[[ "$(cat "$M4/.ticket-loop/loop.env")" == new && -d "$M4/.orca-loop" ]] || fail ".agent-loop 가 아니라 .orca-loop 를 옮겼거나 .orca-loop 를 지움"
grep -q 'Both .orca-loop/ and .ticket-loop/ exist' <<<"$out" || fail "남은 .orca-loop 에 경고가 없음"
echo "ok  0.3 → .ticket-loop 마이그레이션 · 두 옛 경로"

# 스킬 동기화: 가짜 upstream(plugin.json + 스킬 디렉터리)으로 네트워크 없이 — 묶음 선택, 이름 바꾸기, 본문 치환, 지난 설치 스킬 유지(kept)·--prune
U="$T/upstream"; mkdir -p "$U/.claude-plugin" "$U/.changeset"; git -C "$U" init -q -b main
ALL=(tdd code-review grill-with-docs to-spec to-tickets retro grilling domain-modeling writing-for-agents implement pr ask-matt wizard)
for sk in "${ALL[@]}"; do
  mkdir -p "$U/skills/engineering/$sk/agents"
  printf -- '---\nname: %s\ndescription: x\n---\nUses the `code-review` skill. If missing, run `/setup-matt-pocock-skills`. See /code-review and "code-review".\n' "$sk" > "$U/skills/engineering/$sk/SKILL.md"
  echo ref > "$U/skills/engineering/$sk/agents/openai.yaml"
done
printf '{"name":"mattpocock-skills","version":"9.9.9","skills":[%s]}\n' "$(printf '"./skills/engineering/%s",' "${ALL[@]}" | sed 's/,$//')" > "$U/.claude-plugin/plugin.json"
echo readme > "$U/.changeset/README.md"; echo cs > "$U/.changeset/one.md"
git -C "$U" add -A >/dev/null; git -C "$U" -c user.name=t -c user.email=t@t commit -q -m up
W="$T/sync"; mkdir -p "$W/.claude/skills/implement"; git -C "$W" init -q -b main; echo mine > "$W/.claude/skills/implement/SKILL.md"
SYNC="$KIT/files/scripts/sync-mattpocock-skills.sh"
sync_run() { (cd "$W" && HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$T/emptyhome/.claude" MATTPOCOCK_UPSTREAM="$U" bash "$SYNC" "$@" 2>&1); }
mkdir -p "$T/emptyhome/.claude"
out="$(sync_run)" || fail "동기화(core) 실패: $out"
[[ -f "$W/.claude/skills/tdd/SKILL.md" && -f "$W/.claude/skills/ticket-review/SKILL.md" && -f "$W/.claude/skills/ticket-review/agents/openai.yaml" ]] || fail "core 스킬이 없음"
[[ -d "$W/.agents/skills/tdd" && ! -L "$W/.agents/skills/tdd" && -L "$W/.claude/skills/tdd" && "$(readlink "$W/.claude/skills/tdd")" == "../../.agents/skills/tdd" ]] || fail "정본이 .agents/skills 가 아니거나 .claude/skills/tdd 가 링크가 아님"
[[ ! -e "$W/.claude/skills/.mattpocock.json" ]] || fail "매니페스트가 옛 자리(.claude/skills)에 생김"
for sk in code-review grill-with-docs to-tickets ask-matt wizard pr; do [[ ! -e "$W/.claude/skills/$sk" ]] || fail "들이지 않을 스킬 $sk 가 놓임"; done
[[ "$(cat "$W/.claude/skills/implement/SKILL.md")" == mine ]] || fail "프로젝트 소유 implement 가 바뀜"
grep -q '^name: ticket-review$' "$W/.claude/skills/ticket-review/SKILL.md" || fail "code-review → ticket-review 이름 변경 안 됨"
grep -q '`ticket-review` skill' "$W/.claude/skills/tdd/SKILL.md" && grep -q '/ticket-review and "ticket-review"' "$W/.claude/skills/tdd/SKILL.md" || fail "본문의 code-review 참조가 안 바뀜"
grep -q '/setup-ticket-loop' "$W/.claude/skills/tdd/SKILL.md" && ! grep -q 'setup-matt-pocock' "$W/.claude/skills/tdd/SKILL.md" || fail "/setup-matt-pocock-skills 안내가 안 바뀜"
M="$W/.agents/skills/.mattpocock.json"
[[ "$(jq -c '.skills' "$M")" == '["tdd","ticket-review"]' && "$(jq -r .workflow "$M")" == false && "$(jq -r .pending_changesets "$M")" == 1 && "$(jq -r .version "$M")" == 9.9.9 ]] || fail "매니페스트(core) 내용이 다름: $(cat "$M")"
grep -q '2 skills synced (core)' <<<"$out" || fail "요약 줄 없음: $out"
out="$(sync_run --workflow)" || fail "동기화(--workflow) 실패: $out"
[[ "$(jq -r '.skills | length' "$M")" == 9 && "$(jq -r .workflow "$M")" == true ]] || fail "workflow 묶음이 9개가 아님"
[[ -f "$W/.claude/skills/grilling/SKILL.md" && -f "$W/.claude/skills/writing-for-agents/SKILL.md" ]] || fail "workflow 의존 스킬이 없음"
sync_run >/dev/null || fail "동기화(auto) 실패"
[[ "$(jq -r '.skills | length' "$M")" == 9 ]] || fail "플래그 없이 다시 돌리면 지난 선택(workflow)을 유지해야 한다"
out="$(sync_run --no-workflow)" || fail "동기화(--no-workflow) 실패: $out"
[[ "$(jq -c '.skills' "$M")" == '["tdd","ticket-review"]' && ! -e "$W/.claude/skills/to-tickets" && ! -e "$W/.agents/skills/to-tickets" ]] || fail "--no-workflow 가 workflow 묶음(정본·링크)을 지우지 않음"
grep -q 'removed to-tickets' <<<"$out" || fail "제거 로그 없음"
# 0.5 이하가 들인 매니페스트(workflow 키 없음; 두 묶음 밖의 wizard·ask-matt, upstream 에서 사라진 gone, setup-matt-pocock-skills, 손으로 지운 handoff)
# → to-tickets 가 있었으니 workflow 켜짐. wizard·ask-matt 는 kept 로 유지·동기화, gone 은 그대로, setup-matt-pocock-skills 는 지움, handoff 는 다시 들이지 않음
for sk in wizard ask-matt gone setup-matt-pocock-skills; do mkdir -p "$W/.claude/skills/$sk"; echo old > "$W/.claude/skills/$sk/SKILL.md"; done
jq '.skills = ["tdd","ticket-review","wizard","ask-matt","gone","handoff","setup-matt-pocock-skills","to-tickets","grilling"] | del(.workflow)' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
rc=0; out="$(sync_run --check)" || rc=$?
[[ $rc -eq 0 ]] && grep -q '3 skills from an earlier install are outside the selected sets (ask-matt gone wizard)' <<<"$out" && grep -q 'setup-matt-pocock-skills will be removed' <<<"$out" \
  || fail "--check 가 kept 를 알리지 않음(rc=$rc): $out"
out="$(sync_run)" || fail "0.5 매니페스트에서 동기화 실패: $out"
[[ -f "$W/.claude/skills/to-tickets/SKILL.md" && "$(jq -r .workflow "$M")" == true ]] || fail "0.5 매니페스트에서 workflow 가 유지되지 않음"
[[ -f "$W/.claude/skills/wizard/SKILL.md" && "$(cat "$W/.claude/skills/wizard/SKILL.md")" != old && -L "$W/.claude/skills/wizard" ]] || fail "kept 스킬 wizard 가 유지·동기화·링크되지 않음"
grep -q 'moved   3 skills from .claude/skills/ to .agents/skills/ (ask-matt gone wizard' <<<"$out" || fail "옛 자리의 kept 스킬을 옮긴 안내가 없음: $out"
[[ -d "$W/.agents/skills/gone" && -L "$W/.claude/skills/gone" ]] || fail "upstream 에 없는 kept 스킬 gone 이 .agents/skills 로 옮겨지지 않음"
grep -q '`ticket-review` skill' "$W/.claude/skills/ask-matt/SKILL.md" || fail "kept 스킬 본문 치환 안 됨"
[[ "$(cat "$W/.claude/skills/gone/SKILL.md")" == old ]] || fail "upstream 에 없는 kept 스킬 gone 이 바뀌었거나 지워짐"
[[ ! -e "$W/.claude/skills/setup-matt-pocock-skills" && ! -e "$W/.claude/skills/handoff" ]] || fail "setup-matt-pocock-skills 가 남았거나 handoff 가 다시 들어옴"
[[ "$(jq -c '.kept' "$M")" == '["ask-matt","gone","wizard"]' && "$(jq -r '.skills | length' "$M")" == 12 ]] || fail "매니페스트 kept 가 다름: $(jq -c '{kept, skills}' "$M")"
grep -q 'kept 3 from an earlier install' <<<"$out" && grep -q 'kept    gone (no longer in upstream' <<<"$out" && grep -q 'removed setup-matt-pocock-skills (superseded' <<<"$out" || fail "kept 로그 없음: $out"
sync_run >/dev/null || fail "kept 상태에서 재동기화 실패"
[[ "$(jq -c '.kept' "$M")" == '["ask-matt","gone","wizard"]' ]] || fail "재동기화가 kept 를 잃음"
out="$(sync_run --prune)" || fail "--prune 실패: $out"
for sk in wizard ask-matt gone; do [[ ! -e "$W/.claude/skills/$sk" && ! -e "$W/.agents/skills/$sk" && ! -L "$W/.claude/skills/$sk" ]] || fail "--prune 뒤에도 $sk 가 남음"; done
[[ "$(jq -c '.kept' "$M")" == '[]' && "$(jq -r '.skills | length' "$M")" == 9 ]] || fail "--prune 뒤 매니페스트가 다름: $(jq -c '{kept, skills}' "$M")"
grep -q 'removed wizard (--prune)' <<<"$out" || fail "--prune 제거 로그 없음"
echo "ok  스킬 동기화(가짜 upstream)"

# 0.6 이하 설치본의 동기화: 매니페스트가 .claude/skills/.mattpocock.json 에 있고 스킬이 실제 디렉터리로 커밋돼 있다
# → --check 는 옛 매니페스트를 읽어 kept 를 알리고(바꾸지 않음), 동기화는 git mv 로 옮기고 링크·새 매니페스트를 둔다
W6="$T/sync06"; mkdir -p "$W6/.claude/skills"; git -C "$W6" init -q -b main
for sk in tdd ticket-review wizard; do mkdir -p "$W6/.claude/skills/$sk"; echo old > "$W6/.claude/skills/$sk/SKILL.md"; done
printf '{"skills":["tdd","ticket-review","wizard"],"workflow":false}\n' > "$W6/.claude/skills/.mattpocock.json"
git -C "$W6" add -A >/dev/null; git -C "$W6" -c user.name=t -c user.email=t@t commit -q -m "0.6"
sync6() { (cd "$W6" && HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$T/emptyhome/.claude" MATTPOCOCK_UPSTREAM="$U" bash "$SYNC" "$@" 2>&1); }
rc=0; out="$(sync6 --check)" || rc=$?
[[ $rc -eq 0 ]] && grep -q '1 skills from an earlier install are outside the selected sets (wizard)' <<<"$out" || fail "옛 매니페스트로 --check 가 kept 를 못 읽음(rc=$rc): $out"
[[ -f "$W6/.claude/skills/.mattpocock.json" && -z "$(git -C "$W6" status --porcelain)" ]] || fail "--check 가 저장소를 바꿈"
out="$(sync6)" || fail "0.6 배치에서 동기화 실패: $out"
grep -q 'moved   3 skills from .claude/skills/ to .agents/skills/' <<<"$out" || fail "배치 이동 안내가 없음: $out"
[[ -f "$W6/.agents/skills/.mattpocock.json" && ! -e "$W6/.claude/skills/.mattpocock.json" ]] || fail "매니페스트가 .agents/skills 로 옮겨지지 않음"
for sk in tdd ticket-review wizard; do
  [[ -d "$W6/.agents/skills/$sk" && ! -L "$W6/.agents/skills/$sk" && -L "$W6/.claude/skills/$sk" && "$(cat "$W6/.claude/skills/$sk/SKILL.md")" != old ]] || fail "0.6 배치: $sk 가 옮겨지고 동기화되고 링크되지 않음"
done
git -C "$W6" status --porcelain | grep -q '^RM .claude/skills/wizard/SKILL.md -> .agents/skills/wizard/SKILL.md' || fail "0.6 배치: git mv 로 옮기지 않음(이력 끊김): $(git -C "$W6" status --porcelain)"
[[ "$(jq -c '.kept' "$W6/.agents/skills/.mattpocock.json")" == '["wizard"]' ]] || fail "0.6 배치: kept 가 이어지지 않음"
sync6 >/dev/null || fail "옮긴 뒤 재동기화 실패"
echo "ok  0.6 → .agents/skills 배치 마이그레이션(동기화)"

# 충돌 검사(--check): 가짜 HOME 으로 다섯 경우. 종료 0 없음 · 1 경고 · 3 차단
K="$T/check"; mkdir -p "$K/.claude"; git -C "$K" init -q -b main; H="$T/home"; mkdir -p "$H/.claude"
chk() { (cd "$K" && HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" bash "$SYNC" --check "$@" 2>&1); }
chk >/dev/null && echo "ok  --check 깨끗" || fail "깨끗한 저장소에서 --check 가 0 이 아님"
mkdir -p "$H/.claude/skills/tdd"; echo x > "$H/.claude/skills/tdd/SKILL.md"
rc=0; out="$(chk)" || rc=$?; [[ $rc -eq 1 ]] && grep -q 'global' <<<"$out" && grep -q '~/.claude/skills/tdd' <<<"$out" || fail "글로벌 스킬 경고(1) 아님: rc=$rc $out"
mkdir -p "$K/.claude/skills/code-review"; echo x > "$K/.claude/skills/code-review/SKILL.md"
rc=0; out="$(chk)" || rc=$?; [[ $rc -eq 1 ]] && grep -q 'builtin-shadow' <<<"$out" || fail "code-review 디렉터리 경고 아님: $out"
printf '{"enabledPlugins":{"mattpocock-skills@mattpocock":true}}\n' > "$K/.claude/settings.json"
rc=0; out="$(chk)" || rc=$?; grep -q 'plugin mattpocock-skills@mattpocock is enabled' <<<"$out" || fail "플러그인 경고 없음: $out"
printf '{"enabledPlugins":{"mattpocock-skills@mattpocock":false}}\n' > "$K/.claude/settings.local.json"
rc=0; out="$(chk)" || rc=$?; grep -q 'plugin mattpocock' <<<"$out" && fail "local 의 false 가 project 의 true 를 덮어야 한다"
rm "$K/.claude/settings.local.json"
printf '{"version":1,"skills":{"tdd":{"source":"mattpocock/skills","sourceType":"github"}}}\n' > "$K/skills-lock.json"
rc=0; out="$(chk --json)" || rc=$?; [[ $rc -eq 3 ]] || fail "skills-lock.json 이 차단(3)이 아님: rc=$rc"
jq -e 'type == "array" and (map(.kind) | index("skills-cli") != null) and (map(.kind) | index("plugin") != null) and (map(.kind) | index("global") != null) and (map(.kind) | index("builtin-shadow") != null)' <<<"$out" >/dev/null || fail "--json 결과가 네 종류를 담지 않음: $out"
jq -e '.[] | select(.kind == "plugin") | .fix | test("claude plugin disable mattpocock-skills@mattpocock --scope project")' <<<"$out" >/dev/null || fail "플러그인 해결 명령 없음"
rm "$K/skills-lock.json"; mkdir -p "$K/.agents/skills/tdd"; ln -s ../../.agents/skills/tdd "$K/.claude/skills/tdd"
rc=0; out="$(chk)" || rc=$?; [[ $rc -eq 1 ]] && ! grep -q 'symbolic link' <<<"$out" || fail "이 키트 배치의 링크(.claude/skills/tdd → ../../.agents/skills/tdd)를 차단함: rc=$rc $out"
mkdir -p "$T/elsewhere/ticket-review"; ln -s "$T/elsewhere/ticket-review" "$K/.claude/skills/ticket-review"
rc=0; out="$(chk)" || rc=$?; [[ $rc -eq 3 ]] && grep -q 'symbolic link to' <<<"$out" || fail "다른 곳을 가리키는 링크가 차단(3)이 아님: rc=$rc $out"
rm "$K/.claude/skills/ticket-review"
# --agent codex: 플러그인·~/.claude/skills 검사는 Claude Code 의 일이라 하지 않고, ~/.agents/skills 의 같은 이름은 알림(둘 다 선택기에 보임)
rc=0; out="$(chk --agent codex)" || rc=$?
grep -q 'plugin mattpocock' <<<"$out" && fail "--agent codex 인데 플러그인 경고가 나옴: $out"
grep -q '~/.claude/skills/tdd' <<<"$out" && fail "--agent codex 인데 ~/.claude/skills 경고가 나옴: $out"
mkdir -p "$T/agentshome/skills/tdd"; echo x > "$T/agentshome/skills/tdd/SKILL.md"
rc=0; out="$(cd "$K" && HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" CODEX_AGENTS_HOME="$T/agentshome" bash "$SYNC" --check --agent codex 2>&1)" || rc=$?
grep -q '~/.agents/skills/tdd exists' <<<"$out" || fail "--agent codex 가 ~/.agents/skills 의 같은 이름을 알리지 않음: $out"
(cd "$K" && bash "$SYNC" --check --agent bogus >/dev/null 2>&1) && fail "모르는 --agent 를 거절해야 한다"
echo "ok  --check 다섯 경우·종료 코드·--json·배치 링크·--agent codex"

# 차단 충돌이면 install.sh 와 npx 껍질은 파일을 놓기 전에 멈춘다. --no-skills 면 진행한다
B="$T/blocked"; mkdir -p "$B"; git -C "$B" init -q -b main; git -C "$B" commit -q --allow-empty -m init
printf '{"version":1,"skills":{"tdd":{"source":"mattpocock/skills"}}}\n' > "$B/skills-lock.json"
(cd "$B" && HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$T/emptyhome/.claude" KIT_DIR="$KIT" bash "$KIT/install.sh" --no-github --no-git-credential --no-orca >/dev/null 2>&1) && fail "차단 충돌에서 install.sh 가 멈추지 않음"
[[ ! -e "$B/scripts/ticket-loop.sh" ]] || fail "차단 충돌인데 파일을 놓음"
(cd "$B" && HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$T/emptyhome/.claude" node "$KIT/bin/ticket-loop-kit.js" init --yes --no-github --no-git-credential --no-orca >/dev/null 2>&1) && fail "차단 충돌에서 npx 껍질이 멈추지 않음"
[[ ! -e "$B/scripts/ticket-loop.sh" ]] || fail "npx 껍질이 차단 충돌인데 파일을 놓음"
(cd "$B" && HOME="$T/emptyhome" CLAUDE_CONFIG_DIR="$T/emptyhome/.claude" node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null 2>&1) || fail "--no-skills 로는 진행해야 한다"
[[ -x "$B/scripts/ticket-loop.sh" ]] || fail "--no-skills 설치가 파일을 놓지 않음"
echo "ok  차단 충돌에서 설치 중단"

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
BACKEND=orca; ORCA_CLI=orca; CMUX_CLI=cmux; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude; SKILL_PREFIX=/
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

# 에이전트 프리셋: AGENT 가 기동 명령·배너·모델 정규식·스킬 접두사의 기본값을 정하고, 준 값이 이긴다. 프롬프트에는 특정 에이전트의 이름·도구가 없다
A="$T/agent"; mkdir -p "$A"
sed -n '/^# ----- 에이전트 프리셋 -----/,/^# ----- 에이전트 프리셋 끝 -----/p' "$KIT/files/scripts/ticket-loop.sh" > "$A/preset.sh"
grep -q 'case "\$AGENT" in' "$A/preset.sh" || fail "에이전트 프리셋 블록을 찾지 못함"
preset() { AGENT="$1" bash -c 'set -euo pipefail; source "$0"; printf "%s\n%s\n%s\n%s\n" "$AGENT_RESTART_CMD" "$AGENT_BANNER_REGEX" "$MODEL_REGEX" "$SKILL_PREFIX"' "$A/preset.sh"; }
out="$(preset claude)"; [[ "$(sed -n 1p <<<"$out")" == "claude --dangerously-skip-permissions" && "$(sed -n 4p <<<"$out")" == "/" ]] || fail "claude 프리셋이 다름: $out"
printf '[Opus 5.5 | Max]\n' | grep -oE "$(sed -n 3p <<<"$out")" | grep -qx 'Opus 5.5' || fail "claude MODEL_REGEX 가 Opus 5.5 를 못 뽑음"
out="$(preset codex)"; [[ "$(sed -n 1p <<<"$out")" == "codex --dangerously-bypass-approvals-and-sandbox" && "$(sed -n 4p <<<"$out")" == '$' ]] || fail "codex 프리셋이 다름: $out"
printf '>_ OpenAI Codex (v0.58.0)\nmodel: gpt-5.1-codex-max   /model to change\n' | grep -Eq "$(sed -n 2p <<<"$out")" || fail "codex 배너 정규식이 기동 화면에 안 맞음"
printf 'codex --dangerously-bypass-approvals-and-sandbox "$(cat /tmp/p)"\n' | grep -Eq "$(sed -n 2p <<<"$out")" && fail "codex 배너 정규식이 셸에 찍힌 기동 명령에도 맞음(배너 오판)"
printf 'model: gpt-5.1-codex-max.\n' | grep -oE "$(sed -n 3p <<<"$out")" | grep -qx 'gpt-5.1-codex-max' || fail "codex MODEL_REGEX 가 모델명을 못 뽑음"
out="$(AGENT_RESTART_CMD='codex --yolo' SKILL_PREFIX=/ preset codex)"; [[ "$(sed -n 1p <<<"$out")" == "codex --yolo" && "$(sed -n 4p <<<"$out")" == "/" ]] || fail "loop.env 값이 프리셋을 이기지 않음: $out"
out="$(preset bogus)"; [[ -z "$(sed -n 1p <<<"$out")" && -z "$(sed -n 2p <<<"$out")" && "$(sed -n 4p <<<"$out")" == "/" ]] || fail "모르는 AGENT 에 프리셋이 생김: $out"
grep -q 'AGENT=\${AGENT} 에는 프리셋이 없습니다' "$KIT/files/scripts/ticket-loop.sh" || fail "모르는 AGENT 를 시작 때 멈추는 검사가 없음"
sed -n '/^worker_prompt() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$A/prompt.sh"
wp() { ROOT="$A" WORKER_RULES_FILE="rules.md" SKILL_PREFIX="$1" bash -c 'set -euo pipefail; source "$0"; worker_prompt 12' "$A/prompt.sh"; }
out="$(wp '$')"; [[ "$out" == '$implement 12 — '* ]] || fail "codex 워커 프롬프트가 \$implement 로 시작하지 않음: $out"
out="$(wp /)"; [[ "$out" == '/implement 12 — '* ]] || fail "claude 워커 프롬프트가 /implement 로 시작하지 않음: $out"
grep -q 'rules.md 규칙도 따라라' <<<"$out" && fail "규칙 파일이 없는데 프롬프트에 규칙 문장이 있음"
: > "$A/rules.md"; out="$(wp /)"; grep -q 'rules.md 규칙도 따라라' <<<"$out" || fail "규칙 파일이 있는데 프롬프트에 규칙 문장이 없음"
grep -qiE 'claude|codex|AskUserQuestion' "$A/prompt.sh" && fail "워커 프롬프트에 특정 에이전트의 이름·도구가 있음"
grep -E 'repair "\$\{handle\}"' "$KIT/files/scripts/ticket-loop.sh" | grep -qiE 'claude|codex|AskUserQuestion' && fail "수리 프롬프트에 특정 에이전트의 이름·도구가 있음"
echo "ok  에이전트 프리셋(claude·codex)·중립 프롬프트"

# 스펙 이슈 자동 닫기: 가짜 gh 로 세 경우 — 하위 이슈가 모두 닫힘(닫는다), 하나 열림(안 닫는다), 하위 이슈 없음(안 닫는다)
S="$T/spec"; mkdir -p "$S"
cat > "$S/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "issue view "*"--json state"*) echo OPEN ;;
  "api "*"/sub_issues"*) cat "$SUBS" ;;
  "issue close "*) exit "${CLOSE_RC:-0}" ;;
esac
SH
chmod +x "$S/gh"
sed -n '/^close_spec_if_done() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$S/fn.sh"
sed -n '/^suggest_retro() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$S/fn.sh"
grep -q 'gh issue close' "$S/fn.sh" && grep -q '/retro' "$S/fn.sh" || fail "close_spec_if_done·suggest_retro 를 찾지 못함"
spec_case() {  # $1 하위 이슈 JSON, $2 기대(closed|kept)
  local out
  printf '%s' "$1" > "$S/subs.json"; : > "$S/gh.log"
  out="$(cd "$S" && PATH="$S:$PATH" GH_LOG="$S/gh.log" SUBS="$S/subs.json" OWNER_REPO=o/r bash -c 'set -euo pipefail; log() { echo "$*"; }; source fn.sh; close_spec_if_done 40; echo "CLOSED=${CLOSED_SPECS:-}"')" || fail "close_spec_if_done 실패($2)"
  if [[ "$2" == closed ]]; then grep -q '^issue close 40 ' "$S/gh.log" && grep -q '스펙 #40: 하위 이슈 2건 모두 닫힘' <<<"$out" && grep -q '^CLOSED= 40$' <<<"$out" || fail "모두 닫힌 스펙을 닫지 않았거나 CLOSED_SPECS 에 적지 않음: $out"
  else ! grep -q '^issue close' "$S/gh.log" || fail "닫으면 안 되는 스펙($2)을 닫음"; fi
}
spec_case '[{"number":41,"state":"closed"},{"number":42,"state":"closed"}]' closed
spec_case '[{"number":41,"state":"closed"},{"number":42,"state":"open"}]' kept
spec_case '[]' kept
(cd "$S" && PATH="$S:$PATH" GH_LOG="$S/gh.log" SUBS="$S/subs.json" bash -c 'set -euo pipefail; source fn.sh; log() { :; }; close_spec_if_done ""; close_spec_if_done 0') || fail "빈 스펙 번호에서 실패"
grep -c 'close_spec_if_done "' "$KIT/files/scripts/ticket-loop.sh" | grep -qx 3 || fail "close_spec_if_done 호출이 세 곳(티켓 뒤·티켓 없음·정상 종료)이 아니다"
echo "ok  스펙 이슈 자동 닫기"

# 회고 안내: 끝난 스펙이 있을 때만, 권고 문구로, 리포트가 있으면 경로·없으면 뽑는 방법, retro 스킬이 없으면 그 사실 — 아무것도 실행하지 않는다
mkdir -p "$S/reports" "$S/.claude/skills/retro"; : > "$S/reports/spec-40.html"
retro_case() {  # $1 CLOSED_SPECS, $2 REPORT_DIR, $3 ROOT → 출력
  (cd "$S" && CLOSED_SPECS="$1" REPORT_DIR="$2" ROOT="$3" LOG_FILE=".ticket-loop/loop-0101.log" bash -c 'set -euo pipefail; log() { echo "$*"; }; source fn.sh; suggest_retro')
}
out="$(retro_case " 40" "reports" "$S")" || fail "suggest_retro 실패"
grep -q '^스펙 #40 완료. 원하면 /retro로' <<<"$out" && grep -q '리포트 reports/spec-40.html' <<<"$out" && grep -q 'loop-0101.log' <<<"$out" || fail "회고 안내 문구가 다름: $out"
! grep -q -E '해야|반드시|필수' <<<"$out" || fail "회고 안내가 강제 어조: $out"
out="$(retro_case " 40 41" "reports" "$S")" || fail "suggest_retro(둘) 실패"
[[ "$(grep -c '^스펙 #' <<<"$out")" == 2 ]] && grep -q 'ticket-loop.sh --parent 41 로 뽑을 수 있다' <<<"$out" || fail "리포트 없는 스펙 안내가 다름: $out"
out="$(retro_case " 40" "reports" "$T/nowhere")" || fail "suggest_retro(스킬 없음) 실패"
grep -q '/retro(이 저장소에는 아직 없다' <<<"$out" || fail "retro 스킬이 없을 때 안내가 다름: $out"
out="$(retro_case "" "reports" "$S")" || fail "suggest_retro(빈) 실패"
[[ -z "$out" ]] || fail "끝난 스펙이 없는데 회고 안내가 나옴: $out"
grep -c -E '^suggest_retro$|; suggest_retro; ' "$KIT/files/scripts/ticket-loop.sh" | grep -qx 2 || fail "suggest_retro 호출이 두 곳(티켓 없음·정상 종료)이 아니다"
echo "ok  회고 안내"

# 템플릿 자리표: 무거운 테스트는 스위트와 파일 하나 실행 명령 두 자리표로, 설정 스킬의 결정 표가 둘 다 묻는다
for f in .ticket-loop/worker-rules.md .agents/skills/implement/SKILL.md .agents/skills/pr/SKILL.md; do
  grep -q '__HEAVY_TEST_FILE__' "$KIT/templates/$f" || fail "templates/$f 에 __HEAVY_TEST_FILE__ 없음"
done
[[ ! -e "$KIT/templates/.claude" && ! -e "$KIT/files/.claude" ]] || fail "키트에 옛 배치(templates/.claude, files/.claude)가 남음"
grep -rq '__HEAVY_TESTS_RULE__' "$KIT/templates" "$KIT/files" && fail "옛 자리표 __HEAVY_TESTS_RULE__ 가 남음"
grep -q '`__HEAVY_TESTS__`' "$KIT/files/.agents/skills/setup-ticket-loop/SKILL.md" && grep -q '`__HEAVY_TEST_FILE__`' "$KIT/files/.agents/skills/setup-ticket-loop/SKILL.md" || fail "setup-ticket-loop 결정 표에 무거운 테스트 자리표가 없음"
echo "ok  무거운 테스트 자리표"

# 스펙 리포트 jq 프로그램을 고정 자료로 그려 본다(GitHub 없이). 병합·중단·기록 없음 세 경우가 표에 나와야 한다.
# 고정 문구는 영어, GitHub에서 온 제목과 기록의 중단 사유는 원문(한국어) 그대로여야 한다
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
for want in '<!doctype html>' '<html lang="en">' 'PR #50' 'Acceptance criteria 1/2' '>Merged<' '>Stopped<' 'Stop reason: 워커가 PR 없이 멈췄습니다' 'Opus 5.5' 'PR created→merged' 'not recorded' '1 repair ·' 'post-merge check passed in 90s' 'T01: 하나'; do
  grep -qF "$want" "$T/report.html" || fail "스펙 리포트에 '$want' 없음"
done
echo "ok  스펙 리포트 렌더"

# npx 껍질: 새 저장소에 --yes 로 설치하면 install.sh 결과에 더해 loop.env(BACKEND 줄)와 kit.json(커밋·ref)이 생긴다.
# 두 번째 실행은 loop.env 를 건드리지 않고, cmux 는 아직 거절한다
N="$T/npx"; mkdir -p "$N"; git -C "$N" init -q -b main; git -C "$N" commit -q --allow-empty -m init
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 init 실패"
[[ -x "$N/scripts/ticket-loop.sh" && -f "$N/.claude/skills/setup-ticket-loop/SKILL.md" ]] || fail "npx 껍질이 install.sh 를 부르지 않음"
grep -qxF 'BACKEND="${BACKEND:-orca}"' "$N/.ticket-loop/loop.env" || fail "loop.env 에 BACKEND 줄 없음"
grep -qxF 'AGENT="${AGENT:-claude}"' "$N/.ticket-loop/loop.env" || fail "loop.env 에 AGENT 줄 없음"
[[ "$(jq -r .commit "$N/.ticket-loop/kit.json")" == "$(git -C "$KIT" rev-parse HEAD)" ]] || fail "kit.json commit 이 키트 HEAD 와 다르다"
[[ "$(jq -r .ref "$N/.ticket-loop/kit.json")" == "local" ]] || fail "kit.json ref 가 local 이 아니다"
printf 'CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}"\n' >> "$N/.ticket-loop/loop.env"; cp "$N/.ticket-loop/loop.env" "$N/before.env"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 재실행 실패"
cmp -s "$N/before.env" "$N/.ticket-loop/loop.env" || fail "재실행이 loop.env 를 바꿈"
sed -i.bak '/^BACKEND=/d' "$N/.ticket-loop/loop.env"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca >/dev/null) || fail "npx 껍질 세 번째 실행 실패"
grep -qxF 'BACKEND="${BACKEND:-orca}"' "$N/.ticket-loop/loop.env" || fail "BACKEND 줄이 없는 loop.env 에 줄을 덧붙이지 않음"
grep -q 'CI_SKIP_REGEX' "$N/.ticket-loop/loop.env" && grep -qxF 'AGENT="${AGENT:-claude}"' "$N/.ticket-loop/loop.env" || fail "BACKEND 줄을 덧붙이며 기존 줄을 잃음"
X="$T/npx-codex"; mkdir -p "$X"; git -C "$X" init -q -b main; git -C "$X" commit -q --allow-empty -m init
out="$(cd "$X" && node "$KIT/bin/ticket-loop-kit.js" init --yes --agent codex --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "--agent codex init 실패: $out"
grep -qxF 'AGENT="${AGENT:-codex}"' "$X/.ticket-loop/loop.env" || fail "--agent codex 가 loop.env 에 반영되지 않음"
grep -q 'setup-ticket-loop' <<<"$out" && grep -q 'In Codex' <<<"$out" || fail "codex 다음 단계 안내가 없음: $out"
(cd "$X" && node "$KIT/bin/ticket-loop-kit.js" init --yes --agent bogus >/dev/null 2>&1) && fail "모르는 에이전트를 거절해야 한다"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --backend bogus >/dev/null 2>&1) && fail "모르는 백엔드를 거절해야 한다"
C="$T/npx-cmux"; mkdir -p "$C"; git -C "$C" init -q -b main; git -C "$C" commit -q --allow-empty -m init
(cd "$C" && node "$KIT/bin/ticket-loop-kit.js" init --yes --backend cmux --no-skills --no-github --no-git-credential >/dev/null) || fail "cmux 백엔드 init 실패"
grep -qxF 'BACKEND="${BACKEND:-cmux}"' "$C/.ticket-loop/loop.env" || fail "cmux 선택이 loop.env 에 반영되지 않음"
grep -q 'WORKTREE_SETUP_CMD' "$C/.ticket-loop/loop.env" || fail "cmux loop.env 에 WORKTREE_SETUP_CMD 안내가 없음"
(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --bogus >/dev/null 2>&1) && fail "모르는 인자를 거절해야 한다"
echo "ok  npx 껍질 설치·재실행·백엔드 선택·거절"
echo "smoke 통과"
