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
for b in orca cmux tmux; do
  for f in check worktree_create worktree_remove send type interrupt wait_idle tail set_status; do
    grep -qE "^${b}_${f}\(\)" "$KIT/files/scripts/ticket-loop.sh" || fail "백엔드 ${b} 에 ${b}_${f} 함수가 없다"
  done
done
grep -qE '^backend_[a-z_]+\(\)' "$KIT/files/scripts/ticket-loop.sh" || fail "backend_* 디스패치 함수가 없다"
# 공통부에서 백엔드 CLI를 직접 부르면 안 된다(백엔드 절 밖의 orca_json / "$CMUX_CLI")
awk '/^# ---------- 백엔드 ----------/{on=1} /^# ----- 공통 -----/{on=0} !on && !/^\s*#/ && /orca_json|\$CMUX_CLI|\$ORCA_CLI|\$TMUX_CLI/' \
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
BACKEND=orca; ORCA_CLI=orca; CMUX_CLI=cmux; TMUX_CLI=tmux; TMUX_SESSION=""; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude; SKILL_PREFIX=/
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

# tmux 백엔드: 가짜 tmux 로 함수를 부르고, 훅 스크립트가 Claude Code(stdin)·Codex(인자) 페이로드를 상태 파일로 옮기는지, 기동 명령에 훅이 붙는지 본다.
# 실제 tmux 3.8 + Claude Code 로는 손으로 확인했다(초기 프롬프트 인자 → running, 응답 끝 → idle, send-keys 제출 → running→idle, /exit → exited)
cat > "$F/tmux" <<'SH'
#!/bin/bash
case "$1" in
  display) case "$*" in *window_name*) echo "issue-7" ;; *pane_id*) echo "%0" ;; *) echo "ticket-loop" ;; esac ;;
  send-keys) [[ "${@: -1}" != Enter || -z "${FAKE_STATE:-}" ]] || printf 'running\n' > "$FAKE_STATE" ;;
  capture-pane) printf 'Claude Code\n\n[Opus 5.5 | Max]\n\n\n' ;;
  has-session) exit 1 ;;
  new-session|new-window) echo "@0 %0" ;;
  kill-window|rename-window) ;;
  *) echo "fake tmux: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$F/tmux"
cat > "$F/run-tmux.sh" <<'SH'
set -euo pipefail
export HOME="$2"
BACKEND=tmux; ORCA_CLI=orca; CMUX_CLI=cmux; TMUX_CLI=tmux; TMUX_SESSION=""; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude; SKILL_PREFIX=/
AGENT_RESTART_CMD="claude --dangerously-skip-permissions"; TERMINAL_RETRY=1; TERMINAL_RETRY_SEC=0; IDLE_POLL_SEC=0; WORKTREE_DIR=""; WORKTREE_SETUP_CMD=""
log() { :; }; die() { echo "die: $*" >&2; exit 1; }
source "$1"
tmux_check
[[ "$AGENT_RESTART_CMD" == "claude --dangerously-skip-permissions --settings $HOME/.cache/ticket-loop/o-r/tmux/claude-hooks.json" ]] || die "claude 기동 명령에 --settings 가 안 붙음: $AGENT_RESTART_CMD"
jq -e '[.hooks.UserPromptSubmit, .hooks.Stop, .hooks.Notification, .hooks.SessionEnd] | all(.[0].hooks[0].command | startswith("bash "))' "$TMUX_DIR/claude-hooks.json" >/dev/null || die "claude-hooks.json"
S="$TMUX_DIR/state"
printf '{"hook_event_name":"UserPromptSubmit","cwd":"/w/issue-7"}' | bash "$TMUX_DIR/hook.sh" "$S"; [[ "$(cat "$S/issue-7")" == running ]] || die "UserPromptSubmit"
printf '{"hook_event_name":"Notification","notification_type":"auth_success","cwd":"/w/issue-7"}' | bash "$TMUX_DIR/hook.sh" "$S"; [[ "$(cat "$S/issue-7")" == running ]] || die "무관한 Notification 이 상태를 바꿈"
printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"/w/issue-7"}' | bash "$TMUX_DIR/hook.sh" "$S"; [[ "$(cat "$S/issue-7")" == needsInput ]] || die "permission_prompt"
printf '{"hook_event_name":"Stop","cwd":"/w/issue-7"}' | bash "$TMUX_DIR/hook.sh" "$S"; [[ "$(cat "$S/issue-7")" == idle ]] || die "Stop"
printf '{"hook_event_name":"SessionEnd","cwd":"/w/issue-7"}' | bash "$TMUX_DIR/hook.sh" "$S"; [[ "$(cat "$S/issue-7")" == exited ]] || die "SessionEnd"
bash "$TMUX_DIR/hook.sh" "$S" '{"type":"agent-turn-complete","cwd":"/w/issue-7"}'; [[ "$(cat "$S/issue-7")" == idle ]] || die "codex notify"
echo nonsense | bash "$TMUX_DIR/hook.sh" "$S" || die "훅은 알 수 없는 입력에도 0 으로 끝나야 한다"
TMUX_STATE_FILE="$S/issue-7"; export FAKE_STATE="$TMUX_STATE_FILE"
tmux_set_status @0 in-progress; tmux_set_status @0 todo "" "comment"; tmux_set_status @0 in-review 7 "PR #7"; tmux_set_status @0 completed 7 "done"
tmux_wait_idle %0 1000 || die "idle 인데 wait_idle 이 0 이 아님"
printf 'running\n' > "$TMUX_STATE_FILE"; rc=0; tmux_wait_idle %0 0 || rc=$?; [[ $rc -eq 1 ]] || die "running 인데 wait_idle 이 1(타임아웃)이 아님: $rc"
tmux_send %0 "hello" || die "send"; [[ "$(cat "$TMUX_STATE_FILE")" == running ]] || die "send 뒤 running 이 아님"
tmux_type %0 "claude x"; tmux_interrupt %0
[[ "$(tmux_tail %0 | tail -n1)" == "[Opus 5.5 | Max]" ]] || die "tail"
AGENT=codex AGENT_RESTART_CMD="codex --yolo"; tmux_check
# 셸이 풀면 TOML 배열 한 토큰이어야 한다(printf %q 로 인용해 셸에 치는 값)
eval "set -- $AGENT_RESTART_CMD"; [[ $# -eq 4 && "$4" == "notify=[\"bash\",\"$HOME/.cache/ticket-loop/o-r/tmux/hook.sh\",\"$HOME/.cache/ticket-loop/o-r/tmux/state\"]" ]] || die "codex 기동 명령에 notify 가 안 붙음: $AGENT_RESTART_CMD"
TMUX_STATE_FILE="$S/issue-7"; printf 'idle\n' > "$TMUX_STATE_FILE"; tmux_send %0 "hello" || die "codex send"; [[ "$(cat "$TMUX_STATE_FILE")" == running ]] || die "codex send 뒤 running 이 아님"
(AGENT=other; tmux_check) 2>/dev/null && die "tmux 백엔드는 모르는 에이전트를 거절해야 한다"
# Claude Code 폴더 신뢰: 메인 체크아웃이 ~/.claude.json 에 trust=true 가 아니면 시작 때 막는다(없는 파일·다른 에이전트는 통과)
AGENT=claude; printf '{"projects":{"/tmp":{"hasTrustDialogAccepted":false}}}' > "$HOME/.claude.json"
(tmux_check) 2>/dev/null && die "신뢰하지 않은 메인 체크아웃을 막아야 한다"
printf '{"projects":{"/tmp":{"hasTrustDialogAccepted":true}}}' > "$HOME/.claude.json"; tmux_check
(AGENT=codex; printf '{"projects":{}}' > "$HOME/.claude.json"; tmux_check) || die "codex 는 신뢰 검사를 건너뛰어야 한다"
rm -f "$HOME/.claude.json"
echo ok
SH
mkdir -p "$F/home"
(cd "$F" && PATH="$F:$PATH" bash run-tmux.sh "$F/backend.sh" "$F/home" >/dev/null) || fail "tmux 백엔드 함수 가짜 호출 실패"
echo "ok  tmux 백엔드 함수·훅 가짜 호출"

# cmux 백엔드: 가짜 cmux 로 wait_idle 의 세 경우 — lifecycle idle → 0, lifecycle 빈 값인데 화면은 읽힘 → 계속 기다림(타임아웃 1)과 안내 로그,
# 화면도 못 읽음 → 3(닿지 못함). 2026-10-14 rental-portal #100 에서 빈 값 5번(25초)으로 일하던 워커를 두고 루프가 죽은 오판을 고정한다
cat > "$F/cmux" <<'SH'
#!/bin/bash
case "$1" in
  rpc) [[ "${FAKE_LC:-}" == none ]] || echo "{\"lifecycle\":\"${FAKE_LC:-idle}\"}" ;;
  read-screen) if [[ "${FAKE_SCREEN:-ok}" == ok ]]; then echo "[Opus 5.5 | Max]"; else echo "Error: not_found: Workspace not found" >&2; exit 1; fi ;;
  *) exit 0 ;;
esac
SH
chmod +x "$F/cmux"
cat > "$F/run-cmux.sh" <<'SH'
set -euo pipefail
BACKEND=cmux; ORCA_CLI=orca; CMUX_CLI=cmux; TMUX_CLI=tmux; TMUX_SESSION=""; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude; SKILL_PREFIX=/
AGENT_RESTART_CMD=claude; TERMINAL_RETRY=2; TERMINAL_RETRY_SEC=0; IDLE_POLL_SEC=0; WORKTREE_DIR=""; WORKTREE_SETUP_CMD=""
LOGGED=""; log() { LOGGED+="$*"$'\n'; }; die() { echo "die: $*" >&2; exit 1; }
source "$1"
export FAKE_LC=idle FAKE_SCREEN=ok; cmux_wait_idle s1 1000 || die "idle 인데 wait_idle 이 0 이 아님"
export FAKE_LC=none FAKE_SCREEN=ok; rc=0; cmux_wait_idle s1 0 || rc=$?; [[ $rc -eq 1 ]] || die "lifecycle 빈 값·화면 읽힘인데 1(계속 기다림)이 아님: $rc"
[[ "$LOGGED" == *"keep waiting"* ]] || die "화면이 읽히는데 안내 로그가 없다"
export FAKE_LC=none FAKE_SCREEN=gone; rc=0; cmux_wait_idle s1 60000 || rc=$?; [[ $rc -eq 3 ]] || die "lifecycle 빈 값·화면도 못 읽는데 3 이 아님: $rc"
echo ok
SH
(cd "$F" && PATH="$F:$PATH" bash run-cmux.sh "$F/backend.sh" >/dev/null) || fail "cmux 백엔드 wait_idle 가짜 호출 실패"
echo "ok  cmux 백엔드 wait_idle 세 경우"

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
grep -q 'AGENT=\${AGENT} has no preset' "$KIT/files/scripts/ticket-loop.sh" || fail "모르는 AGENT 를 시작 때 멈추는 검사가 없음"
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
  if [[ "$2" == closed ]]; then grep -q '^issue close 40 ' "$S/gh.log" && grep -q 'spec #40: all 2 sub-issues closed' <<<"$out" && grep -q '^CLOSED= 40$' <<<"$out" || fail "모두 닫힌 스펙을 닫지 않았거나 CLOSED_SPECS 에 적지 않음: $out"
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
grep -q '^spec #40 complete. If you like, review this batch with /retro' <<<"$out" && grep -q 'report reports/spec-40.html' <<<"$out" && grep -q 'loop-0101.log' <<<"$out" || fail "회고 안내 문구가 다름: $out"
! grep -q -iE 'must|required|mandatory' <<<"$out" || fail "회고 안내가 강제 어조: $out"
out="$(retro_case " 40 41" "reports" "$S")" || fail "suggest_retro(둘) 실패"
[[ "$(grep -c '^spec #' <<<"$out")" == 2 ]] && grep -q 'can be generated with ticket-loop.sh --parent 41' <<<"$out" || fail "리포트 없는 스펙 안내가 다름: $out"
out="$(retro_case " 40" "reports" "$T/nowhere")" || fail "suggest_retro(스킬 없음) 실패"
grep -q '/retro (not in this repository yet' <<<"$out" || fail "retro 스킬이 없을 때 안내가 다름: $out"
out="$(retro_case "" "reports" "$S")" || fail "suggest_retro(빈) 실패"
[[ -z "$out" ]] || fail "끝난 스펙이 없는데 회고 안내가 나옴: $out"
grep -c -E '^suggest_retro$|; suggest_retro; ' "$KIT/files/scripts/ticket-loop.sh" | grep -qx 2 || fail "suggest_retro 호출이 두 곳(티켓 없음·정상 종료)이 아니다"
echo "ok  회고 안내"

# 리포트 자동 열기 — 가짜 open·xdg-open으로 세 경우를 본다: REPORT_OPEN=0 → 안 연다, SSH 세션 → 안 연다, 켬 → 연다
O="$T/open"; mkdir -p "$O"
for b in open xdg-open; do printf '#!/bin/bash\necho "%s $*" >> "$OPEN_LOG"\n' "$b" > "$O/$b"; chmod +x "$O/$b"; done
sed -n '/^open_report() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$O/fn.sh"
grep -q 'xdg-open' "$O/fn.sh" || fail "open_report 를 찾지 못함"
open_case() {  # $1 환경 설정(bash 문장), $2 기대(opened|skipped)
  : > "$O/open.log"
  (cd "$O" && env -u SSH_CONNECTION -u SSH_TTY PATH="$O:$PATH" OPEN_LOG="$O/open.log" DISPLAY=:0 \
     bash -c "set -euo pipefail; REPORT_OPEN=1; $1; source fn.sh; open_report /x/spec-7.html") || fail "open_report 실패($2)"
  if [[ "$2" == opened ]]; then grep -q ' /x/spec-7.html$' "$O/open.log" || fail "리포트를 열지 않음"
  else [[ ! -s "$O/open.log" ]] || fail "열면 안 되는 경우($1)에 열음"; fi
}
open_case 'REPORT_OPEN=0' skipped
open_case 'export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"' skipped
open_case ':' opened
grep -q '^    open_report "\$out"$' "$KIT/files/scripts/ticket-loop.sh" || fail "리포트 생성 성공 분기에서 open_report 를 부르지 않는다"
echo "ok  리포트 자동 열기"

# 터미널 로그 색: 색을 켜면 단계별로 감싸고 메시지는 맨글자, 색을 끄면 전과 같은 "[시각] 메시지", 파일 쪽 strip_ansi 는 SGR 만 지운다
G="$T/logcolor"; mkdir -p "$G"
sed -n '/^# 터미널 색 — /,/^dim_lines() /p' "$KIT/files/scripts/ticket-loop.sh" > "$G/fn.sh"
grep -q '^strip_ansi() {' "$G/fn.sh" && grep -q '^log() {' "$G/fn.sh" && grep -q '^dim_lines() ' "$G/fn.sh" || fail "색 로그 함수(strip_ansi·log·dim_lines)를 찾지 못함"
logc() { (cd "$G" && DRY_RUN=1 LOG_FILE=/dev/null bash -c 'set -euo pipefail; source fn.sh; '"$1" 2>&1 | LC_ALL=C sed $'s/\e/<ESC>/g'); }
out="$(logc 'log ok "x"; log "y"; log warn')" || fail "파이프에서 log 실패"
[[ "$out" == "[20"*"] x"$'\n'"[20"*"] y"$'\n'"[20"*"] warn" ]] && [[ "$out" != *"<ESC>"* ]] || fail "파이프(색 없음)에서 log 출력이 전과 다르다: $out"
paint='C_RESET=$'"'"'\e[0m'"'"'; C_DIM=$'"'"'\e[2m'"'"'; C_TITLE=t; C_STEP=s; C_OK=o; C_WARN=w; C_ERR=e; '
out="$(logc "$paint"'log title "T"; log step "S"; log ok "O"; log warn "W"; log err "E"; log "P"; log ok; printf "a\nb" | dim_lines; printf "1\n" | dim_lines "  #"')" || fail "색을 켠 log 실패"
[[ "$out" == $'\n'"<ESC>[2m[20"*"]<ESC>[0m tT<ESC>[0m"$'\n'"<ESC>[2m[20"*"]<ESC>[0m sS<ESC>[0m"$'\n'*"]<ESC>[0m oO<ESC>[0m"$'\n'*"]<ESC>[0m wW<ESC>[0m"$'\n'*"]<ESC>[0m eE<ESC>[0m"$'\n'*"]<ESC>[0m P"$'\n'*"]<ESC>[0m ok"$'\n'"<ESC>[2m  a<ESC>[0m"$'\n'"<ESC>[2m  b<ESC>[0m"$'\n'"<ESC>[2m  #1<ESC>[0m" ]] \
  || fail "색을 켠 log 의 단계별 감싸기가 다르다: $out"
out="$(cd "$G" && printf '\e[2m[t]\e[0m \e[1;35m=== #1 ===\e[0m\n\e[2J keep \e[m x\e[1;31mY\nno newline' | DRY_RUN=1 LOG_FILE=/dev/null bash -c 'set -euo pipefail; source fn.sh; strip_ansi' | LC_ALL=C sed $'s/\e/<ESC>/g')" || fail "strip_ansi 실패"
[[ "$out" == "[t] === #1 ==="$'\n'"<ESC>[2J keep  xY"$'\n'"no newline" ]] || fail "strip_ansi 가 SGR 만 지우지 않는다: $out"
grep -q 'exec 2> >(tee >(strip_ansi >> "$LOG_FILE") >&2)' "$KIT/files/scripts/ticket-loop.sh" || fail "색을 켤 때 로그 파일 쪽에 strip_ansi 가 없음"
echo "ok  터미널 로그 색"

# 병합 뒤 검증 로그 경로: LOG_FILE 이 상대 경로여도 post-merge-N.log 는 저장소 루트 쪽 .ticket-loop/ 에 생기고, 실패 꼬리가 비지 않는다.
# 2026-10-15 rental-portal #101 실측 — 리다이렉트가 cd "$wt" 뒤 서브셸에서 열려 로그가 검증 워크트리 안에 생기고 tail 은 "No such file" 이었다.
# 실제 git 저장소(origin 역할 bare + 메인 체크아웃)와 검증 워크트리를 만들어 run_post_merge 를 그대로 부른다(GitHub·백엔드 없이)
P="$(cd "$T" && pwd -P)/postmerge"; mkdir -p "$P"   # git rev-parse 가 돌려주는 실제 경로(macOS 의 /private/var)와 맞춘다
git -C "$P" init -q --bare origin.git
git clone -q "$P/origin.git" "$P/repo" 2>/dev/null; git -C "$P/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; git -C "$P/repo" push -q origin HEAD:main 2>/dev/null
sed -n '/^# ---------- 병합 뒤 검증 ----------/,/^# ---------- 티켓 기록 · 스펙 리포트 ----------/p' "$KIT/files/scripts/ticket-loop.sh" > "$P/fn.sh"
grep -q '^run_post_merge() {' "$P/fn.sh" || fail "run_post_merge 를 찾지 못함"
sed -n '/^abs_path() /p' "$KIT/files/scripts/ticket-loop.sh" >> "$P/fn.sh"
sed -n '/^bg_wait() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$P/fn.sh"   # 검증 명령은 bg_wait 로 돈다
grep -q '^abs_path() ' "$P/fn.sh" && grep -q '^bg_wait() ' "$P/fn.sh" || fail "abs_path·bg_wait 를 찾지 못함"
postmerge_case() {  # $1 POST_MERGE_CMD, $2 LOG_FILE(상대), $3 기대(pass|fail) → 출력(stderr 포함)
  (cd "$P/repo" && POST_MERGE_CMD="$1" LOG_FILE="$2" POST_MERGE_WORKTREE="$P/wt" EXPECT="$3" FN="$P/fn.sh" bash -c '
    set -euo pipefail
    ROOT="$(git rev-parse --show-toplevel)"; MAIN_WT="$ROOT"; OWNER_REPO=o/r; BASE_BRANCH=main; POST_MERGE_COPY=""; POST_MERGE_PORT=""; PORT_WAIT_SEC=0
    log() { shift; echo "$*"; }; dim_lines() { local l; while IFS= read -r l; do echo "  $l"; done; }; fmt_epoch() { echo "$1"; }
    source "$FN"
    LOG_FILE="$(abs_path "$LOG_FILE")"
    rc=0; run_post_merge 7 || rc=$?
    [[ "$EXPECT" == pass && $rc -eq 0 || "$EXPECT" == fail && $rc -eq 1 ]] || { echo "rc=$rc"; exit 9; }
    echo "POST_MERGE_LOG=$POST_MERGE_LOG"' 2>&1)
}
out="$(postmerge_case 'echo hello-from-post-merge; exit 1' '.ticket-loop/loop-0101.log' fail)" || fail "run_post_merge(실패) 가 1 로 끝나지 않음: $out"
[[ -f "$P/repo/.ticket-loop/post-merge-7.log" ]] || fail "post-merge 로그가 저장소 루트 쪽 .ticket-loop/ 에 없다 (ls: $(ls -R "$P/wt/.ticket-loop" 2>/dev/null))"
[[ ! -e "$P/wt/.ticket-loop" ]] || fail "post-merge 로그가 검증 워크트리 안에 생겼다(0.8.4 이하의 버그)"
grep -q '^  hello-from-post-merge$' <<<"$out" || fail "실패 꼬리가 비었다: $out"
! grep -q 'No such file' <<<"$out" || fail "꼬리 tail 이 파일을 못 찾았다: $out"
grep -q "post-merge check started ($P/wt, log $P/repo/.ticket-loop/post-merge-7.log)" <<<"$out" || fail "시작 줄의 로그 경로가 실제 위치(절대 경로)가 아니다: $out"
grep -q "^POST_MERGE_LOG=$P/repo/.ticket-loop/post-merge-7.log$" <<<"$out" || fail "POST_MERGE_LOG(die 가 찍는 경로)가 절대 경로가 아니다: $out"
out="$(postmerge_case 'exit 0' 'sub/dir/loop.log' pass)" || fail "run_post_merge(통과) 실패: $out"
[[ -f "$P/repo/sub/dir/post-merge-7.log" ]] || fail "LOG_FILE 을 다른 상대 디렉터리로 줘도 저장소 루트 기준이어야 한다"
grep -q 'post-merge check passed in [0-9]*s' <<<"$out" || fail "통과 줄이 없음: $out"
grep -q 'log (${POST_MERGE_LOG})' "$KIT/files/scripts/ticket-loop.sh" || fail "병합 뒤 검증 실패 die 줄에 로그 경로가 없다"
grep -q 'LOG_START_BYTES=$(( $(wc -c < "$LOG_FILE") ))' "$KIT/files/scripts/ticket-loop.sh" || fail "시작 때 로그 파일 크기(LOG_START_BYTES)를 기억하지 않음"
grep -q '^LOG_FILE="$(abs_path "$LOG_FILE")"$' "$KIT/files/scripts/ticket-loop.sh" && grep -q '^RECORDS_FILE="$(abs_path "$RECORDS_FILE")"$' "$KIT/files/scripts/ticket-loop.sh" && grep -q '^REPORT_DIR="$(abs_path "$REPORT_DIR")"$' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "LOG_FILE·RECORDS_FILE·REPORT_DIR 를 시작 때 절대 경로로 굳히지 않는다"
[[ "$(cd "$P/repo" && ROOT="$P/repo" FN="$P/fn.sh" bash -c 'source "$FN"; abs_path /dev/null; echo; abs_path /abs/x; echo; abs_path rel/y')" == $'/dev/null\n/abs/x\n'"$P/repo/rel/y" ]] || fail "abs_path 가 /dev/null·절대 경로를 그대로 두고 상대 경로만 ROOT 에 붙이지 않는다"
echo "ok  병합 뒤 검증 로그 경로(저장소 루트 기준·실패 꼬리)"

# 진행 로그: 실제 git 저장소에서 progress_reset/check 를 그대로 부른다 — 브랜치·첫 수정·커밋은 바로 한 줄, 심장박동은 변경 파일 목록이
# 지난 줄과 다를 때만(같으면 HEARTBEAT_SEC=0 이어도 조용하다)
Q="$T/progress"; mkdir -p "$Q"; git -C "$Q" init -q -b main repo; git -C "$Q/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
sed -n '/^# ----- 진행 로그 -----/,/^# ----- 진행 로그 끝 -----/p' "$KIT/files/scripts/ticket-loop.sh" > "$Q/fn.sh"
grep -q '^progress_check() ' "$Q/fn.sh" && grep -q '^idle_wait_ms() ' "$Q/fn.sh" || fail "진행 로그 함수(progress_check·idle_wait_ms)를 찾지 못함"
out="$(cd "$Q" && FN="$Q/fn.sh" bash -c '
  set -euo pipefail
  log() { echo "[$1] ${*:2}"; }; c() { git -C repo -c user.name=t -c user.email=t@t "$@"; }
  PROGRESS_SEC=60; IDLE_WAIT_MS=600000; HEARTBEAT_SEC=300
  source "$FN"
  progress_reset "$PWD/repo"
  echo "== quiet"; progress_check 7
  echo "== quiet-heartbeat0"; HEARTBEAT_SEC=0 progress_check 7
  echo "== branch+edit"; c checkout -q -b issue-7-export; printf a > repo/a.ts; printf b > repo/b.ts; printf c > repo/c.ts; printf d > repo/d.ts; progress_check 7
  echo "== same"; progress_check 7
  echo "== commits"; c add a.ts; c commit -q -m "feat: a #7"; c add b.ts; c commit -q -m "test: b #7"; progress_check 7
  echo "== amend"; c commit -q --amend -m "test: b amended #7"; progress_check 7
  echo "== heartbeat-after-commit"; HEARTBEAT_SEC=0 progress_check 7
  echo "== heartbeat-changed"; printf e > repo/e.ts; HEARTBEAT_SEC=0 progress_check 7
  echo "== sync"; progress_sync; HEARTBEAT_SEC=0 progress_check 7
  echo "== wait $(idle_wait_ms) $(PROGRESS_SEC=0 idle_wait_ms)"
  echo "== gone"; PROG_WT=/nonexistent progress_check 7' 2>&1)" || fail "진행 로그 함수 실패: $out"
want="== quiet
== quiet-heartbeat0
== branch+edit
[step] #7: branch issue-7-export
[step] #7: first file changes — a.ts, b.ts, c.ts +1 more
== same
== commits
[step] #7: commit SHA feat: a #7
[step] #7: commit SHA test: b #7
== amend
[step] #7: commit SHA test: b amended #7
== heartbeat-after-commit
== heartbeat-changed
[#7: working — 0m elapsed, 3 uncommitted files: c.ts, d.ts, e.ts] 
== sync
== wait 60000 600000
== gone"
[[ "$(sed -E 's/commit [0-9a-f]{7,} /commit SHA /' <<<"$out")" == "$want" ]] || fail "진행 로그 출력이 기대와 다르다:
$out"
grep -q 'progress_reset "${wt_path}"' "$KIT/files/scripts/ticket-loop.sh" && grep -q '^  progress_sync$' "$KIT/files/scripts/ticket-loop.sh" || fail "run_ticket 이 progress_reset(PR 대기 전)·progress_sync(PR 열린 뒤)를 부모 셸에서 부르지 않는다"
[[ "$(grep -c 'progress_check "${n}"\|progress_check "${CUR_N}"' "$KIT/files/scripts/ticket-loop.sh")" -ge 3 ]] || fail "wait_for_pr·repair 가 progress_check 를 부르지 않는다"
echo "ok  진행 로그(브랜치·첫 수정·커밋·심장박동은 목록이 달라질 때만)"

# 티켓의 PR 찾기: head 브랜치가 issue-N 과 같거나 issue-N- 로 시작하는 것만. issue-1020·issue-1020-x 는 #102 가 아니다
# (rental-portal #102 실측 — 워커가 워크트리 브랜치 issue-102 에 그대로 커밋해 PR 을 열었고 접두 `N-`만 보던 루프가 못 찾았다)
P="$T/prfind"; mkdir -p "$P"
sed -n '/^open_pr_for() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$P/fn.sh"
grep -q '^open_pr_for() ' "$P/fn.sh" || fail "open_pr_for 를 찾지 못함"
printf '#!/usr/bin/env bash\ncat "$PRS"\n' > "$P/gh"; chmod +x "$P/gh"
prfind() { (cd "$P" && PATH="$P:$PATH" PRS="$P/prs.json" BRANCH_PREFIX=issue- bash -c 'set -euo pipefail; source fn.sh; open_pr_for 102'); }
echo '[{"number":130,"headRefName":"issue-1020"},{"number":131,"headRefName":"issue-1020-x"},{"number":120,"headRefName":"issue-102"}]' > "$P/prs.json"
[[ "$(prfind)" == "120" ]] || fail "open_pr_for: head 가 issue-102 인 PR 을 못 찾음(또는 issue-1020 을 잡음): $(prfind)"
echo '[{"number":130,"headRefName":"issue-1020"},{"number":121,"headRefName":"issue-102-dispatch-cutoff"}]' > "$P/prs.json"
[[ "$(prfind)" == "121" ]] || fail "open_pr_for: head 가 issue-102-slug 인 PR 을 못 찾음: $(prfind)"
echo '[{"number":130,"headRefName":"issue-1020"},{"number":131,"headRefName":"issue-1020-x"},{"number":132,"headRefName":"issue-10"}]' > "$P/prs.json"
[[ -z "$(prfind)" ]] || fail "open_pr_for: issue-1020·issue-1020-x·issue-10 을 #102 로 잡음: $(prfind)"
echo '[]' > "$P/prs.json"
[[ -z "$(prfind)" ]] || fail "open_pr_for: PR 이 없는데 값이 나옴"
# ticket-state.sh 의 PR 필터도 같은 규칙, 원격 브랜치 조회는 issue-N 과 issue-N-* 둘 다
TS_JQ="$(grep -o "jq -r --arg b \"\$b\" '[^']*'" "$KIT/files/scripts/ticket-state.sh" | sed "s/^jq -r --arg b \"\$b\" '//; s/'\$//")"
[[ -n "$TS_JQ" ]] || fail "ticket-state.sh 의 jq 필터를 찾지 못함"
out="$(jq -r --arg b issue-102 "$TS_JQ" <<<'[{"number":130,"state":"OPEN","headRefName":"issue-1020"},{"number":131,"state":"MERGED","headRefName":"issue-1020-x"},{"number":120,"state":"MERGED","headRefName":"issue-102"},{"number":121,"state":"CLOSED","headRefName":"issue-102-slug"}]')"
[[ "$out" == $'#120 MERGED issue-102\n#121 CLOSED issue-102-slug' ]] || fail "ticket-state.sh PR 필터: $out"
grep -qF 'git ls-remote --heads origin "refs/heads/${b}" "refs/heads/${b}-*"' "$KIT/files/scripts/ticket-state.sh" || fail "ticket-state.sh 원격 브랜치 조회가 issue-N 과 issue-N-* 둘 다 보지 않음"
grep -qE 'grep -E "/\$\{BRANCH_PREFIX:-issue-\}\$\{n\}\( \|-\|\$\)"' "$KIT/files/scripts/ticket-state.sh" || fail "ticket-state.sh 워크트리 조회 패턴이 바뀜"
echo "ok  티켓 PR 찾기(issue-N·issue-N-slug 는 잡고 issue-N0 은 안 잡음)·ticket-state 필터"

# 알림·멈춤 보고: 가짜 gh·curl·osascript 로 블록을 그대로 부른다(GitHub·Slack·데스크톱 없이).
#   멈춤은 어떻게 끝나든 한 번 — die·set -e·HUP·INT·TERM·PIPE(정상 종료는 없음), 종료 코드는 그대로, 잠금은 이 실행이 잡았을 때만 푼다
#   Slack: 아이콘·이스케이프(&<>)·#N 링크·멘션은 stop 만(Ctrl-C 는 없음)·로그 꼬리(워커 화면 포함), 웹훅이 없거나 잠금을 안 잡은 실행은 안 보낸다
#   GitHub 기록: 라벨 만들기·코멘트(사유·머신·PR·모델·워크트리 ~·로그는 루프 자신의 줄만)·라벨 붙이기
M="$(cd "$T" && pwd -P)/stop"; mkdir -p "$M/bin"
sed -n '/^# ----- 알림 · 멈춤 보고 -----/,/^# ----- 알림 · 멈춤 보고 끝 -----/p' "$KIT/files/scripts/ticket-loop.sh" > "$M/fn.sh"
grep -q '^stop_report() ' "$M/fn.sh" && grep -q '^on_signal() ' "$M/fn.sh" && grep -q '^on_exit() ' "$M/fn.sh" || fail "알림·멈춤 보고 블록을 찾지 못함"
for b in gh curl osascript; do   # 인자를 \x1e 로 이어 JSON 한 줄로 남긴다(본문의 줄바꿈·따옴표도 그대로)
  printf '#!/usr/bin/env bash\nprintf "%%s\\x1e" "$@" | jq -Rsc --arg cmd %s '"'"'{cmd: $cmd, args: (split("\\u001e")[:-1])}'"'"' >> "$CALLS"\n' "$b" > "$M/bin/$b"
  chmod +x "$M/bin/$b"
done
cat > "$M/run.sh" <<'EOF'
set -euo pipefail
ROOT="$PWD"; OWNER_REPO=o/r; BACKEND=orca; BACKEND_NAME=Orca; AGENT=claude
SLACK_WEBHOOK_URL=https://hooks.example/x; SLACK_MENTION="<@U1>"; STOPPED_LABEL=loop-stopped
LOG_FILE="$PWD/loop.log"; LOCK_DIR="$PWD/lock"
log() { case "$1" in title|step|ok|warn|err) shift ;; esac; printf '[2026-10-15 10:02:00] %s\n' "$*" >> "$LOG_FILE"; }
record_ticket() { printf '%s|%s\n' "$1" "$2" >> rec; }
source fn.sh
REPO_URL=https://github.com/o/r
trap on_exit EXIT; trap 'on_signal HUP' HUP; trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal PIPE' PIPE
mkdir "$LOCK_DIR"; LOCK_HELD=1
CUR_N=12; STOP_ISSUE=12; CUR_PR=34; CUR_STARTED=$(( $(date +%s) - 125 )); CUR_MODEL="Opus 5.5"; WT_PATH="$HOME/wt/issue-12"; mkdir -p "$WT_PATH"
eval "${2:-}"
case "$1" in
  die) die '#12: PR #34 CI failed — "x" <y> & z' ;;
  errexit) git -C /nonexistent fetch -q origin main 2>/dev/null ;;
  HUP|INT|TERM|PIPE) kill -"$1" $$; sleep 5 ;;
  bgwait) bg_wait sleep 31.7 ;;   # 루프 pid에만 오는 신호를 밖에서 보낸다
  bgcodes) f() { false; echo after-false; }; out="$(bg_wait f)"; rc3=0; bg_wait sh -c 'exit 3' || rc3=$?; echo "$out|$rc3" > bgcodes ;;
  ok) : ;;
esac
EOF
stop_case() {  # $1 어떻게 끝나나(die|errexit|HUP|INT|TERM|ok), $2 덧붙일 설정(bash 문장) → 종료 코드
  rm -rf "$M/calls.jsonl" "$M/rec" "$M/lock"; : > "$M/calls.jsonl"
  printf '[2026-10-15 09:00:00] ERROR: previous-run-line\n' > "$M/loop.log"   # 같은 날 앞 실행 — 이 실행의 보고에 실리면 안 된다
  local start; start=$(( $(wc -c < "$M/loop.log") ))
  printf '[2026-10-15 10:00:00] #12: PR #34 opened\n  worker-screen-line\n' >> "$M/loop.log"
  local rc=0
  (cd "$M" && PATH="$M/bin:$PATH" CALLS="$M/calls.jsonl" HOME="$M/home" LOG_START_BYTES="$start" bash run.sh "$1" "${2:-}" 2>/dev/null) || rc=$?
  echo "$rc"
}
calls() { jq -s --arg c "$1" '[.[] | select(.cmd == $c)] | length' "$M/calls.jsonl"; }
slack_text() { jq -rs '[.[] | select(.cmd == "curl")][0].args as $a | $a[($a | index("--data")) + 1] | fromjson | .text' "$M/calls.jsonl"; }
gh_comment() { jq -rs '[.[] | select(.cmd == "gh" and .args[1] == "comment")][0].args as $a | ($a[2] + "\n" + $a[($a | index("--body")) + 1])' "$M/calls.jsonl"; }
L='<https://github.com/o/r/issues'
rc="$(stop_case die)"; [[ "$rc" == 1 ]] || fail "die 종료 코드: $rc"
[[ "$(cat "$M/rec")" == 'stopped|#12: PR #34 CI failed — "x" <y> & z' ]] || fail "die: 티켓 기록: $(cat "$M/rec")"
[[ "$(calls curl)" == 1 && "$(calls osascript)" == 1 ]] || fail "die: Slack·데스크톱 알림이 한 번씩이 아님(curl $(calls curl), osascript $(calls osascript))"
out="$(slack_text)"
[[ "$out" == ":octagonal_sign: *Ticket loop stopped* · o/r · "* ]] || fail "die: Slack 머리줄: $out"
grep -qF "<@U1> $L/12|#12>: PR $L/34|#34> CI failed — \"x\" &lt;y&gt; &amp; z" <<<"$out" || fail "die: Slack 본문(멘션·링크·이스케이프): $out"
grep -qF '```' <<<"$out" && grep -qF 'worker-screen-line' <<<"$out" && grep -qF 'ERROR: #12: PR #34' <<<"$out" || fail "die: Slack 에 로그 꼬리(워커 화면·ERROR 줄)가 없음: $out"
[[ "$(jq -rs '[.[] | select(.cmd == "osascript")][0].args[-2:] | join("|")' "$M/calls.jsonl")" == 'Ticket loop stopped|#12: PR #34 CI failed — "x" <y> & z' ]] || fail "die: 데스크톱 알림 문구가 인자로 가지 않음"
[[ "$(jq -rs '[.[] | select(.cmd == "gh") | .args[0:2] | join(" ")] | join(",")' "$M/calls.jsonl")" == "label create,issue comment,issue edit" ]] || fail "die: gh 호출 순서: $(jq -c . "$M/calls.jsonl")"
jq -e -s '[.[] | select(.cmd == "gh" and .args[1] == "edit")][0].args | . == ["issue","edit","12","--add-label","loop-stopped"]' "$M/calls.jsonl" >/dev/null || fail "die: 라벨 붙이기 인자"
out="$(gh_comment)"
for want in $'12\n**ticket-loop 중단** — #12: PR #34 CI failed' '에이전트 claude (Opus 5.5)' '(2분)' '- PR #34' '워크트리 `~/wt/issue-12` — 조사용' '루프 로그 `loop.log`' '<details><summary>루프 로그 마지막 2줄</summary>' 'ERROR: #12: PR #34 CI failed'; do
  grep -qF -- "$want" <<<"$out" || fail "die: GitHub 코멘트에 '$want' 없음: $out"
done
! grep -q 'worker-screen-line' <<<"$out" || fail "die: GitHub 코멘트에 워커 화면 줄이 실림(루프 자신의 줄만이어야 한다)"
! grep -q 'previous-run-line' <<<"$out" && ! grep -q 'previous-run-line' <<<"$(slack_text)" || fail "die: 같은 날 앞 실행의 로그 줄이 GitHub·Slack 보고에 섞임"
[[ ! -e "$M/lock" ]] || fail "die: 잡은 잠금을 풀지 않음"
rc="$(stop_case errexit)"; [[ "$rc" == 128 ]] || fail "set -e 종료 코드가 걸린 명령의 것이 아님: $rc"
[[ "$(cat "$M/rec")" == 'stopped|#12: unexpected exit (status 128) at: git -C /nonexistent fetch -q origin main 2> /dev/null' ]] || fail "set -e: 사유: $(cat "$M/rec")"
[[ "$(calls curl)" == 1 ]] && grep -qF "<@U1> $L/12|#12>: unexpected exit (status 128)" <<<"$(slack_text)" || fail "set -e: Slack: $(slack_text)"
[[ ! -e "$M/lock" ]] || fail "set -e: 잠금을 풀지 않음"
for sig in HUP INT TERM PIPE; do
  rc="$(stop_case "$sig")"
  case "$sig" in HUP) want=129; why="terminal closed (SIGHUP)" ;; INT) want=130; why="interrupted (Ctrl-C)" ;; TERM) want=143; why="terminated (SIGTERM)" ;; PIPE) want=141; why="log output closed (SIGPIPE — terminal gone?)" ;; esac
  [[ "$rc" == "$want" ]] || fail "SIG${sig} 종료 코드: $rc"
  [[ "$(cat "$M/rec")" == "stopped|#12: ${why}" ]] || fail "SIG${sig}: 사유: $(cat "$M/rec")"
  [[ "$(calls curl)" == 1 && "$(jq -s '[.[] | select(.cmd == "gh" and .args[1] == "comment")] | length' "$M/calls.jsonl")" == 1 ]] || fail "SIG${sig}: 보고가 한 번이 아님"
  out="$(slack_text)"
  if [[ "$sig" == INT ]]; then
    grep -qF "$L/12|#12>: ${why}" <<<"$out" && ! grep -qF '<@U1>' <<<"$out" || fail "Ctrl-C 는 멘션 없이 알려야 함: $out"
  else
    grep -qF "<@U1> $L/12|#12>: ${why}" <<<"$out" || fail "SIG${sig}: Slack: $out"
  fi
  [[ ! -e "$M/lock" ]] || fail "SIG${sig}: 잠금을 풀지 않음"
done
rc="$(stop_case ok)"; [[ "$rc" == 0 && ! -s "$M/calls.jsonl" && ! -e "$M/rec" && ! -e "$M/lock" ]] || fail "정상 종료인데 보고했거나 잠금이 남음(rc $rc): $(cat "$M/calls.jsonl")"
rc="$(stop_case die 'LOCK_HELD=0; STOP_ISSUE=; CUR_N=')"   # 이미 도는 루프와 겹친 실행: 시작 전에 멈춘다
[[ "$rc" == 1 && "$(calls curl)" == 0 && "$(calls gh)" == 0 && "$(calls osascript)" == 1 && -d "$M/lock" ]] || fail "잠금을 못 잡은 실행은 Slack·GitHub 없이 데스크톱만, 남의 잠금은 그대로여야 함(rc $rc): $(cat "$M/calls.jsonl")"
rc="$(stop_case die 'SLACK_WEBHOOK_URL=')"; [[ "$rc" == 1 && "$(calls curl)" == 0 && "$(calls gh)" == 3 ]] || fail "웹훅이 없으면 Slack 만 빠져야 함: $(cat "$M/calls.jsonl")"
rc="$(stop_case ok 'notify "Ticket done" "#12 T01 & co — PR #34, 5m" done; STOP_ISSUE=')"
out="$(slack_text)"; [[ "$rc" == 0 && "$out" == ":white_check_mark: *Ticket done* · o/r · "*$'\n'"$L/12|#12> T01 &amp; co — PR $L/34|#34>, 5m" ]] || fail "완료 알림: $out"
rc="$(stop_case ok 'REPO_URL=; slack_post "Ticket loop started" "1 ticket"$'"'"'\n'"'"'"#12 T01" start')"
out="$(slack_text)"; [[ "$out" == ":arrow_forward: *Ticket loop started* · o/r · "*$'\n1 ticket\n#12 T01' ]] || fail "시작 알림(저장소 URL 없으면 링크 없이): $out"
# 오래 기다리는 중(bg_wait)에 루프 pid 에만 온 신호도 바로 처리하고 기다리던 자식을 끝낸다. 포그라운드 자식이면 bash 가 trap 을 미뤄
# PR 대기 내내 먹히지 않았다(0.8.8 실측: 더미 저장소·cmux 에서 SIGHUP 이 2분 뒤 처리). bg_wait 는 종료 코드를 돌려주고 set +e 로 돈다
rm -rf "$M/calls.jsonl" "$M/rec" "$M/lock"; : > "$M/calls.jsonl"; : > "$M/loop.log"
(cd "$M" && PATH="$M/bin:$PATH" CALLS="$M/calls.jsonl" HOME="$M/home" exec bash run.sh bgwait 2>/dev/null) & bp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'sleep 31.7' >/dev/null && break; sleep 0.3; done
t0="$(date +%s)"; kill -TERM "$bp"; rc=0; wait "$bp" || rc=$?; t1="$(date +%s)"
[[ "$rc" == 143 && $((t1 - t0)) -le 8 ]] || fail "bg_wait 중 루프 pid 에만 온 TERM 이 바로 처리되지 않음(rc $rc, $((t1 - t0))초)"
[[ "$(cat "$M/rec")" == "stopped|#12: terminated (SIGTERM)" && "$(calls curl)" == 1 ]] || fail "bg_wait 중 TERM: 보고가 다름: $(cat "$M/rec")"
sleep 0.5; ! pgrep -f 'sleep 31.7' >/dev/null || { pkill -f 'sleep 31.7'; fail "bg_wait 로 기다리던 자식이 남음"; }
rm -f "$M/bgcodes"; rc="$(stop_case bgcodes)"; [[ "$rc" == 0 && "$(cat "$M/bgcodes" 2>/dev/null)" == "after-false|3" ]] || fail "bg_wait 종료 코드·set +e: $(cat "$M/bgcodes" 2>/dev/null) (rc $rc)"
grep -q 'bg_wait wait_for_pr "${n}"' "$KIT/files/scripts/ticket-loop.sh" && grep -q 'bg_wait gh pr checks "$1" --watch' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -q 'bg_wait terminal_idle "${handle}"' "$KIT/files/scripts/ticket-loop.sh" && grep -q 'bg_wait bash -c .* "$POST_MERGE_CMD"' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -q 'bg_wait env LOOP_ROOT_PATH=.* "$WORKTREE_SETUP_CMD"' "$KIT/files/scripts/ticket-loop.sh" || fail "오래 기다리는 다섯 곳(PR·CI·수리 idle·병합 뒤 검증·워크트리 준비)이 bg_wait 를 쓰지 않음"
! grep -q 'pr="$(wait_for_pr' "$KIT/files/scripts/ticket-loop.sh" || fail "wait_for_pr 를 다시 커맨드 치환(포그라운드)으로 부른다"
# 본 스크립트의 연결: 사용자 설정 파일을 저장소 loop.env 보다 먼저 읽고, trap 은 잠금 전에, LOCK_HELD 는 잠금을 잡은 뒤, 티켓마다 STOP_ISSUE,
# 병합하면 멈춤 라벨을 뗀다. EXIT trap 은 on_exit 하나뿐
L1="$(grep -n 'source "$USER_LOOP_ENV"' "$KIT/files/scripts/ticket-loop.sh" | cut -d: -f1)"; L2="$(grep -n 'source "$LOOP_ENV"' "$KIT/files/scripts/ticket-loop.sh" | cut -d: -f1)"
[[ -n "$L1" && -n "$L2" && "$L1" -lt "$L2" ]] || fail "사용자 loop.env 를 저장소 loop.env 보다 먼저 읽지 않음"
grep -qF 'USER_LOOP_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/ticket-loop/loop.env"' "$KIT/files/scripts/ticket-loop.sh" || fail "사용자 loop.env 경로가 바뀜"
grep -A3 "trap on_exit EXIT; trap 'on_signal HUP' HUP; trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal PIPE' PIPE" "$KIT/files/scripts/ticket-loop.sh" | grep -A1 'mkdir "$LOCK_DIR"' | grep -q '^  LOCK_HELD=1$' || fail "trap(잠금 전)·LOCK_HELD=1(잠금 뒤) 순서가 아님"
[[ "$(grep -c 'trap .* EXIT' "$KIT/files/scripts/ticket-loop.sh")" == 1 ]] || fail "EXIT trap 이 on_exit 하나가 아님"
grep -q 'STOP_ISSUE="$n"$' "$KIT/files/scripts/ticket-loop.sh" && grep -qF -- '--remove-label "$STOPPED_LABEL"' "$KIT/files/scripts/ticket-loop.sh" || fail "run_ticket 이 STOP_ISSUE 를 두거나 병합 뒤 멈춤 라벨을 떼지 않음"
echo "ok  알림·멈춤 보고(Slack·GitHub 기록, die·set -e·신호, 긴 대기 중 신호, 잠금)"

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
                     {"number":43,"title":"T03: 셋","state":"closed","url":"https://x/43","assignees":0},
                     {"number":44,"title":"T04: 넷","state":"closed","url":"https://x/44","assignees":0},
                     {"number":4,"title":"T05: 다섯","state":"open","url":"https://x/4","assignees":0}]' \
  --argjson prs '[{"number":50,"title":"T01 PR","body":"- [x] a\n- [ ] b","state":"MERGED","url":"https://x/p50","createdAt":"2026-10-12T00:00:00Z","mergedAt":"2026-10-12T00:30:00Z","headRefName":"issue-41-one"},
                  {"number":51,"title":"T03 PR","body":"","state":"MERGED","url":"https://x/p51","createdAt":"2026-10-11T00:00:00Z","mergedAt":"2026-10-11T01:00:00Z","headRefName":"issue-43-three"},
                  {"number":52,"title":"T04 PR","body":"","state":"MERGED","url":"https://x/p52","createdAt":"2026-10-11T02:00:00Z","mergedAt":"2026-10-11T03:00:00Z","headRefName":"issue-44"}]' \
  --argjson recs '[{"spec":40,"issue":41,"title":"T01: 하나","result":"merged","started":"2026-10-12T00:00:00Z","finished":"2026-10-12T00:31:00Z","wall_sec":1860,"repairs":1,"idle_false_positives":0,"agent":"claude","pr":50,"ci_sec":200,"post_merge":"통과 90초","model":"Opus 5.5"},
                   {"spec":40,"issue":42,"title":"T02: 둘","result":"stopped","reason":"워커가 PR 없이 멈췄습니다","started":"2026-10-12T01:00:00Z","finished":"2026-10-12T01:10:00Z","wall_sec":600,"repairs":0,"idle_false_positives":2,"agent":"claude"},
                   {"spec":40,"issue":43,"title":"T03: 셋","result":"merged","started":"2026-10-11T00:00:00Z","finished":"2026-10-11T01:01:00Z","wall_sec":3660,"repairs":0,"idle_false_positives":0,"agent":"claude","pr":51,"ci_sec":100,"post_merge":"failed in 12s","model":"Opus 5.5"}]' \
  "$REPORT_JQ" > "$T/report.html" || fail "스펙 리포트 jq 실패"
for want in '<!doctype html>' '<html lang="en">' 'PR #50' 'Acceptance criteria 1/2' '>Merged<' '>Stopped<' 'Stop reason: 워커가 PR 없이 멈췄습니다' 'Opus 5.5' 'PR created→merged' 'not recorded' '1 repair ·' 'post-merge check passed in 90s' 'post-merge check failed in 12s' 'T01: 하나'; do
  grep -qF "$want" "$T/report.html" || fail "스펙 리포트에 '$want' 없음"
done
# head 가 정확히 issue-44 인 PR #52 는 T04 의 PR 이고(Merged 3건), 이슈 4 에는 붙지 않는다(기록도 PR 도 없는 이슈 4 는 Not started)
[[ "$(grep -o 'PR #52' "$T/report.html" | wc -l | tr -d ' ')" == "1" ]] || fail "스펙 리포트: head 가 issue-44 인 PR #52 가 한 번 나와야 함"
[[ "$(grep -o 'badge ok">Merged<' "$T/report.html" | wc -l | tr -d ' ')" == "3" ]] || fail "스펙 리포트: Merged 배지가 3건(41·43·44)이어야 함"
grep -qF '<div class="v">3</div><div class="l">Merged</div>' "$T/report.html" || fail "스펙 리포트: KPI Merged 가 3 이어야 함"
[[ "$(grep -o 'badge muted">Not started<' "$T/report.html" | wc -l | tr -d ' ')" == "1" ]] || fail "스펙 리포트: 이슈 4 가 Not started 여야 함(issue-44 PR 이 #4 에 붙음?)"
echo "ok  스펙 리포트 렌더(head 가 issue-N 그대로인 PR 포함)"

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
