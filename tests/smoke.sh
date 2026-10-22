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
for sk in setup-ticket-loop loop-triage implement pr; do
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
grep -qxF '/.ticket-loop/stops/' "$T/.gitignore" || fail ".gitignore 에 멈춤 기록(/.ticket-loop/stops/) 줄 없음"
grep -q 'allow_implicit_invocation: false' "$T/.agents/skills/loop-triage/agents/openai.yaml" && grep -q '^disable-model-invocation: true$' "$T/.agents/skills/loop-triage/SKILL.md" \
  || fail "loop-triage 스킬이 명시 호출 전용이 아님"
jq -e '.managed | index(".agents/skills/loop-triage/SKILL.md")' "$T/.ticket-loop/kit.json" >/dev/null || fail "kit.json managed 에 loop-triage 스킬이 없음"
echo "ok  첫 설치"

# #5: 설치본에서 `__[A-Z_]*__`에 걸리는 줄은 사용자가 채울 자리표뿐이어야 한다. setup-ticket-loop 스킬의 자리표 표에 적힌 이름을
# 모두 임의 값으로 채운 뒤 그 스킬 5절의 검사를 그대로 돌려 결과가 비어야 한다(주석 속 __PLACEHOLDERS__ 같은 낱말이 들어오면 여기서 걸린다)
F="$T/filled"; rm -rf "$F"; mkdir -p "$F/.agents/skills"
cp -R "$T/.agents/skills/implement" "$T/.agents/skills/pr" "$F/.agents/skills/"; cp -R "$T/.ticket-loop" "$T/.codex" "$F/"
names="$(grep -o '^| `__[A-Z_]*__` |' "$KIT/files/.agents/skills/setup-ticket-loop/SKILL.md" | grep -o '__[A-Z_]*__')"
[[ "$(wc -l <<<"$names")" -ge 8 ]] || fail "setup-ticket-loop 스킬의 자리표 표를 읽지 못함: $names"
while IFS= read -r n; do find "$F" -type f -exec sed -i.bak "s/$n/filled/g" {} +; done <<<"$names"
find "$F" -name '*.bak' -delete
left="$(cd "$F" && grep -rn '__[A-Z_]*__' .agents/skills/implement .agents/skills/pr .ticket-loop .codex || true)"
[[ -z "$left" ]] || fail "자리표를 다 채워도 5절 검사에 남는 줄: $left"
echo "ok  자리표를 채운 설치본에서 setup-ticket-loop 5절 검사가 빈다"

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
AGENT_RESTART_CMD="claude --dangerously-skip-permissions"; TERMINAL_RETRY=1; TERMINAL_RETRY_SEC=0; IDLE_POLL_SEC=0; SEND_ACCEPT_SEC=15; WORKTREE_DIR=""; WORKTREE_SETUP_CMD=""
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
# 화면도 못 읽음 → 3(닿지 못함). 2026-10-14 rental-portal #100 에서 빈 값 5번(25초)으로 일하던 워커를 두고 루프가 죽은 오판을 고정한다.
# send 의 다섯 경우 — 붙여 넣은 뒤 lifecycle 이 직전 턴의 idle 에서 running 으로 → 0, 끝까지 idle 이고 화면도 그대로 → 비0, 끝까지 idle 이지만
# 프롬프트가 화면에 찍힘 → 0, lifecycle 빈 값 → 0, paste 거부 → 비0. 2026-10-20 rental-portal #251 에서 붙여 넣은 직후의 묵은 idle 을
# 수리 끝으로 읽어 5초 만에 멈춘 것을 고정한다
cat > "$F/cmux" <<'SH'
#!/bin/bash
case "$1" in
  rpc)
    lc="${FAKE_LC:-idle}"
    if [[ -n "${FAKE_LC_FILE:-}" ]]; then   # 부를 때마다 한 줄씩, 마지막 줄은 이어진다
      lc="$(head -n 1 "$FAKE_LC_FILE")"
      if [[ "$(wc -l < "$FAKE_LC_FILE")" -gt 1 ]]; then tail -n +2 "$FAKE_LC_FILE" > "$FAKE_LC_FILE.n"; mv "$FAKE_LC_FILE.n" "$FAKE_LC_FILE"; fi
    fi
    [[ "$lc" == none ]] || echo "{\"lifecycle\":\"$lc\"}" ;;
  read-screen)
    if [[ "${FAKE_SCREEN:-ok}" != ok ]]; then echo "Error: not_found: Workspace not found" >&2; exit 1; fi
    if [[ -n "${FAKE_SCREEN_FILE:-}" ]]; then cat "$FAKE_SCREEN_FILE"; else echo "[Opus 5.5 | Max]"; fi ;;
  paste)   # FAKE_PASTE_SHOWS=1 이면 붙여 넣은 줄이 화면에 찍힌다
    [[ "${FAKE_PASTE_SHOWS:-0}" != 1 ]] || echo "> ${*: -1}" >> "$FAKE_SCREEN_FILE"
    exit "${FAKE_PASTE_RC:-0}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$F/cmux"
cat > "$F/run-cmux.sh" <<'SH'
set -euo pipefail
BACKEND=cmux; ORCA_CLI=orca; CMUX_CLI=cmux; TMUX_CLI=tmux; TMUX_SESSION=""; OWNER_REPO=o/r; ROOT=/tmp; MAIN_WT=/tmp; BASE_BRANCH=main; BRANCH_PREFIX=issue-; AGENT=claude; SKILL_PREFIX=/
AGENT_RESTART_CMD=claude; TERMINAL_RETRY=2; TERMINAL_RETRY_SEC=0; IDLE_POLL_SEC=0; SEND_ACCEPT_SEC=2; WORKTREE_DIR=""; WORKTREE_SETUP_CMD=""
LOGGED=""; log() { LOGGED+="$*"$'\n'; }; die() { echo "die: $*" >&2; exit 1; }
source "$1"
export FAKE_SCREEN_FILE="$PWD/screen" FAKE_LC_FILE="$PWD/lc"
send_case() {   # $1 lifecycle 차례(줄마다 한 번), $2 FAKE_PASTE_SHOWS, $3 FAKE_PASTE_RC → "종료 코드|남은 lifecycle 첫 줄"
  local rc=0; printf '%s\n' $1 > "$FAKE_LC_FILE"; echo "[Opus 5.5 | Max]" > "$FAKE_SCREEN_FILE"
  FAKE_PASTE_SHOWS="$2" FAKE_PASTE_RC="$3" cmux_send s1 "고쳐라" || rc=$?
  echo "$rc|$(head -n 1 "$FAKE_LC_FILE")"
}
[[ "$(send_case "idle idle running idle" 0 0)" == "0|idle" ]] || die "send: idle → running 에서 수락으로 돌아오지 않음(또는 running 을 지나쳐 더 읽음): $(send_case "idle idle running idle" 0 0)"
[[ "$(send_case idle 0 0)" == 1\|* ]] || die "send: 끝까지 idle·화면 그대로인데 수락으로 봄(묵은 idle, #251)"
[[ "$(send_case idle 1 0)" == 0\|* ]] || die "send: 끝까지 idle 이지만 프롬프트가 화면에 찍혔는데 비0"
[[ "$(send_case "none idle" 0 0)" == "0|idle" ]] || die "send: lifecycle 빈 값인데 기다림: $(send_case "none idle" 0 0)"
[[ "$(send_case running 0 1)" == 1\|* ]] || die "send: paste 가 거부됐는데 0"
unset FAKE_SCREEN_FILE FAKE_LC_FILE
export FAKE_LC=idle FAKE_SCREEN=ok; cmux_wait_idle s1 1000 || die "idle 인데 wait_idle 이 0 이 아님"
export FAKE_LC=none FAKE_SCREEN=ok; rc=0; cmux_wait_idle s1 0 || rc=$?; [[ $rc -eq 1 ]] || die "lifecycle 빈 값·화면 읽힘인데 1(계속 기다림)이 아님: $rc"
[[ "$LOGGED" == *"keep waiting"* ]] || die "화면이 읽히는데 안내 로그가 없다"
export FAKE_LC=none FAKE_SCREEN=gone; rc=0; cmux_wait_idle s1 60000 || rc=$?; [[ $rc -eq 3 ]] || die "lifecycle 빈 값·화면도 못 읽는데 3 이 아님: $rc"
echo ok
SH
(cd "$F" && PATH="$F:$PATH" bash run-cmux.sh "$F/backend.sh" >/dev/null) || fail "cmux 백엔드 wait_idle·send 가짜 호출 실패"
echo "ok  cmux 백엔드 wait_idle 세 경우, send 다섯 경우"

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
sed -n '/^spec_logs() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$S/fn.sh"
grep -q 'gh issue close' "$S/fn.sh" && grep -q '/retro' "$S/fn.sh" && grep -q '^spec_logs() {' "$S/fn.sh" || fail "close_spec_if_done·suggest_retro·spec_logs 를 찾지 못함"
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
# 멈췄다가 다른 날 이어 간 스펙: 그 스펙 기록이 지나간 로그를 모두 적는다 — 기록의 log(0.9.7부터), log 없는 지난 기록은 loop-*.log 의
# 머리줄(=== #N)로 찾고, 지워진 로그와 다른 스펙의 로그는 빼고, 이번 실행의 로그는 늘 넣는다. 0.9.6까지는 이번 실행의 로그만 적었다
mkdir -p "$S/.ticket-loop"
printf '[2026-12-30 21:07:40] === #41 T01: 하나 ===\n' > "$S/.ticket-loop/loop-1230.log"
printf '[2026-12-31 09:00:00] === #39 다른 스펙 ===\n' > "$S/.ticket-loop/loop-1231.log"
printf 'x\n' > "$S/.ticket-loop/loop-1229.log"
printf '%s\n' '{"spec":40,"issue":41,"result":"merged"}' 'not json' "{\"spec\":40,\"issue\":42,\"result\":\"stopped\",\"log\":\"$S/.ticket-loop/loop-1229.log\"}" \
  '{"spec":39,"issue":39,"result":"merged","log":".ticket-loop/loop-1231.log"}' '{"spec":40,"issue":43,"result":"merged","log":".ticket-loop/loop-gone.log"}' \
  '{"spec":40,"issue":44,"result":"merged","log":".ticket-loop/loop-1229.log"}' > "$S/recs.jsonl"   # 41 은 log 없는 지난 기록(머리줄로 loop-1230), 42·44 는 절대·상대 경로가 같은 파일
out="$(cd "$S" && CLOSED_SPECS=" 40" REPORT_DIR=reports ROOT="$S" LOG_FILE=".ticket-loop/loop-0101.log" RECORDS_FILE="$S/recs.jsonl" bash -c 'set -euo pipefail; log() { echo "$*"; }; source fn.sh; suggest_retro')" || fail "suggest_retro(여러 로그) 실패"
grep -qF 'material to read: logs .ticket-loop/loop-1230.log, .ticket-loop/loop-1229.log, .ticket-loop/loop-0101.log, report reports/spec-40.html' <<<"$out" \
  || fail "이어 간 스펙의 회고 안내가 지난 실행의 로그를 다 적지 않음: $out"
out="$(cd "$S" && CLOSED_SPECS=" 40" REPORT_DIR=reports ROOT="$S" LOG_FILE=/dev/null RECORDS_FILE="$S/recs.jsonl" bash -c 'set -euo pipefail; log() { echo "$*"; }; source fn.sh; suggest_retro')" || fail "suggest_retro(로그 끔) 실패"
grep -qF 'material to read: log (none — logging is off), report' <<<"$out" || fail "로그를 끈 실행의 회고 안내가 다름: $out"
echo "ok  회고 안내(이어 간 스펙은 지난 실행의 로그까지)"

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

# 키트 머리줄: 실행 맨 앞 "━━ ticket-loop-kit <버전> (<커밋 7자>) ━━…"(56칸, 앞에 빈 줄). 버전은 설치기가 쓴 kit.json, 없거나 못 읽으면 unknown.
# 색을 켜면 C_BANNER(256색 주황)로 감싸고, 끄면 맨글자. 메인의 첫 출력이고 Slack 시작 알림에도 버전이 붙는다
out="$(logc 'kit_banner "ticket-loop-kit 1.2.3 (abc1234)"')" || fail "kit_banner 실패"
[[ "$out" == $'\n'"━━ ticket-loop-kit 1.2.3 (abc1234) ━━━━━━━━━━━━━━━━━━━━━" ]] || fail "머리줄(색 없음)이 다르다: $out"
out="$(logc "kit_banner \"ticket-loop-kit $(printf 'x%.0s' {1..60})\"")" || fail "긴 머리줄 실패"
[[ "$out" == *"x ━━━" ]] || fail "머리줄이 폭을 넘으면 꼬리 ━ 세 개를 남겨야 한다: $out"
out="$(logc "$paint"'C_BANNER=b; kit_banner "ticket-loop-kit 1.2.3"')" || fail "색을 켠 kit_banner 실패"
[[ "$out" == $'\n'"b━━ ticket-loop-kit 1.2.3 ━━━━"*"━<ESC>[0m" ]] || fail "머리줄을 C_BANNER 로 감싸지 않는다: $out"
grep -qF 'C_BANNER=$'"'"'\e[1;38;5;208m'"'"'' "$KIT/files/scripts/ticket-loop.sh" || fail "C_BANNER 가 256색 주황(1;38;5;208)이 아니다"
K="$G/kitver"; mkdir -p "$K/full/.ticket-loop" "$K/nocommit/.ticket-loop" "$K/broken/.ticket-loop" "$K/none"
echo '{"version":"1.2.3","commit":"abcdef0123456789"}' > "$K/full/.ticket-loop/kit.json"
echo '{"version":"1.2.3"}' > "$K/nocommit/.ticket-loop/kit.json"
echo 'not json' > "$K/broken/.ticket-loop/kit.json"
[[ "$(logc "ROOT=$K/full; kit_version")" == "1.2.3 (abcdef0)" ]] || fail "kit_version(버전·커밋): $(logc "ROOT=$K/full; kit_version")"
[[ "$(logc "ROOT=$K/nocommit; kit_version")" == "1.2.3" ]] || fail "kit_version(커밋 없음): $(logc "ROOT=$K/nocommit; kit_version")"
[[ "$(logc "ROOT=$K/broken; kit_version")" == "unknown" && "$(logc "ROOT=$K/none; kit_version")" == "unknown" ]] || fail "kit.json 이 깨졌거나 없으면 unknown 이어야 한다"
[[ "$(logc "ROOT=$T; kit_version")" == "$(cat "$KIT/VERSION") ($(git -C "$KIT" rev-parse HEAD | cut -c1-7))" ]] || fail "install.sh 가 쓴 kit.json 을 읽지 못함: $(logc "ROOT=$T; kit_version")"
grep -A2 '^# ---------- 메인 ----------$' "$KIT/files/scripts/ticket-loop.sh" | tail -n 1 | grep -qx 'KIT_VERSION="$(kit_version)"' \
  && grep -A1 '^kit_banner "ticket-loop-kit ${KIT_VERSION}"$' "$KIT/files/scripts/ticket-loop.sh" | tail -n 1 | grep -qx 'backend_check' \
  || fail "머리줄이 메인의 첫 출력(backend_check 앞)이 아니다"
grep -F 'slack_post "Ticket loop started"' "$KIT/files/scripts/ticket-loop.sh" | grep -qF ' · kit ${KIT_VERSION}' || fail "Slack 시작 알림에 키트 버전이 없다"
echo "ok  키트 머리줄"

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
sed -n '/^PH_NAME=/p; /^phase() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$P/fn.sh"   # 검증 명령이 도는 시간을 센다
grep -q '^abs_path() ' "$P/fn.sh" && grep -q '^bg_wait() ' "$P/fn.sh" && grep -q '^phase() {' "$P/fn.sh" || fail "abs_path·bg_wait·phase 를 찾지 못함"
postmerge_case() {  # $1 POST_MERGE_CMD, $2 LOG_FILE(상대), $3 기대(pass|fail), [$4 POST_MERGE_RETRY_CMD, $5 source 뒤 덧붙일 설정] → 출력(stderr 포함)
  rm -f "$P/repo/.ticket-loop/post-merge-7-retry.log"
  (cd "$P/repo" && POST_MERGE_CMD="$1" LOG_FILE="$2" POST_MERGE_WORKTREE="$P/wt" EXPECT="$3" POST_MERGE_RETRY_CMD="${4:-}" EXTRA="${5:-}" FN="$P/fn.sh" bash -c '
    set -euo pipefail
    ROOT="$(git rev-parse --show-toplevel)"; MAIN_WT="$ROOT"; OWNER_REPO=o/r; BASE_BRANCH=main; POST_MERGE_COPY=""; POST_MERGE_PORT=""; PORT_WAIT_SEC=0
    log() { shift; echo "$*"; }; dim_lines() { local l; while IFS= read -r l; do echo "  $l"; done; }; fmt_epoch() { echo "$1"; }
    post_merge_flaky_record() { echo "FLAKY_RECORD $*"; }   # 알림 블록의 것 — 아래 알림 검사에서 따로 본다
    source "$FN"
    eval "$EXTRA"
    LOG_FILE="$(abs_path "$LOG_FILE")"
    rc=0; run_post_merge 7 || rc=$?
    [[ "$EXPECT" == pass && $rc -eq 0 || "$EXPECT" == fail && $rc -eq 1 ]] || { echo "rc=$rc"; exit 9; }
    echo "POST_MERGE_LOG=$POST_MERGE_LOG"; echo "POST_MERGE_RETRY_LOG=$POST_MERGE_RETRY_LOG"; echo "POST_MERGE_RESULT=$POST_MERGE_RESULT"; echo "PH=${PH_NAME}|${PH_POST}"' 2>&1)
}
out="$(postmerge_case 'echo hello-from-post-merge; exit 1' '.ticket-loop/loop-0101.log' fail)" || fail "run_post_merge(실패) 가 1 로 끝나지 않음: $out"
[[ -f "$P/repo/.ticket-loop/post-merge-7.log" ]] || fail "post-merge 로그가 저장소 루트 쪽 .ticket-loop/ 에 없다 (ls: $(ls -R "$P/wt/.ticket-loop" 2>/dev/null))"
[[ ! -e "$P/wt/.ticket-loop" ]] || fail "post-merge 로그가 검증 워크트리 안에 생겼다(0.8.4 이하의 버그)"
grep -q '^  hello-from-post-merge$' <<<"$out" || fail "실패 꼬리가 비었다: $out"
! grep -q 'No such file' <<<"$out" || fail "꼬리 tail 이 파일을 못 찾았다: $out"
grep -q "post-merge check started ($P/wt, log $P/repo/.ticket-loop/post-merge-7.log)" <<<"$out" || fail "시작 줄의 로그 경로가 실제 위치(절대 경로)가 아니다: $out"
grep -q "^POST_MERGE_LOG=$P/repo/.ticket-loop/post-merge-7.log$" <<<"$out" || fail "POST_MERGE_LOG(die 가 찍는 경로)가 절대 경로가 아니다: $out"
grep -q '^POST_MERGE_RESULT=failed in [0-9]*s$' <<<"$out" && grep -q '^POST_MERGE_RETRY_LOG=$' <<<"$out" || fail "재실행 설정이 없으면 결과는 전처럼 'failed in Ns' 여야 한다: $out"
! grep -q 'retrying\|FLAKY_RECORD' <<<"$out" && [[ ! -e "$P/repo/.ticket-loop/post-merge-7-retry.log" ]] || fail "재실행 설정이 없는데 재실행했다: $out"
out="$(postmerge_case 'exit 0' 'sub/dir/loop.log' pass)" || fail "run_post_merge(통과) 실패: $out"
[[ -f "$P/repo/sub/dir/post-merge-7.log" ]] || fail "LOG_FILE 을 다른 상대 디렉터리로 줘도 저장소 루트 기준이어야 한다"
grep -q 'post-merge check passed in [0-9]*s' <<<"$out" || fail "통과 줄이 없음: $out"
grep -q 'log (${POST_MERGE_LOG})' "$KIT/files/scripts/ticket-loop.sh" || fail "병합 뒤 검증 실패 die 줄에 로그 경로가 없다"
echo "ok  병합 뒤 검증 로그 경로(저장소 루트 기준·실패 꼬리)"

# 병합 뒤 검증 재실행(POST_MERGE_RETRY_CMD): 첫 실행이 실패하면 포트 대기를 다시 지나 같은 워크트리에서 딱 한 번, 첫 실행 로그 경로
# (POST_MERGE_FAILED_LOG)를 받아 돈다. 통과하면 0("passed on retry …")과 플레이크 기록, 실패하면 1. 2026-10-15 rental-portal #106 실측 —
# 44분 통합 테스트에서 병합과 무관한 테스트 하나가 시간 초과로 깨져 루프가 멈췄다
retry_cmd='grep -q "^first-run-output$" "$POST_MERGE_FAILED_LOG" && case "$POST_MERGE_FAILED_LOG" in /*) ;; *) exit 5 ;; esac && echo "retried in $(pwd -P)"'
out="$(postmerge_case 'echo first-run-output; exit 1' '.ticket-loop/loop-0101.log' pass "$retry_cmd")" || fail "재실행 통과인데 0 이 아님: $out"
grep -q '^POST_MERGE_RESULT=passed on retry in [0-9]*s (first run failed in [0-9]*s)$' <<<"$out" || fail "재실행 통과 결과 문자열이 다르다: $out"
[[ -f "$P/repo/.ticket-loop/post-merge-7-retry.log" ]] && grep -q "^POST_MERGE_RETRY_LOG=$P/repo/.ticket-loop/post-merge-7-retry.log$" <<<"$out" || fail "재실행 로그가 첫 실행 로그와 같은 디렉터리의 post-merge-7-retry.log 가 아니다: $out"
grep -qx "retried in $P/wt" "$P/repo/.ticket-loop/post-merge-7-retry.log" || fail "재실행이 검증 워크트리에서 첫 실행 로그(절대 경로)를 읽지 못함: $(cat "$P/repo/.ticket-loop/post-merge-7-retry.log")"
grep -q "^#7: retrying the post-merge check once (log $P/repo/.ticket-loop/post-merge-7-retry.log)$" <<<"$out" && grep -q 'post-merge check passed on retry in .* likely flaky' <<<"$out" || fail "재실행 시작·통과 줄이 없음: $out"
grep -q "^FLAKY_RECORD 7 $P/repo/.ticket-loop/post-merge-7.log $P/repo/.ticket-loop/post-merge-7-retry.log [0-9]* [0-9]*$" <<<"$out" || fail "재실행 통과인데 플레이크 기록을 부르지 않음: $out"
out="$(postmerge_case 'echo first-run-output; exit 1' '.ticket-loop/loop-0101.log' fail 'echo retry-output; exit 1')" || fail "재실행도 실패인데 1 이 아님: $out"
grep -q '^POST_MERGE_RESULT=failed on retry in [0-9]*s (first run failed in [0-9]*s)$' <<<"$out" && grep -q '^  retry-output$' <<<"$out" || fail "재실행 실패 결과·꼬리가 다르다: $out"
! grep -q 'FLAKY_RECORD' <<<"$out" || fail "재실행이 실패했는데 플레이크 기록을 부름: $out"
out="$(postmerge_case 'exit 0' '.ticket-loop/loop-0101.log' pass 'echo should-not-run')" || fail "첫 실행 통과(재실행 설정 있음) 실패: $out"
grep -q '^POST_MERGE_RESULT=passed in [0-9]*s$' <<<"$out" && [[ ! -e "$P/repo/.ticket-loop/post-merge-7-retry.log" ]] || fail "첫 실행이 통과했는데 재실행했다: $out"
# 재실행 전에도 포트 대기를 지난다: 첫 실행이 포트를 쥔 채 끝나면(가짜 port_in_use 가 busy 파일을 본다) PORT_WAIT_SEC=0 에서 재실행 없이 1
rm -f "$P/busy"
out="$(postmerge_case "touch '$P/busy'; exit 1" '.ticket-loop/loop-0101.log' fail 'echo should-not-run' "POST_MERGE_PORT=3999; port_in_use() { echo \"port-check \$1\"; [[ -e '$P/busy' ]]; }")" || fail "재실행 전 포트가 안 비는 경우 1 이 아님: $out"
[[ "$(grep -c '^port-check 3999$' <<<"$out")" -ge 2 ]] && grep -q 'port 3999 did not free up' <<<"$out" && [[ ! -e "$P/repo/.ticket-loop/post-merge-7-retry.log" ]] \
  || fail "재실행 전에 포트 대기를 지나지 않았거나, 포트가 안 비었는데 재실행했다: $out"
grep -q '^POST_MERGE_RETRY_LOG=$' <<<"$out" || fail "재실행을 못 돌렸으면 POST_MERGE_RETRY_LOG 는 비어야 한다(die 가 전 문구를 쓴다): $out"
rm -f "$P/busy"
grep -c '^  wait_post_merge_port "$n" || return 1$' "$KIT/files/scripts/ticket-loop.sh" | grep -qx 2 || fail "포트 대기 함수를 첫 실행·재실행 두 곳에서 부르지 않는다"
# 검증 명령을 돌리기 전에 끝나면(포트가 끝내 안 빔) 결과는 skipped 가 아니라 did not start
out="$(postmerge_case 'echo should-not-run' '.ticket-loop/loop-0101.log' fail '' "POST_MERGE_PORT=3999; port_in_use() { true; }; POST_MERGE_LOG=''; POST_MERGE_RETRY_LOG=''")" || fail "첫 실행 전 포트가 안 비는 경우 1 이 아님: $out"
grep -q '^POST_MERGE_RESULT=did not start$' <<<"$out" || fail "검증 명령 전에 끝났는데 결과가 did not start 가 아님: $out"
# 리포트의 병합 뒤 검증 시간(phase post)은 명령이 도는 동안만 센다 — 포트 대기는 빼고, 재실행은 더한다. 끝나면 단계를 닫는다
grep -q '^PH=|0$' <<<"$out" || fail "검증 명령을 돌리지 않았는데 병합 뒤 검증 시간이 0 이 아님: $out"
out="$(postmerge_case 'sleep 1; exit 1' '.ticket-loop/loop-0101.log' pass 'sleep 1')" || fail "재실행 통과(시간 세기) 실패: $out"
[[ "$(sed -n 's/^PH=|\([0-9]*\)$/\1/p' <<<"$out")" -ge 2 ]] || fail "병합 뒤 검증 시간이 첫 실행과 재실행을 더하지 않거나 단계를 닫지 않음: $out"
[[ "$(sed -n '/^run_post_merge() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" | grep -B1 '^  if bg_wait' | grep -c '^  phase post')" == 2 \
   && "$(sed -n '/^run_post_merge() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" | grep -A1 '^  if bg_wait' | grep -c '^    phase ""$')" == 2 ]] \
  || fail "병합 뒤 검증 명령 두 곳(첫 실행·재실행)을 phase post 로 감싸지 않음(포트 대기는 빼야 한다)"
# 병합 전에 멈춘 티켓의 기록에 post_merge=skipped 가 남지 않게: 티켓 시작 때는 비우고, 병합 뒤 검증을 하지 않기로 할 때만 skipped(0.9.6까지의 버그)
rt="$(sed -n '/^run_ticket() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh")"
merge_at="$(grep -n 'if ! merge_pr "${pr}"; then' <<<"$rt" | cut -d: -f1)"
grep -qxF '  POST_MERGE_RESULT=""; POST_MERGE_LOG=""; POST_MERGE_RETRY_LOG=""' "$KIT/files/scripts/ticket-loop.sh" && ! grep -q 'POST_MERGE_RESULT="skipped"; ' "$KIT/files/scripts/ticket-loop.sh" \
  && [[ -n "$merge_at" && "$(grep -c 'POST_MERGE_RESULT="skipped"' <<<"$rt")" -ge 1 ]] \
  && [[ -z "$(grep -n 'POST_MERGE_RESULT="skipped"' <<<"$rt" | cut -d: -f1 | awk -v m="$merge_at" '$1 < m')" ]] \
  || fail "POST_MERGE_RESULT 를 티켓 시작 때 skipped 로 채운다(병합 전 멈춘 기록이 '검증 건너뜀'으로 남음)"
grep -qF 'first run ${POST_MERGE_LOG}, retry ${POST_MERGE_RETRY_LOG}' "$KIT/files/scripts/ticket-loop.sh" && grep -q 'If it looks like a flake, just rerun; otherwise rerun after a fix PR' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "재실행까지 실패한 die 줄에 두 로그 경로·문구가 없다"
grep -qF '${POST_MERGE_RETRY_CMD:+ (retry once on failure: ${POST_MERGE_RETRY_CMD})}' "$KIT/files/scripts/ticket-loop.sh" || fail "시작 줄에 재실행 설정을 보이지 않는다"
echo "ok  병합 뒤 검증 재실행(포트 대기·첫 실행 로그·딱 한 번·결과 문자열)"

# 묶어 돌리는 병합 뒤 검증(POST_MERGE_EVERY): 창(아직 검증하지 않은 병합)의 저장·읽기, 언제 돌릴지(pm_due), 묶음 검증의 결과 문자열과
# 창 닫기, 묶음이 재실행까지 실패하면 실패한 테스트만 다시 돌리는 명령으로 처음 실패하는 병합을 이분 탐색, 멈춤 사유, 루프 끝의 검증.
# 실제 git 저장소(origin 역할 bare + 메인 체크아웃)에 병합 커밋 넷(#11~#14)을 쌓고 셋째(#13)가 테스트를 깨뜨린다(broken 파일)
W="$(cd "$T" && pwd -P)/pmwin"; mkdir -p "$W"
git -C "$W" init -q --bare origin.git
git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
pmw_commit() { [[ -z "${2:-}" ]] || touch "$W/repo/$2"; git -C "$W/repo" add -A; git -C "$W/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git -C "$W/repo" rev-parse HEAD; }
C0="$(pmw_commit init)"; C1="$(pmw_commit 'merge #11' a)"; C2="$(pmw_commit 'merge #12' b)"; C3="$(pmw_commit 'merge #13' broken)"; C4="$(pmw_commit 'merge #14' c)"
git -C "$W/repo" push -q origin HEAD:main 2>/dev/null; git -C "$W/repo" fetch -q origin
sed -n '/^# ---------- 병합 뒤 검증 ----------/,/^# ---------- 티켓 기록 · 스펙 리포트 ----------/p' "$KIT/files/scripts/ticket-loop.sh" > "$W/fn.sh"
sed -n '/^abs_path() /p; /^bg_wait() {/,/^}/p; /^PH_NAME=/p; /^phase() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$W/fn.sh"
for f in pm_count pm_list pm_cover pm_of pm_save pm_load pm_add pm_passed pm_due pm_probe pm_describe pm_bisect pm_window_json post_merge_recover pm_flush_end; do
  grep -q "^${f}() {" "$W/fn.sh" || fail "병합 뒤 검증 절에 ${f} 가 없음"
done
WIN4="$(printf '11\t21\t%s\n12\t22\t%s\n13\t23\t%s\n14\t24\t%s' "$C1" "$C2" "$C3" "$C4")"
# $1 실행할 bash 문장들(창·설정·호출) → 출력(stderr 포함). 함수 로그는 단계 이름 없이도 찍힌다
pmw() {
  rm -rf "$W/repo/.ticket-loop" "$W/state.json"
  (cd "$W/repo" && FN="$W/fn.sh" W="$W" BODY="$1" bash -c '
    set -euo pipefail
    ROOT="$(git rev-parse --show-toplevel)"; MAIN_WT="$ROOT"; OWNER_REPO=o/r; BASE_BRANCH=main; POST_MERGE_COPY=""; POST_MERGE_PORT=""; PORT_WAIT_SEC=0
    POST_MERGE_CMD="exit 0"; POST_MERGE_RETRY_CMD=""; POST_MERGE_WORKTREE="$W/wt"; POST_MERGE=1; POST_MERGE_EVERY=4
    TICKETS=(); MAX=0; done_count=0; PROCESSED=""; CLOSED_SPECS=""
    log() { case "${1:-}" in title|step|ok|warn|err) [[ $# -lt 2 ]] || shift ;; esac; echo "$*"; }
    dim_lines() { local l; while IFS= read -r l; do echo "  $l"; done; }; fmt_epoch() { echo "$1"; }
    post_merge_flaky_record() { echo "FLAKY_RECORD $1"; }; die() { echo "DIE $*"; exit 7; }
    pick_targets() { echo "PICK" >&2; printf "%b" "${PICK:-}"; }
    source "$FN"
    PM_STATE_FILE="$W/state.json"; LOG_FILE="$(abs_path .ticket-loop/loop-0101.log)"
    eval "$BODY"' 2>&1)
}
s7() { printf '%s' "${1:0:7}"; }

# 창 저장·읽기: 처음 연 창의 시작은 첫 병합의 부모, 결과 꼬리는 다른 병합이 섞일 때만, 통과하면 창을 닫고 그 커밋이 시작
out="$(pmw "pm_add 11 21 $C1; pm_add 12 22 $C2; pm_add 13 '' ''
  echo \"BASE=\$PM_BASE COUNT=\$(pm_count) LIST=\$(pm_list) COVER11=[\$(pm_cover 11)] COVER13=[\$(pm_cover 13)]\"; jq -c . \"\$PM_STATE_FILE\"
  PM_BASE=x; PM_PENDING=; pm_load; echo \"LOADED=\$PM_BASE|\$(pm_count)|\$(pm_list)\"
  pm_passed $C4; echo \"PASSED=\$PM_BASE|\$(pm_count)\"; jq -c . \"\$PM_STATE_FILE\"
  PM_BASE=; pm_save; [[ ! -e \"\$PM_STATE_FILE\" ]] && echo REMOVED")" || fail "창 저장·읽기 실패: $out"
grep -qxF "BASE=$C0 COUNT=3 LIST=#11 #12 #13 COVER11=[, covering #11 #12 #13] COVER13=[, covering #11 #12 #13]" <<<"$out" \
  && grep -qxF "{\"base\":\"$C0\",\"pending\":[{\"issue\":11,\"pr\":21,\"commit\":\"$C1\"},{\"issue\":12,\"pr\":22,\"commit\":\"$C2\"},{\"issue\":13,\"pr\":null,\"commit\":null}]}" <<<"$out" \
  && grep -qxF "LOADED=$C0|3|#11 #12 #13" <<<"$out" && grep -qxF "PASSED=$C4|0" <<<"$out" && grep -qxF "{\"base\":\"$C4\",\"pending\":[]}" <<<"$out" && grep -qx REMOVED <<<"$out" \
  || fail "창 저장·읽기: $out"
out="$(pmw "pm_add 14 24 $C4; echo \"COVER=[\$(pm_cover 14)]\"")"; grep -qxF 'COVER=[]' <<<"$out" || fail "창에 그 티켓 하나뿐인데 결과 꼬리가 붙음: $out"
# 시작 커밋이 기본 브랜치에 없으면(강제 push) 시작만 버리고 병합은 남긴다. 못 읽는 파일은 무시
out="$(pmw "printf '%s' '{\"base\":\"0123456789012345678901234567890123456789\",\"pending\":[{\"issue\":11,\"pr\":21,\"commit\":\"$C1\"}]}' > \"\$PM_STATE_FILE\"; pm_load; echo \"LOADED=[\$PM_BASE]|\$(pm_list)\"
  echo '{oops' > \"\$PM_STATE_FILE\"; PM_PENDING=; pm_load; echo \"BROKEN=[\$(pm_list)]\"")"
grep -qxF 'LOADED=[]|#11' <<<"$out" && grep -q 'not on origin/main any more' <<<"$out" && grep -qxF 'BROKEN=[]' <<<"$out" && grep -q 'unreadable state' <<<"$out" \
  || fail "창 읽기(기본 브랜치에 없는 시작, 깨진 파일): $out"
echo "ok  묶어 돌리는 검증 — 창 저장·읽기·닫기"

# 언제 돌리나: 창이 POST_MERGE_EVERY개 찼을 때, 스펙이 끝났을 때, 이번 실행의 마지막 티켓(--max, 번호 지정, 자동 선택이면 다음 대상이
# 없을 때). 미룰 때는 미리 계산한 대상을 메인 고리에 넘긴다. 찼으면 다음 대상을 계산하지 않는다
due() { pmw "PM_PENDING=\"\$(printf '%s\n' \"$WIN4\" | awk 'NR <= $1')\"; $2; rc=0; pm_due ${3:-12} ${4:-0} || rc=\$?; echo \"DUE=\$rc WHY=\$PM_WHY SET=\$NEXT_TARGETS_SET\""; }
[[ "$(due 2 'PICK="15\tT05\n"')" == $'PICK\nDUE=1 WHY= SET=1' ]] || fail "pm_due(다음 대상 있음 → 미룸): $(due 2 'PICK="15\tT05\n"')"
[[ "$(due 2 'PICK="12\tT02\n11\tT01\n"; PROCESSED=" 11"')" == $'PICK\nDUE=0 WHY=no more tickets SET=0' ]] || fail "pm_due(남은 대상이 이 티켓·처리한 티켓뿐 → 돌림): $(due 2 'PICK="12\tT02\n11\tT01\n"; PROCESSED=" 11"')"
[[ "$(due 4 'PICK="15\tT05\n"' 14)" == 'DUE=0 WHY=every 4 merged tickets SET=0' ]] || fail "pm_due(창이 참 — 다음 대상 계산 없이): $(due 4 'PICK="15\tT05\n"' 14)"
[[ "$(due 1 'POST_MERGE_EVERY=1')" == 'DUE=0 WHY=every 1 merged ticket SET=0' ]] || fail "pm_due(병합마다): $(due 1 'POST_MERGE_EVERY=1')"
# 0 이면 개수로는 돌리지 않는다 — 스펙 끝·실행의 마지막에만
[[ "$(due 4 'POST_MERGE_EVERY=0; PICK="15\tT05\n"')" == $'PICK\nDUE=1 WHY= SET=1' ]] || fail "pm_due(0 — 창이 차도 미룸): $(due 4 'POST_MERGE_EVERY=0; PICK="15\tT05\n"')"
[[ "$(due 4 'POST_MERGE_EVERY=0; CLOSED_SPECS=" 40"' 12 40)" == 'DUE=0 WHY=spec #40 complete SET=0' && "$(due 4 'POST_MERGE_EVERY=0')" == $'PICK\nDUE=0 WHY=no more tickets SET=0' ]] \
  || fail "pm_due(0 — 스펙 끝·실행의 마지막에는 돌림): $(due 4 'POST_MERGE_EVERY=0; CLOSED_SPECS=" 40"' 12 40) / $(due 4 'POST_MERGE_EVERY=0')"
[[ "$(pmw "PM_PENDING=\"\$(head -n 2 <<<\"$WIN4\")\"; pm_of; echo; POST_MERGE_EVERY=0; pm_of")" == $'2/4\n2' ]] || fail "미룬 병합 수 표시(2/4, 0 이면 2)"
[[ "$(due 2 'CLOSED_SPECS=" 39 40"' 12 40)" == 'DUE=0 WHY=spec #40 complete SET=0' ]] || fail "pm_due(스펙 끝): $(due 2 'CLOSED_SPECS=" 39 40"' 12 40)"
[[ "$(due 2 'MAX=3; done_count=2')" == 'DUE=0 WHY=last ticket of this run SET=0' && "$(due 2 'TICKETS=(11 12 13); done_count=2')" == 'DUE=0 WHY=last ticket of this run SET=0' ]] \
  || fail "pm_due(--max·번호 지정의 마지막): $(due 2 'MAX=3; done_count=2') / $(due 2 'TICKETS=(11 12 13); done_count=2')"
[[ "$(due 2 'TICKETS=(11 12 13); done_count=1')" == 'DUE=1 WHY= SET=0' ]] || fail "pm_due(번호 지정 중간 — 대상을 계산하지 않고 미룸): $(due 2 'TICKETS=(11 12 13); done_count=1')"
[[ "$(due 0 'CLOSED_SPECS=" 40"' 12 40)" == 'DUE=1 WHY= SET=0' ]] || fail "pm_due(창이 비면 돌리지 않음): $(due 0 'CLOSED_SPECS=" 40"' 12 40)"
[[ "$(due 2 'pick_targets() { return 1; }')" == 'DUE=1 WHY= SET=0' ]] || fail "pm_due(다음 대상 조회 실패 → 죽지 않고 미룸): $(due 2 'pick_targets() { return 1; }')"
echo "ok  묶어 돌리는 검증 — 언제 돌리나(창이 참·스펙 끝·실행의 마지막)"

# 묶음 검증: 통과·재실행 통과면 결과에 덮은 병합을 적고 창을 닫는다(시작 = 검증한 커밋)
pmv() { pmw "PM_BASE=$C0; PM_PENDING=\"$WIN4\"; $1; rc=0; run_post_merge 14 || rc=\$?
  echo \"RC=\$rc\"; echo \"RESULT=\$POST_MERGE_RESULT\"; echo \"WIN=\$PM_BASE|\$(pm_count)\"; echo \"HEAD=\$(git -C \"\$W/wt\" rev-parse HEAD)\"; echo \"PH=\$PH_POST\"
  ls .ticket-loop | sed 's/^/FILE /'"; }
out="$(pmv 'POST_MERGE_CMD="exit 0"')"
grep -qE '^RESULT=passed in [0-9]+s, covering #11 #12 #13 #14$' <<<"$out" && grep -qxF "WIN=$C4|0" <<<"$out" && grep -qxF '#14: this check covers the merged tickets #11 #12 #13 #14' <<<"$out" \
  || fail "묶음 검증 통과: $out"
out="$(pmv 'POST_MERGE_CMD="exit 1"; POST_MERGE_RETRY_CMD="exit 0"')"
grep -qE '^RESULT=passed on retry in [0-9]+s \(first run failed in [0-9]+s\), covering #11 #12 #13 #14$' <<<"$out" && grep -qxF "WIN=$C4|0" <<<"$out" && grep -qx 'FLAKY_RECORD 14' <<<"$out" \
  || fail "묶음 검증 재실행 통과: $out"
# 재실행까지 실패하면 이분 탐색: 창의 시작(통과해야 성립)과 #12(통과)·#13(실패)을 다시 돌려 #13 을 찾고, 검증 워크트리는 끝으로 되돌린다.
# 창은 닫지 않는다. 다시 돌린 시간도 병합 뒤 검증 시간에 든다
FULL='echo full; test ! -e broken'; PROBE='test -s "$POST_MERGE_FAILED_LOG" && echo probe && sleep 1 && test ! -e broken'
out="$(pmv "POST_MERGE_CMD='$FULL'; POST_MERGE_RETRY_CMD='$PROBE'")"
grep -qE "^RESULT=failed on retry in [0-9]+s \(first run failed in [0-9]+s\), covering #11 #12 #13 #14; first failing merge: #13 \(PR #23, commit $(s7 "$C3")\)$" <<<"$out" \
  || fail "이분 탐색 결과 문자열: $out"
[[ "$(grep '^FILE post-merge-14-bisect-' <<<"$out" | sort | tr '\n' ' ')" == "$(printf 'FILE post-merge-14-bisect-%s.log\n' "$(s7 "$C0")" "$(s7 "$C2")" "$(s7 "$C3")" | sort | tr '\n' ' ')" ]] \
  || fail "이분 탐색이 시작·#12·#13 만 다시 돌려야 함: $(grep '^FILE' <<<"$out")"
grep -qxF "HEAD=$C4" <<<"$out" && grep -qxF "WIN=$C0|4" <<<"$out" && [[ "$(sed -n 's/^PH=//p' <<<"$out")" -ge 3 ]] \
  && grep -qF "#14: failed tests at $(s7 "$C3") merge #13 — fail" <<<"$out" && grep -qF "#14: failed tests at $(s7 "$C2") merge #12 — pass" <<<"$out" \
  || fail "이분 탐색 뒤 워크트리·창·시간·줄: $out"
# 창의 시작에서도 실패하면 탐색이 성립하지 않는다(플레이크·환경·테스트를 못 고름) — 한 번만 돌리고 그렇게 적는다
out="$(pmv "POST_MERGE_CMD='$FULL'; POST_MERGE_RETRY_CMD='exit 1'")"
grep -qF "; first failing merge not found: the failed tests fail at $(s7 "$C0") (last passed) too" <<<"$out" && [[ "$(grep -c '^FILE post-merge-14-bisect-' <<<"$out")" == 1 ]] \
  || fail "창의 시작에서도 실패하는 이분 탐색: $out"
# 처음 실패하는 커밋이 창의 병합이 아니면(사람이 병합) 커밋과 제목을 적는다
out="$(pmw "PM_BASE=$C0; PM_PENDING=\"\$(grep -v '^13' <<<\"$WIN4\")\"; POST_MERGE_CMD='$FULL'; POST_MERGE_RETRY_CMD='$PROBE'; run_post_merge 14 || true; echo \"RESULT=\$POST_MERGE_RESULT\"")"
grep -qF "; first failing merge: commit $(s7 "$C3") merge #13" <<<"$out" || fail "창 밖 커밋을 찾았을 때: $out"
out="$(pmw "PM_PENDING=\"\$(printf '12\t\t%s' $C2)\"; pm_describe $C2 \"\$W/repo\"")"
[[ "$out" == "#12 (commit $(s7 "$C2"))" ]] || fail "PR 을 모르는 창의 병합(빈 칸): $out"
# 탐색 중 포트가 끝내 안 비면 거기서 그친다
out="$(pmv "POST_MERGE_CMD='$FULL'; POST_MERGE_RETRY_CMD='touch \"\$W/busy\"; exit 1'; POST_MERGE_PORT=3999; rm -f \"\$W/busy\"; port_in_use() { [[ -e \"\$W/busy\" ]]; }; port_holder() { echo x; }")"
grep -qF '; first failing merge not found: port 3999 did not free up' <<<"$out" && ! grep -q '^FILE post-merge-14-bisect-' <<<"$out" || fail "이분 탐색 중 포트: $out"
rm -f "$W/busy"
# 재실행 명령이 없으면 탐색하지 않는다(전체 스위트로는 하지 않는다). 창에 이 티켓 하나면 꼬리도 탐색도 없다
out="$(pmv "POST_MERGE_CMD='$FULL'")"
grep -qE '^RESULT=failed in [0-9]+s, covering #11 #12 #13 #14$' <<<"$out" && ! grep -q '^FILE post-merge-14-bisect-' <<<"$out" || fail "재실행 명령 없는 묶음 실패: $out"
out="$(pmw "PM_BASE=$C3; PM_PENDING=\"\$(grep '^14' <<<\"$WIN4\")\"; POST_MERGE_CMD='$FULL'; POST_MERGE_RETRY_CMD='$PROBE'; run_post_merge 14 || true; echo \"RESULT=\$POST_MERGE_RESULT\"; ls .ticket-loop")"
grep -qE '^RESULT=failed on retry in [0-9]+s \(first run failed in [0-9]+s\)$' <<<"$out" && ! grep -q 'bisect' <<<"$out" || fail "창에 이 티켓 하나뿐인 실패: $out"
# 앞 검증의 탐색 결과가 다음 멈춤 사유에 섞이지 않는다
out="$(pmw "PM_BISECT=stale; PM_FIRST_FAILING=x; PM_PENDING=\"$WIN4\"; run_post_merge 14; echo \"B=[\$PM_BISECT][\$PM_FIRST_FAILING]\"")"
grep -qxF 'B=[][]' <<<"$out" || fail "검증마다 이분 탐색 결과를 비우지 않음: $out"
echo "ok  묶어 돌리는 검증 — 결과·창 닫기·처음 실패하는 병합 찾기(이분 탐색)"

# 멈춤 사유: 묶음과 탐색 결과를 적고, 수습이 고치면 다시 검증해 통과로 이어 간다. 루프 끝에 남은 창을 검증한다. 멈춤 기록에 창을 싣는다
rcv() { pmw "PM_BASE=$C0; PM_PENDING=\"$WIN4\"; POST_MERGE_LOG=/l/pm-14.log; POST_MERGE_RETRY_LOG=/l/pm-14-retry.log; POST_MERGE_RESULT=first; $1; rc=0; post_merge_recover 14 || rc=\$?; echo \"RC=\$rc\"; echo \"REASON=\$PM_REASON\"; echo \"RESULT=\$POST_MERGE_RESULT\""; }
out="$(rcv 'PM_BISECT="first failing merge: #13 (PR #23, commit abc1234)"; triage() { echo "TRIAGE $1"; TRIAGE_NOTE=" (no triage: t)"; return 1; }')"
grep -qxF 'REASON=#14: post-merge check failed on the merged main (merges checked together: #11 #12 #13 #14 — first failing merge: #13 (PR #23, commit abc1234)), and again on retry. Check the logs (first run /l/pm-14.log, retry /l/pm-14-retry.log) and the check worktree ('"$W"'/wt). If it looks like a flake, just rerun; otherwise rerun after a fix PR. (no triage: t)' <<<"$out" \
  && grep -qx 'RC=1' <<<"$out" && grep -qx 'TRIAGE post_merge_failed' <<<"$out" || fail "묶음 실패의 멈춤 사유: $out"
out="$(rcv 'PM_PENDING="$(grep "^14" <<<"$PM_PENDING")"; POST_MERGE_RETRY_LOG=; triage() { TRIAGE_NOTE=""; return 1; }')"
grep -qxF 'REASON=#14: post-merge check failed on the merged main. Check the log (/l/pm-14.log) and the check worktree ('"$W"'/wt), then rerun after a fix PR.' <<<"$out" || fail "한 티켓 창의 멈춤 사유가 전과 다름: $out"
out="$(rcv 'triage() { TRIAGE_FIX_PR=99; return 0; }')"
grep -qx 'RC=0' <<<"$out" && grep -qE '^RESULT=first; after triage \(fix PR #99\): passed in [0-9]+s, covering #11 #12 #13 #14$' <<<"$out" || fail "수습 뒤 다시 검증: $out"
out="$(pmw "PM_BASE=$C0; PM_PENDING=\"\$(head -n 2 <<<\"$WIN4\")\"; CUR_PR=99; CUR_STARTED=5; WT_PATH=/old; issue_title() { echo \"제목 \$1\"; }; pm_flush_end; echo \"AFTER=\$(pm_count)|[\$STOP_ISSUE]|\$CUR_PR|\$CUR_TITLE|[\$CUR_STARTED][\$WT_PATH]\"; ls .ticket-loop 2>&1")" || true
grep -qE '^post-merge check at the end of the run: passed in [0-9]+s, covering #11 #12$' <<<"$out" && grep -qxF 'AFTER=0|[]|22|제목 12|[][]' <<<"$out" && grep -qx 'post-merge-12-end.log' <<<"$out" \
  && grep -qxF 'post-merge check for the merged tickets not checked yet (#11 #12)' <<<"$out" || fail "루프 끝에 남은 창 검증: $out"
out="$(pmw "PM_PENDING=\"$WIN4\"; POST_MERGE_CMD='exit 1'; post_merge_recover() { PM_REASON=\"why \$1\"; return 1; }; pm_flush_end")" || true
grep -qx 'DIE why 14' <<<"$out" || fail "루프 끝 검증이 실패하면 창의 마지막 티켓으로 멈춰야 함: $out"
[[ "$(pmw "PM_PENDING=\"$WIN4\"; POST_MERGE=0; pm_flush_end; echo DONE")" == DONE && "$(pmw 'pm_flush_end; echo DONE')" == DONE ]] || fail "검증이 꺼졌거나 창이 비면 루프 끝 검증을 하지 않아야 함"
out="$(pmw "PM_BASE=$C0; PM_PENDING=\"\$(head -n 2 <<<\"$WIN4\")\"; PM_BISECT=b; PM_FIRST_FAILING=$C2; pm_window_json; PM_PENDING=; pm_window_json")"
[[ "$out" == "{\"base\":\"$C0\",\"first_failing_commit\":\"$C2\",\"bisect\":\"b\",\"pending\":[{\"issue\":11,\"pr\":21,\"commit\":\"$C1\"},{\"issue\":12,\"pr\":22,\"commit\":\"$C2\"}]}"$'\n'null ]] || fail "멈춤 기록의 창: $out"
grep -qF 'post_merge_worktree: ($pm_wt | str), post_merge_window: $pm_window,' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -qF -- '- 아직 병합 뒤 검증을 통과하지 않은 병합: $(pm_list)' "$KIT/files/scripts/ticket-loop.sh" || fail "멈춤 기록·GitHub 기록에 창이 없음"
# 리포트: 미룬 티켓은 "deferred", 묶음을 돌린 티켓은 덮은 병합을 적고 그 시간은 그 티켓에만 든다
RJQ="$(sed -n "/^read -r -d '' REPORT_JQ <<'JQ'/,/^JQ\$/p" "$KIT/files/scripts/ticket-loop.sh" | sed '1d;$d')"
jq -rn --arg prefix issue- --arg now "2026-10-21 09:00" --argjson spec '{"number":60,"title":"스펙","state":"CLOSED","url":"https://x/60"}' \
  --argjson issues '[{"number":61,"title":"T01: 하나","state":"closed","url":"https://x/61","assignees":0},{"number":62,"title":"T02: 둘","state":"closed","url":"https://x/62","assignees":0}]' \
  --argjson prs '[{"number":71,"title":"P1","body":"","state":"MERGED","url":"https://x/p71","createdAt":"2026-10-21T00:30:00Z","mergedAt":"2026-10-21T00:40:00Z","headRefName":"issue-61-a"},
                  {"number":72,"title":"P2","body":"","state":"MERGED","url":"https://x/p72","createdAt":"2026-10-21T01:30:00Z","mergedAt":"2026-10-21T01:40:00Z","headRefName":"issue-62-b"}]' \
  --argjson recs '[{"spec":60,"issue":61,"title":"T01: 하나","result":"merged","started":"2026-10-21T00:00:00Z","finished":"2026-10-21T00:41:00Z","wall_sec":2460,"impl_sec":1800,"repair_sec":0,"ci_wait_sec":600,"post_merge_sec":0,"repairs":0,"agent":"claude","pr":71,"ci_sec":500,"post_merge":"deferred (1/2 pending)","model":"Opus 5.5"},
                   {"spec":60,"issue":62,"title":"T02: 둘","result":"merged","started":"2026-10-21T01:00:00Z","finished":"2026-10-21T02:31:00Z","wall_sec":5460,"impl_sec":1800,"repair_sec":0,"ci_wait_sec":600,"post_merge_sec":3000,"repairs":0,"agent":"claude","pr":72,"ci_sec":500,"post_merge":"passed in 3000s, covering #61 #62","model":"Opus 5.5"}]' \
  "$RJQ" > "$W/report.html" || fail "묶음 리포트 jq 실패"
grep -F 'https://x/61"' "$W/report.html" | grep -qF '0 repairs · post-merge check deferred (1/2 pending)</div></td><td class="nw">30m</td><td class="nw">10m</td><td class="nw">—</td>' \
  && grep -F 'https://x/62"' "$W/report.html" | grep -qF '0 repairs · post-merge check passed, covering #61 #62</div></td><td class="nw">30m</td><td class="nw">10m</td><td class="nw">50m</td>' \
  && grep -qF '<div class="v">50m</div><div class="l"><span class="dot s-post"></span>Post-merge check</div>' "$W/report.html" && grep -qF 'say "post-merge check deferred"' "$W/report.html" \
  || fail "묶음 리포트: $(grep -F 'https://x/6' "$W/report.html")"
echo "ok  묶어 돌리는 검증 — 멈춤 사유·수습 뒤 검증·루프 끝 검증·멈춤 기록"

# 연결: 병합 뒤 창에 넣고(CI 없는 PR 은 빼고) pm_due 로 정한다. 실패 뒤처리는 post_merge_recover. 시작 때 창을 읽고, 끝날 때(대상 없음 포함)
# 남은 창을 검증한 뒤 스펙을 닫는다. 미룰 때 계산한 대상은 메인 고리가 쓴다. 값 검사
rt="$(sed -n '/^run_ticket() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh")"
[[ "$(grep -n 'if ! merge_pr "${pr}"; then' <<<"$rt" | cut -d: -f1)" -lt "$(grep -n 'pm_add "${n}" "${pr}"' <<<"$rt" | cut -d: -f1)" ]] \
  && grep -B2 'pm_add "${n}" "${pr}"' <<<"$rt" | grep -qF 'if [[ $ci_sec -ge 0 ]]; then' \
  && grep -A1 'if pm_due "${n}" "$spec"; then' <<<"$rt" | grep -qxF '      run_post_merge "${n}" || post_rc=$?' \
  && grep -qF 'POST_MERGE_RESULT="deferred ($(pm_of) pending)"' <<<"$rt" \
  && grep -qxF '    post_rc=0; post_merge_recover "${n}" || post_rc=$?' <<<"$rt" && grep -qxF '  close_spec_if_done "$spec"' <<<"$rt" \
  || fail "run_ticket 의 묶어 돌리는 검증 연결"
grep -A3 '^backend_check$' "$KIT/files/scripts/ticket-loop.sh" | sed -n 2p | grep -qx 'pm_load' \
  && grep -qF '{ pm_flush_end; close_spec_if_done "$PARENT"; write_spec_report; suggest_retro; }' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -B1 '^close_spec_if_done "$PARENT"$' "$KIT/files/scripts/ticket-loop.sh" | head -n1 | grep -qx 'pm_flush_end' \
  && grep -qF 'if [[ $NEXT_TARGETS_SET -eq 1 ]]; then targets="$NEXT_TARGETS"; NEXT_TARGETS_SET=0' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "메인의 창 읽기·끝 검증·미리 계산한 대상"
everyc() { sed -n '/^\[\[ "$POST_MERGE_EVERY" =~/p' "$KIT/files/scripts/ticket-loop.sh" | POST_MERGE_EVERY="$1" bash 2>&1; }
[[ -z "$(everyc 4)" && -z "$(everyc 12)" && -z "$(everyc 0)" && -z "$(everyc 1)" ]] && grep -q 'must be 0 or a positive integer' <<<"$(everyc -1)" \
  && grep -q "got 'x'" <<<"$(everyc x)" && grep -q "got ''" <<<"$(everyc '')" && grep -q "got '04'" <<<"$(everyc 04)" \
  || fail "POST_MERGE_EVERY 값 검사: [$(everyc 4)] [$(everyc 0)] [$(everyc -1)]"
(cd "$T" && POST_MERGE_EVERY=-1 bash scripts/ticket-loop.sh --dry-run >/dev/null 2>&1) && fail "POST_MERGE_EVERY=-1 인데 실행됨" || [[ $? -eq 2 ]] || fail "POST_MERGE_EVERY=-1 종료 코드가 2 가 아님"
grep -qxF 'POST_MERGE_EVERY="${POST_MERGE_EVERY:-4}"' "$KIT/files/scripts/ticket-loop.sh" || fail "POST_MERGE_EVERY 기본값이 4 가 아님"
startc() { sed -n '/^log "post-merge check: /p' "$KIT/files/scripts/ticket-loop.sh" | POST_MERGE=1 POST_MERGE_CMD=c POST_MERGE_RETRY_CMD= POST_MERGE_EVERY="$1" bash -c 'log() { echo "$*"; }; eval "$(cat)"'; }
[[ "$(startc 1)" == 'post-merge check: on — c' && "$(startc 0)" == 'post-merge check: on, when a spec or the run ends — c' \
   && "$(startc 4)" == 'post-merge check: on, every 4 merged tickets and when a spec or the run ends — c' ]] || fail "시작 줄의 검증 주기: [$(startc 1)] [$(startc 0)] [$(startc 4)]"
echo "ok  묶어 돌리는 검증 — 연결·값 검사"
grep -q 'LOG_START_BYTES=$(( $(wc -c < "$LOG_FILE") ))' "$KIT/files/scripts/ticket-loop.sh" || fail "시작 때 로그 파일 크기(LOG_START_BYTES)를 기억하지 않음"
grep -q '^LOG_FILE="$(abs_path "$LOG_FILE")"$' "$KIT/files/scripts/ticket-loop.sh" && grep -q '^RECORDS_FILE="$(abs_path "$RECORDS_FILE")"$' "$KIT/files/scripts/ticket-loop.sh" && grep -q '^REPORT_DIR="$(abs_path "$REPORT_DIR")"$' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "LOG_FILE·RECORDS_FILE·REPORT_DIR 를 시작 때 절대 경로로 굳히지 않는다"
[[ "$(cd "$P/repo" && ROOT="$P/repo" FN="$P/fn.sh" bash -c 'source "$FN"; abs_path /dev/null; echo; abs_path /abs/x; echo; abs_path rel/y')" == $'/dev/null\n/abs/x\n'"$P/repo/rel/y" ]] || fail "abs_path 가 /dev/null·절대 경로를 그대로 두고 상대 경로만 ROOT 에 붙이지 않는다"

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
  rm -rf "$M/calls.jsonl" "$M/rec" "$M/lock" "$M/.ticket-loop"; : > "$M/calls.jsonl"
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
rc="$(stop_case ok 'post_merge_flaky_record 12 /secret/dir/.ticket-loop/post-merge-12.log /secret/dir/.ticket-loop/post-merge-12-retry.log 2640 300')"
[[ "$rc" == 0 && ! -e "$M/rec" ]] || fail "플레이크 기록이 멈춤으로 처리됨(rc $rc)"
[[ "$(jq -rs '[.[] | select(.cmd == "gh") | .args[0:2] | join(" ")] | join(",")' "$M/calls.jsonl")" == "issue comment" ]] || fail "플레이크 기록은 코멘트 하나뿐이어야 한다(라벨 없음): $(jq -c . "$M/calls.jsonl")"
out="$(gh_comment)"
for want in $'12\n**ticket-loop 병합 뒤 검증 재시도 통과** — 플레이크 의심' '첫 실행 2640초 만에 실패' '300초 만에 통과' '- PR #34 병합 뒤' '- 머신 `' '`post-merge-12.log`(첫 실행), `post-merge-12-retry.log`(재실행)'; do
  grep -qF -- "$want" <<<"$out" || fail "플레이크 코멘트에 '$want' 없음: $out"
done
! grep -q '/secret/dir\|worker-screen-line\|loop-stopped' <<<"$out" || fail "플레이크 코멘트에 로컬 경로·로그 본문·멈춤 라벨이 실림: $out"
out="$(slack_text)"
[[ "$(calls curl)" == 1 && "$(calls osascript)" == 1 && "$out" == ":warning: *Post-merge check passed on retry* · o/r · "*$'\n'"$L/12|#12>: first run failed in 2640s, retry passed in 300s — likely flaky (logs post-merge-12.log, post-merge-12-retry.log)" ]] \
  || fail "플레이크 Slack 알림(아이콘·멘션 없음·로그 꼬리 없음): $out"
rc="$(stop_case ok 'REPO_URL=; slack_post "Ticket loop started" "1 ticket"$'"'"'\n'"'"'"#12 T01" start')"
out="$(slack_text)"; [[ "$out" == ":arrow_forward: *Ticket loop started* · o/r · "*$'\n1 ticket\n#12 T01' ]] || fail "시작 알림(저장소 URL 없으면 링크 없이): $out"
# 멈춤 기록(0.9): 수습 없이 멈춰도 한 번 남긴다 — 사람이 /loop-triage <id> 로 이어받을 자리. 종류는 STOP_KIND(없으면 other), 신호는 signal,
# set -e 는 unexpected_exit. 잠금을 못 잡은 실행은 남기지 않고, 무인 수습이 이미 남긴 멈춤(STOP_RECORD)은 다시 쓰지 않는다. set -u 아래에서
# 루프가 아직 채우지 않은 변수(BASE_BRANCH·MAIN_WT·ORIG_ARGS·PARENT …)가 비어 있어도 써져야 한다
stops() { ls "$M/.ticket-loop/stops/"*.json 2>/dev/null | grep -v '\.verdict\.json$' || true; }
rc="$(stop_case die)"; rec="$(stops)"
[[ "$rc" == 1 && "$(grep -c . <<<"$rec")" == 1 ]] || fail "die: 멈춤 기록이 하나가 아님(rc $rc): $rec"
jq -e --arg wt "$M/home/wt/issue-12" --arg dir "$M/.ticket-loop/stops" '.kind == "other" and .mode == "manual" and .issue == 12 and .pr == 34
  and (.reason | startswith("#12: PR #34 CI failed")) and .worker_worktree == $wt and .rerun == "bash scripts/ticket-loop.sh"
  and .verdict_file == ($dir + "/" + .id + ".verdict.json") and (.id | test("^[0-9]{8}-[0-9]{6}-12$")) and .logs.loop_from_byte > 0
  and .agent == "claude" and .base_branch == null and .spec == null' "$rec" >/dev/null || fail "die: 멈춤 기록 내용: $(cat "$rec")"
grep -qF "멈춤 기록 \`.ticket-loop/stops/$(basename "$rec")\`" <<<"$(gh_comment)" && grep -qF "\`/loop-triage $(basename "$rec" .json)\`" <<<"$(gh_comment)" \
  || fail "die: GitHub 코멘트에 멈춤 기록·/loop-triage 안내가 없음: $(gh_comment)"
rc="$(stop_case die 'ORIG_ARGS=(--parent 96 "a b"); STOP_KIND=ci_failed; BASE_BRANCH=main; PARENT=96')"; rec="$(stops)"
jq -e '.rerun == "bash scripts/ticket-loop.sh --parent 96 a\\ b" and .kind == "ci_failed" and .base_branch == "main" and .spec == 96' "$rec" >/dev/null \
  || fail "멈춤 기록의 다시 실행할 명령·종류·스펙: $(cat "$rec")"
rc="$(stop_case errexit)"; [[ "$(jq -r .kind "$(stops)")" == unexpected_exit ]] || fail "set -e 멈춤 기록의 종류가 unexpected_exit 가 아님"
rc="$(stop_case HUP)"; [[ "$(jq -r .kind "$(stops)")" == signal ]] || fail "신호 멈춤 기록의 종류가 signal 이 아님"
rc="$(stop_case die 'LOCK_HELD=0; STOP_ISSUE=; CUR_N=')"; [[ -z "$(stops)" ]] || fail "잠금을 못 잡은 실행이 멈춤 기록을 남김"
rc="$(stop_case die 'STOP_RECORD="$PWD/.ticket-loop/stops/20261016-154317-12.json"')"
[[ -z "$(stops)" ]] && grep -qF '`/loop-triage 20261016-154317-12`' <<<"$(gh_comment)" || fail "무인 수습이 남긴 기록이 있으면 새로 쓰지 않고 그 기록을 가리켜야 함: $(stops)"
# 무인 수습이 고쳐 이어 갈 때의 기록: 코멘트 하나(멈춤 라벨 없음, 홈 경로는 ~), Slack 은 :recycle: 에 멘션 없이
rc="$(stop_case ok 'STOP_ISSUE=; CUR_N=; STOP_RECORD="$PWD/.ticket-loop/stops/20261016-154317-12.json"; triage_resume_record 12 "#12: post-merge check failed. Check the log ($HOME/r/.ticket-loop/post-merge-12.log)" project "기대값을 새 열에 맞췄다" "fix PR #131 merged" "수정 PR #131 병합"')"
[[ "$rc" == 0 && "$(jq -rs '[.[] | select(.cmd == "gh") | .args[0:2] | join(" ")] | join(",")' "$M/calls.jsonl")" == "issue comment" ]] || fail "수습 이어 감 기록은 코멘트 하나뿐이어야 한다(rc $rc): $(jq -c . "$M/calls.jsonl")"
out="$(gh_comment)"
for want in $'12\n**ticket-loop 무인 수습 — 이어 감**' '- 멈춘 이유: #12: post-merge check failed. Check the log (~/r/.ticket-loop/post-merge-12.log)' '- 분류 `project` — 기대값을 새 열에 맞췄다' '- 조치: 수정 PR #131 병합. 루프는 멈춘 자리에서 이어 갔다' '멈춤 기록 `.ticket-loop/stops/20261016-154317-12.json`'; do
  grep -qF -- "$want" <<<"$out" || fail "수습 이어 감 코멘트에 '$want' 없음: $out"
done
! grep -qF "$M/home" <<<"$out" || fail "수습 이어 감 코멘트에 홈 경로가 그대로 실림: $out"
out="$(slack_text)"; [[ "$out" == ":recycle: *Triage fixed it — loop continues* · o/r · "*$'\n'"$L/12|#12>: 기대값을 새 열에 맞췄다 (fix PR $L/131|#131> merged)" ]] || fail "수습 이어 감 Slack(아이콘·멘션 없음): $out"
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

# 무인 수습(0.9): triage 를 가짜 백엔드·gh·CI 로 그대로 부른다. 실제 git 저장소(bare origin 에 loop-triage 스킬 커밋)를 쓴다.
# 가짜 backend_worktree_create 는 프롬프트에서 판정 파일 경로를 읽어 VERDICT 를 써 둔다(빈 값이면 판정 없이 idle 로 남는다)
TG="$(cd "$T" && pwd -P)/triage"; mkdir -p "$TG/bin"
git -C "$TG" init -q --bare origin.git
git clone -q "$TG/origin.git" "$TG/repo" 2>/dev/null
mkdir -p "$TG/repo/.agents/skills/loop-triage"; echo skill > "$TG/repo/.agents/skills/loop-triage/SKILL.md"
git -C "$TG/repo" add -A && git -C "$TG/repo" -c user.name=t -c user.email=t@t commit -qm init && git -C "$TG/repo" push -q origin HEAD:main 2>/dev/null
git -C "$TG/repo" push -q origin "$(git -C "$TG/repo" -c user.name=t -c user.email=t@t commit-tree -m empty 4b825dc642cb6eb9a060e54bf8d69288fbee4904):refs/heads/noskill" 2>/dev/null
sed -n '/^# ----- 알림 · 멈춤 보고 -----/,/^# ----- 알림 · 멈춤 보고 끝 -----/p' "$KIT/files/scripts/ticket-loop.sh" > "$TG/fn.sh"
sed -n '/^# ---------- 무인 수습 ----------/,/^# ---------- 티켓 기록 · 스펙 리포트 ----------/p' "$KIT/files/scripts/ticket-loop.sh" >> "$TG/fn.sh"
sed -n '/^idle_wait_ms() /p; /^GH_TRANSIENT_RE=/p; /^merge_pr() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$TG/fn.sh"
grep -q '^triage() {' "$TG/fn.sh" && grep -q '^wait_for_verdict() {' "$TG/fn.sh" && grep -q '^idle_wait_ms() ' "$TG/fn.sh" && grep -q '^merge_pr() {' "$TG/fn.sh" \
  || fail "무인 수습 블록을 찾지 못함"
for b in curl osascript; do cp "$M/bin/$b" "$TG/bin/$b"; done
cat > "$TG/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf "%s\x1e" "$@" | jq -Rsc '{cmd: "gh", args: (split("\u001e")[:-1])}' >> "$CALLS"
case "$1 $2" in
  "pr view") [[ -n "${PR_VIEW_JSON:-}" ]] && printf '%s\n' "$PR_VIEW_JSON" ;;
  "pr merge") exit "${MERGE_RC:-0}" ;;
  "issue view") echo "${ISSUE_STATE:-OPEN}" ;;
esac
EOF
chmod +x "$TG/bin/gh"
cat > "$TG/run.sh" <<'EOF'
set -euo pipefail
ROOT="$PWD"; MAIN_WT="$PWD"; OWNER_REPO=o/r; BASE_BRANCH="${BASE:-main}"; BACKEND=cmux; BACKEND_NAME=cmux; AGENT=claude; SKILL_PREFIX=/
SLACK_WEBHOOK_URL=https://hooks.example/x; SLACK_MENTION="<@U1>"; STOPPED_LABEL=loop-stopped
LOG_FILE="$PWD/.ticket-loop/loop.log"; mkdir -p .ticket-loop; : > "$LOG_FILE"
LOOP_TRIAGE="${LOOP_TRIAGE:-1}"; TRIAGE_MAX="${TRIAGE_MAX:-1}"; TRIAGE_TIMEOUT_SEC="${TRIAGE_TIMEOUT_SEC:-60}"; TRIAGE_LABEL=loop-triage; MERGE_METHOD=merge; GH_TRIES=3; GH_RETRY_SEC=0
PROGRESS_SEC=0; IDLE_WAIT_MS=1; STARTUP_GRACE_SEC=0; IDLE_RECHECK_SEC=0; IDLE_STRIKES=3; REOPEN_WATCH_SEC=0
log() { case "$1" in title|step|ok|warn|err) shift ;; esac; printf '[2026-10-16 15:43:17] %s\n' "$*" >> "$LOG_FILE"; }
dim_lines() { sed 's/^/  /' >> "$LOG_FILE"; }
record_ticket() { :; }
terminal_idle() { return 0; }; terminal_tail() { echo same-screen; }
ensure_agent_started() { echo "started $1 $2" >> ev; }
backend_set_status() { echo "status $1 $2 ${4:-}" >> ev; }
backend_worktree_remove() { echo "remove $1 $2" >> ev; }
ci_expected() { [[ "${CI_EXPECTED:-1}" == 1 ]]; }
ci_passed() { echo "ci_passed $1" >> ev; [[ "${CI_PASS:-1}" == 1 ]]; }
backend_worktree_create() {
  local vfile
  printf '%s' "$2" > prompt.txt; echo "create $1 $3" >> ev
  [[ "${SPAWN_FAIL:-0}" == 0 ]] || die "fake create failed"
  WT="wt-$3"; WT_PATH="$PWD/tw/$3"; mkdir -p "$WT_PATH"; WT_BRANCH="$3"; HANDLE="h-$3"
  vfile="$(grep -oE '판정을 [^ ]+ 에' <<<"$2" | sed -e 's/^판정을 //' -e 's/ 에$//')"
  [[ -z "${VERDICT:-}" ]] || { printf '%s' "$VERDICT" > "$vfile.tmp"; mv "$vfile.tmp" "$vfile"; }
}
source "$FN"
LOCK_HELD="${LOCK:-1}"; REPO_URL=https://github.com/o/r
STOP_ISSUE=12; CUR_N=12; CUR_PR="${PR:-}"; CUR_TITLE=T12
rc=0; triage "$KIND" "${REASON:-#12: post-merge check failed}" || rc=$?
a_rc=""; a_note=""
if [[ -n "${AGAIN:-}" ]]; then a_rc=0; triage "$AGAIN" "again" || a_rc=$?; a_note="$TRIAGE_NOTE"; fi
jq -n --argjson rc "$rc" --arg note "$TRIAGE_NOTE" --arg result "$TRIAGE_RESULT" --arg fix "$TRIAGE_FIX_PR" --arg rec "$STOP_RECORD" \
  --arg kind "$STOP_KIND" --argjson used "$TRIAGE_USED" --arg a_rc "$a_rc" --arg a_note "$a_note" \
  '{rc: $rc, note: $note, result: $result, fix: $fix, rec: $rec, kind: $kind, used: $used, a_rc: $a_rc, a_note: $a_note}' > out.json
EOF
tcase() {  # 환경 설정(VAR=값 …) → $TG/repo/out.json, ev, calls.jsonl, prompt.txt
  (cd "$TG/repo" && rm -rf .ticket-loop ev prompt.txt out.json tw && : > "$TG/calls.jsonl" \
    && env PATH="$TG/bin:$PATH" CALLS="$TG/calls.jsonl" HOME="$TG/home" FN="$TG/fn.sh" "$@" bash "$TG/run.sh" 2>"$TG/err") || fail "triage 실행이 죽음($*): $(cat "$TG/err")"
}
o() { jq -r "$1" "$TG/repo/out.json"; }
tcalls() { jq -rs '[.[] | select(.cmd == "gh") | .args[0:2] | join(" ")] | join(",")' "$TG/calls.jsonl"; }
tslack() { jq -rs --argjson i "$1" '[.[] | select(.cmd == "curl")][$i].args as $a | $a[($a | index("--data")) + 1] | fromjson | .text' "$TG/calls.jsonl"; }
ncurl() { jq -s '[.[] | select(.cmd == "curl")] | length' "$TG/calls.jsonl"; }
PRV='{"state":"OPEN","baseRefName":"main","headRefName":"loop-triage-12-x"}'
V_FIX='{"verdict":"resume","category":"project","summary":"기대값을 새 열에 맞췄다","fix_pr":131,"pushed_to_pr":false,"kit_bug_report":null}'
# 1) 병합 뒤 검증 실패 → 수정 PR 로 resume: 라벨·CI·병합, 수습 워크트리 정리, 이어 감 기록, 멈춤 기록은 비운다(다음 멈춤이 새로 쓴다)
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON="$PRV"
[[ "$(o .rc)" == 0 && "$(o .fix)" == 131 && "$(o .rec)" == "" && "$(o .kind)" == "" && "$(o .used)" == 1 ]] || fail "수정 PR resume: $(cat "$TG/repo/out.json")"
[[ "$(o .result)" == "resumed (project, fix PR #131 merged): 기대값을 새 열에 맞췄다" ]] || fail "수정 PR resume 결과 문자열: $(o .result)"
[[ "$(tcalls)" == "pr view,label create,pr edit,pr merge,issue comment" ]] || fail "수정 PR resume 의 gh 호출 순서: $(tcalls)"
jq -e -s '[.[] | select(.cmd == "gh" and .args[1] == "edit")][0].args | . == ["pr","edit","131","--add-label","loop-triage"]' "$TG/calls.jsonl" >/dev/null \
  && jq -e -s '[.[] | select(.cmd == "gh" and .args[1] == "merge")][0].args | . == ["pr","merge","131","--merge"]' "$TG/calls.jsonl" >/dev/null || fail "수정 PR 라벨·병합 인자"
grep -q '^ci_passed 131$' "$TG/repo/ev" && grep -q '^remove wt-loop-triage-12-[0-9]\{6\} ' "$TG/repo/ev" && grep -q '^create 12 loop-triage-12-[0-9]\{6\}$' "$TG/repo/ev" || fail "수정 PR CI·수습 워크트리 이름·정리: $(cat "$TG/repo/ev")"
rec="$(ls "$TG/repo/.ticket-loop/stops/"*-12.json)"
jq -e '.kind == "post_merge_failed" and .mode == "unattended" and .reason == "#12: post-merge check failed"' "$rec" >/dev/null || fail "무인 수습의 멈춤 기록: $(cat "$rec")"
[[ "$(cat "$TG/repo/prompt.txt")" == "/loop-triage $rec — 무인 루프(ticket-loop.sh)가 멈춘 지점에서 띄운 수습 세션이다."*"PR은 병합하지 마라"*"판정을 ${rec%.json}.verdict.json 에 써라." ]] || fail "수습 프롬프트: $(cat "$TG/repo/prompt.txt")"
[[ "$(ncurl)" == 2 ]] || fail "수습 시작·이어 감 Slack 두 번이 아님: $(ncurl)"
out="$(tslack 0)"; [[ "$out" == ":hammer_and_wrench: *Ticket loop stopped — triage started* · o/r · "*$'\n<https://github.com/o/r/issues/12|#12>: post-merge check failed\n```\n'* ]] && ! grep -qF '<@U1>' <<<"$out" \
  || fail "수습 시작 Slack(아이콘·멘션 없음·로그 꼬리): $out"
grep -qF ':recycle: *Triage fixed it — loop continues*' <<<"$(tslack 1)" || fail "이어 감 Slack: $(tslack 1)"
grep -q 'stopping — #12: post-merge check failed' "$TG/repo/.ticket-loop/loop.log" && grep -q 'triage verdict: resume (project) — 기대값을 새 열에 맞췄다' "$TG/repo/.ticket-loop/loop.log" || fail "수습 로그 줄: $(cat "$TG/repo/.ticket-loop/loop.log")"
# 2) halt: 사유에 붙일 판정 요약, 워크트리는 남기고(todo), 멈춤 기록은 그대로(stop_report 가 다시 쓰지 않는다), Slack 은 시작 한 번(멈춤은 die 가)
tcase KIND=post_merge_failed VERDICT='{"verdict":"halt","category":"needs-human","summary":"운영 DB 접근이 필요하다","fix_pr":null}'
[[ "$(o .rc)" == 1 && "$(o .note)" == " — triage (needs-human): 운영 DB 접근이 필요하다" && "$(o .result)" == "halt (needs-human): 운영 DB 접근이 필요하다" && -f "$(o .rec)" && "$(o .kind)" == post_merge_failed ]] \
  || fail "halt: $(cat "$TG/repo/out.json")"
! grep -q '^remove ' "$TG/repo/ev" && grep -q '^status wt-loop-triage-12-[0-9]* todo 무인 수습: 멈춤' "$TG/repo/ev" && [[ "$(ncurl)" == 1 && -z "$(tcalls)" ]] || fail "halt: 워크트리를 남기고 시작 알림만: $(cat "$TG/repo/ev") / $(tcalls)"
# 3) 진단만 하는 종류(worker_no_pr)는 resume 을 써도 멈춘다
tcase KIND=worker_no_pr VERDICT='{"verdict":"resume","category":"project","summary":"x"}'
[[ "$(o .rc)" == 1 && "$(o .note)" == " — triage (project): x" ]] && grep -q 'worker_no_pr is diagnosis only' "$TG/repo/.ticket-loop/loop.log" || fail "worker_no_pr resume 은 멈춰야 함: $(cat "$TG/repo/out.json")"
# 4) 횟수: 한 실행에 TRIAGE_MAX 번, 같은 멈춤(종류·이슈)에는 한 번
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON="$PRV" AGAIN=ci_failed
[[ "$(o .a_rc)" == 1 && "$(o .a_note)" == " (no triage: 1/1 used in this run)" && "$(grep -c '^create ' "$TG/repo/ev")" == 1 ]] || fail "TRIAGE_MAX: $(cat "$TG/repo/out.json")"
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON="$PRV" AGAIN=post_merge_failed TRIAGE_MAX=2
[[ "$(o .a_rc)" == 1 && "$(o .a_note)" == " (triage already ran for this stop)" ]] || fail "같은 멈춤에 두 번: $(cat "$TG/repo/out.json")"
# 5) 띄우지 않는 경우: LOOP_TRIAGE=0, 잠금 없음, 대상이 아닌 종류(사유에 덧붙일 말 없음, 기록·알림 없음), 기본 브랜치에 스킬 없음
for env in LOOP_TRIAGE=0 LOCK=0 KIND=timeout; do
  tcase KIND=post_merge_failed "$env" VERDICT="$V_FIX"
  [[ "$(o .rc)" == 1 && "$(o .note)" == "" && ! -d "$TG/repo/.ticket-loop/stops" && "$(ncurl)" == 0 && ! -e "$TG/repo/ev" ]] || fail "$env: 수습을 띄우면 안 됨: $(cat "$TG/repo/out.json")"
done
tcase KIND=post_merge_failed BASE=noskill VERDICT="$V_FIX"
[[ "$(o .rc)" == 1 && "$(o .note)" == " (no triage: loop-triage skill not on origin/noskill)" && ! -d "$TG/repo/.ticket-loop/stops" ]] || fail "스킬 없는 기본 브랜치: $(cat "$TG/repo/out.json")"
# 6) 판정 없이 끝남(idle 연속) · 시간 초과 · 세션이 뜨지 않음(백엔드의 die 가 루프를 죽이지 않고 원래 사유가 남는다)
tcase KIND=post_merge_failed
[[ "$(o .rc)" == 1 && "$(o .note)" == " — triage: the session stopped without a verdict (session worktree $TG/repo/tw/"* && "$(o .result)" == "no verdict: the session stopped without a verdict" ]] \
  && grep -q 'triage session idle, no verdict (3/3)' "$TG/repo/.ticket-loop/loop.log" && grep -q '^status wt-.* todo 무인 수습: 판정 없이 끝남' "$TG/repo/ev" || fail "판정 없음: $(cat "$TG/repo/out.json")"
tcase KIND=post_merge_failed TRIAGE_TIMEOUT_SEC=0
[[ "$(o .note)" == " — triage: timed out after 0m (session worktree "* ]] || fail "시간 초과: $(o .note)"
tcase KIND=post_merge_failed SPAWN_FAIL=1 VERDICT="$V_FIX"
[[ "$(o .rc)" == 1 && "$(o .note)" == " (triage session did not start — see the loop log)" ]] && grep -q 'triage session did not start — fake create failed' "$TG/repo/.ticket-loop/loop.log" \
  && [[ "$(ncurl)" == 1 && -z "$(tcalls)" ]] || fail "세션이 안 뜸: 원래 사유로 멈춰야 함(멈춤 보고는 die 가 한 번): $(cat "$TG/repo/out.json") / $(tcalls)"
# 7) 수정 PR 이 CI 실패·기본 브랜치가 아닌 곳으로 감·병합 실패 → 멈춘다(병합하지 않는다)
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON="$PRV" CI_PASS=0
[[ "$(o .rc)" == 1 && "$(o .note)" == " — triage (project): 기대값을 새 열에 맞췄다 (fix PR #131: CI failed — gh pr checks 131)" && "$(tcalls)" == "pr view,label create,pr edit" ]] || fail "수정 PR CI 실패: $(o .note) / $(tcalls)"
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON='{"state":"OPEN","baseRefName":"dev","headRefName":"x"}'
[[ "$(o .rc)" == 1 && "$(o .note)" == *"(fix PR #131 is not an open PR into main: OPEN, base dev)" && "$(tcalls)" == "pr view" ]] || fail "기본 브랜치가 아닌 수정 PR: $(o .note) / $(tcalls)"
tcase KIND=post_merge_failed VERDICT="$V_FIX" PR_VIEW_JSON="$PRV" MERGE_RC=1
[[ "$(o .rc)" == 1 && "$(o .note)" == *"(fix PR #131: merge failed)" && "$(o .fix)" == "" ]] || fail "수정 PR 병합 실패: $(o .note)"
# 8) CI 실패 → 티켓 PR 브랜치에 push 로 resume(병합할 PR 없음). 티켓 PR 번호를 fix_pr 로 적어도 push 로 본다
tcase KIND=ci_failed PR=34 VERDICT='{"verdict":"resume","category":"project","summary":"번들 천장을 근거와 함께 올렸다","fix_pr":null,"pushed_to_pr":true}'
[[ "$(o .rc)" == 0 && "$(o .result)" == "resumed (project, pushed to PR #34): 번들 천장을 근거와 함께 올렸다" && "$(tcalls)" == "issue comment" ]] || fail "PR 브랜치 push resume: $(o .result) / $(tcalls)"
tcase KIND=ci_failed PR=34 VERDICT='{"verdict":"resume","category":"flake","summary":"러너 오류 — 실패한 job 을 다시 돌렸다","fix_pr":34}'
[[ "$(o .rc)" == 0 && "$(o .result)" == "resumed (flake, pushed to PR #34): "* && "$(tcalls)" == "issue comment" ]] || fail "fix_pr 가 티켓 PR 이면 push 로: $(o .result) / $(tcalls)"
tcase KIND=post_merge_failed VERDICT='{"verdict":"resume","category":"flake","summary":"세 번 다시 돌려 모두 통과"}'
[[ "$(o .rc)" == 0 && "$(o .result)" == "resumed (flake, no code change): 세 번 다시 돌려 모두 통과" && "$(o .fix)" == "" ]] || fail "코드 변경 없는 resume: $(o .result)"
# 8b) 준비 실패의 수정 PR 병합이 티켓 이슈를 닫으면(병합 커밋의 닫기 키워드) 다시 연다. 열려 있으면 다섯 번 보고 그대로 둔다.
#     병합 뒤 검증 실패는 이슈가 원래 닫혀 있으므로 보지 않는다(1번 케이스의 호출 순서에 issue view 가 없다)
tcase KIND=setup_failed REASON="#12: WORKTREE_SETUP_CMD failed" VERDICT="$V_FIX" PR_VIEW_JSON="$PRV" ISSUE_STATE=CLOSED
[[ "$(o .rc)" == 0 && "$(tcalls)" == "pr view,label create,pr edit,pr merge,issue view,issue reopen,issue comment" ]] || fail "수정 PR 이 닫은 이슈를 다시 열지 않음: $(o .rc) / $(tcalls)"
jq -e -s '[.[] | select(.cmd == "gh" and .args[1] == "reopen")][0].args | .[2] == "12" and .[3] == "--comment" and (.[4] | test("수정 PR #131"))' "$TG/calls.jsonl" >/dev/null \
  && grep -q 'merging fix PR #131 closed the issue — reopening it' "$TG/repo/.ticket-loop/loop.log" || fail "다시 열기 인자·로그: $(cat "$TG/repo/.ticket-loop/loop.log")"
tcase KIND=setup_failed REASON="#12: WORKTREE_SETUP_CMD failed" VERDICT="$V_FIX" PR_VIEW_JSON="$PRV"
[[ "$(o .rc)" == 0 && "$(tcalls)" == "pr view,label create,pr edit,pr merge,issue view,issue view,issue view,issue view,issue view,issue comment" ]] || fail "열린 이슈를 다시 열거나 덜 지켜봄: $(tcalls)"
# 9) 루프 버그: 키트 버그 보고서 경로를 사유에 붙인다
tcase KIND=post_merge_failed VERDICT='{"verdict":"halt","category":"loop-bug","summary":"로그 경로 계산이 틀렸다","kit_bug_report":"/r/.ticket-loop/stops/1.kit-bug.md"}'
[[ "$(o .note)" == " — triage (loop-bug): 로그 경로 계산이 틀렸다 · kit bug report /r/.ticket-loop/stops/1.kit-bug.md" ]] || fail "키트 버그 보고서: $(o .note)"
echo "ok  무인 수습(띄우기·판정·수정 PR 병합·push·횟수·띄우지 않는 경우·판정 없음·시간 초과·기동 실패)"

# 워크트리 준비 실패(setup_failed): 실제 git 으로 loop_worktree_add 를 부른다. 수습이 고쳐(origin 에 커밋) 이어 가면 워크트리를 기본 브랜치로
# 당겨 준비를 다시 돌리고, 수습이 멈추면 사유에 판정을 붙여 die. 수습 세션 자신의 워크트리(이름이 다름)는 준비가 실패해도 띄운다
SW="$TG/setup"; mkdir -p "$SW"
git clone -q "$TG/origin.git" "$SW/repo" 2>/dev/null; git clone -q "$TG/origin.git" "$SW/fixer" 2>/dev/null
{ sed -n '/^loop_worktree_add() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh"; sed -n '/^bg_wait() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh"; } > "$SW/fn.sh"
grep -q '^loop_worktree_add() ' "$SW/fn.sh" || fail "loop_worktree_add 를 찾지 못함"
setup_case() {  # $1 TRIAGE_OK(1|0), $2 이름(비우면 기본) → 출력
  rm -rf "$SW/wts"; git -C "$SW/repo" worktree prune
  (cd "$SW/repo" && FN="$SW/fn.sh" SW="$SW" TRIAGE_OK="$1" NAME="${2:-}" bash -c '
    set -euo pipefail
    ROOT="$PWD"; MAIN_WT="$PWD"; BASE_BRANCH=main; BRANCH_PREFIX=issue-; WORKTREE_DIR="$SW/wts"; WORKTREE_SETUP_CMD="test -f fixed"
    log() { case "$1" in title|step|ok|warn|err) shift ;; esac; echo "LOG $*"; }; die() { echo "DIE $*"; exit 1; }
    tri_calls=0
    triage() {   # 진짜처럼 같은 멈춤에는 한 번만 — 두 번째는 1(이어 간 뒤에도 준비가 실패하면 루프는 멈춰야 한다)
      echo "TRIAGE $1|$2"; tri_calls=$((tri_calls + 1))
      [[ $tri_calls -eq 1 ]] || { TRIAGE_NOTE=" (triage already ran for this stop)"; return 1; }
      [[ "$TRIAGE_OK" == 1 ]] || { TRIAGE_NOTE=" — triage (environment): 레지스트리 장애"; return 1; }
      (cd "$SW/fixer" && git pull -q origin main 2>/dev/null; touch fixed; git add fixed; git -c user.name=t -c user.email=t@t commit -qm fix; git push -q origin HEAD:main 2>/dev/null)
      git -C "$ROOT" fetch -q origin main; return 0
    }
    source "$FN"
    git fetch -q origin main
    loop_worktree_add 12 ${NAME:+"$NAME"}
    echo "WT_PATH=$WT_PATH WT_BRANCH=$WT_BRANCH"' 2>&1) || true
}
out="$(setup_case 1)"
grep -q "^TRIAGE setup_failed|#12: WORKTREE_SETUP_CMD failed ($SW/wts/issue-12)$" <<<"$out" && grep -q '^LOG #12: worktree setup again after triage' <<<"$out" \
  && grep -q "^WT_PATH=$SW/wts/issue-12 WT_BRANCH=issue-12$" <<<"$out" && [[ -f "$SW/wts/issue-12/fixed" && "$(grep -c '^TRIAGE' <<<"$out")" == 1 ]] || fail "준비 실패 → 수습 → 당겨서 다시 준비: $out"
git -C "$SW/fixer" reset -q --hard HEAD~1 && git -C "$SW/fixer" push -qf origin HEAD:main 2>/dev/null; git -C "$SW/repo" fetch -q origin main
out="$(setup_case 0)"
grep -q "^DIE #12: WORKTREE_SETUP_CMD failed ($SW/wts/issue-12) — triage (environment): 레지스트리 장애$" <<<"$out" || fail "준비 실패 → 수습 halt 면 판정을 붙여 die: $out"
out="$(setup_case 1 loop-triage-12-154317)"
! grep -q '^TRIAGE' <<<"$out" && grep -q 'WORKTREE_SETUP_CMD failed .* — starting the session anyway' <<<"$out" && grep -q '^WT_PATH=.*/loop-triage-12-154317 WT_BRANCH=loop-triage-12-154317$' <<<"$out" \
  || fail "수습 세션의 워크트리는 준비가 실패해도 띄우고 수습을 다시 부르지 않아야 함: $out"
echo "ok  워크트리 준비 실패 → 수습 → 기본 브랜치로 당겨 다시 준비"

# 연결: 네 자리가 die 대신 triage 를 부르고(CI 실패·충돌·수리 뒤 새 커밋 없음은 같은 고리의 처음부터), 병합 뒤 검증은 다른 로그 이름으로
# 다시 돌린다. 티켓마다 멈춤 종류·기록·수습 결과를 비운다
SCRIPT="$KIT/files/scripts/ticket-loop.sh"
grep -qF 'triage worker_no_pr "$reason" || true' "$SCRIPT" && [[ "$(grep -cF 'STOP_KIND=ci_failed; triage ci_failed "$reason" && continue' "$SCRIPT")" == 3 ]] \
  && grep -qF 'if triage post_merge_failed "$reason"; then' "$SCRIPT" && grep -qF 'run_post_merge "${n}" -after-triage' "$SCRIPT" \
  && grep -qF 'triage setup_failed "$reason" || die "${reason}${TRIAGE_NOTE}"' "$SCRIPT" && grep -qF 'STOP_KIND=""; STOP_RECORD=""; TRIAGE_RESULT=""' "$SCRIPT" \
  || fail "무인 수습을 부르는 자리(네 종류)나 티켓마다 비우는 줄이 없음"
PMD="$(cd "$T" && pwd -P)/postmerge"   # 위 병합 뒤 검증 검사의 저장소($P 는 그 뒤 다른 검사가 다시 쓴다)
out="$(cd "$PMD/repo" && POST_MERGE_CMD='exit 0' LOG_FILE=.ticket-loop/loop-0101.log POST_MERGE_WORKTREE="$PMD/wt" FN="$PMD/fn.sh" bash -c '
  set -euo pipefail
  ROOT="$(git rev-parse --show-toplevel)"; MAIN_WT="$ROOT"; OWNER_REPO=o/r; BASE_BRANCH=main; POST_MERGE_COPY=""; POST_MERGE_PORT=""; PORT_WAIT_SEC=0; POST_MERGE_RETRY_CMD=""
  log() { shift; echo "$*"; }; dim_lines() { cat; }; fmt_epoch() { echo "$1"; }
  source "$FN"; LOG_FILE="$(abs_path "$LOG_FILE")"
  run_post_merge 7 -after-triage; echo "POST_MERGE_LOG=$POST_MERGE_LOG POST_MERGE_WT=$POST_MERGE_WT"' 2>&1)" || fail "수습 뒤 병합 뒤 검증 실패: $out"
grep -q "^POST_MERGE_LOG=$PMD/repo/.ticket-loop/post-merge-7-after-triage.log POST_MERGE_WT=$PMD/wt$" <<<"$out" || fail "수습 뒤 병합 뒤 검증이 앞 실행 로그를 덮지 않는 이름이 아님: $out"
echo "ok  무인 수습 연결(네 자리·수습 뒤 검증 로그 이름)"

# idle 오판 수: wait_for_pr 는 서브셸(bg_wait)에서 돌아 변수로 세면 부모에 남지 않았다(0.8.9 까지 요약·기록이 늘 0).
# 진짜 wait_for_pr 를 bg_wait 로 돌려 부모의 idle_fp_count 를 본다. 0.9.2 부터 오판은 일하던 워커를 idle 로 본 것만이다 —
# idle 뒤 다시 보니 PR 이 열려 있어도 PR 이 idle 보다 먼저 열렸으면 일을 마친 워커(세지 않음), 나중이면 오판. PR 없이 센 idle 뒤에
# 워커가 다시 일하면(화면이 바뀜·idle 이 풀림·PR 을 엶) 그 idle 들이 오판이고, idle 세 번으로 멈추면 그 연속 idle 은 오판이 아니다
W="$T/idlefp"; mkdir -p "$W"
for f in wait_for_pr idle_fp_add bg_wait pr_settle repair; do
  sed -n "/^${f}() {/,/^}/p" "$KIT/files/scripts/ticket-loop.sh" >> "$W/fn.sh"
  grep -q "^${f}() " "$W/fn.sh" || fail "${f} 를 찾지 못함"
done
sed -n '/^idle_fp_count() /p; /^ci_run_sec() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$W/fn.sh"
grep -q '^idle_fp_count() ' "$W/fn.sh" && grep -q '^ci_run_sec() ' "$W/fn.sh" || fail "idle_fp_count·ci_run_sec 를 찾지 못함"
# $1 open_pr_for 가 PR 을 돌려줄 호출 번호들, $2 PR 생성 시각(지금 기준 초, 빈 값이면 못 읽음), $3 terminal_idle 이 "일하는 중"(1)을 돌려줄
# 호출 번호들, $4 화면이 바뀌는 terminal_tail 호출 번호들 → "종료 코드|PR|오판 수"
idlefp_case() {
  (cd "$W" && PR_AT="$1" CREATED="$2" BUSY_AT="${3:-}" TAIL_NEW="${4:-}" CNT="$W/cnt" ICNT="$W/icnt" TCNT="$W/tcnt" bash -c '
    set -euo pipefail
    echo 0 > "$CNT"; echo 0 > "$ICNT"; echo 0 > "$TCNT"
    bump() { local c; c=$(( $(cat "$1") + 1 )); echo "$c" > "$1"; echo "$c"; }
    log() { :; }; idle_wait_ms() { echo 1; }
    terminal_idle() { local c; c="$(bump "$ICNT")"; [[ " $BUSY_AT " != *" $c "* ]] || return 1; return 0; }
    terminal_tail() { local c v=0 k; c="$(bump "$TCNT")"; for k in $TAIL_NEW; do [[ $k -gt $c ]] || v=$((v + 1)); done; echo "screen$v"; }
    open_pr_for() { local c; c="$(bump "$CNT")"; [[ " $PR_AT " != *" $c "* ]] || echo 77; }
    pr_created_epoch() { [[ -z "$CREATED" ]] || echo $(( $(date +%s) + CREATED )); }
    PROGRESS_SEC=0; IDLE_WAIT_MS=1; STARTUP_GRACE_SEC=0; IDLE_RECHECK_SEC=0; IDLE_STRIKES=3
    source fn.sh
    pr_settle() { :; }   # fn.sh 의 진짜 것을 덮는다(아래에서 따로 본다)
    IDLE_FP_FILE="$(mktemp)"; rc=0
    bg_wait wait_for_pr 7 h $(( $(date +%s) + 60 )) > out || rc=$?
    echo "$rc|$(cat out)|$(idle_fp_count)"; rm -f "$IDLE_FP_FILE"')
}
out="$(idlefp_case "2 3" -100)"; [[ "$out" == "0|77|0" ]] || fail "PR 을 연 뒤 idle(일을 마친 워커)을 오판으로 셈: $out (기대 0|77|0)"
out="$(idlefp_case "2 3" 100)"; [[ "$out" == "0|77|1" ]] || fail "idle 을 잡은 뒤 열린 PR(일하던 워커): $out (기대 0|77|1)"
out="$(idlefp_case "2 3" "")"; [[ "$out" == "0|77|0" ]] || fail "PR 생성 시각을 못 읽으면 세지 않아야: $out (기대 0|77|0)"
out="$(idlefp_case "2" 100)"; [[ "$out" == "1||1" ]] || fail "오판 한 번 뒤 PR 없이 멈춘 경우: $out (기대 1||1)"
out="$(idlefp_case "" 0)"; [[ "$out" == "1||0" ]] || fail "idle 세 번으로 멈춘 연속 idle 을 오판으로 셈: $out (기대 1||0)"
out="$(idlefp_case "3" 0)"; [[ "$out" == "0|77|1" ]] || fail "PR 없이 센 idle 한 번 뒤 PR: $out (기대 0|77|1)"
out="$(idlefp_case "" 0 "" "2")"; [[ "$out" == "1||1" ]] || fail "idle 뒤 화면이 바뀐 경우: $out (기대 1||1)"
out="$(idlefp_case "4" 0 "2")"; [[ "$out" == "0|77|1" ]] || fail "idle 뒤 다시 일함(idle 풀림) 다음 PR: $out (기대 0|77|1)"
[[ "$(cd "$W" && bash -c 'source fn.sh; IDLE_FP_FILE=; idle_fp_count; IDLE_FP_FILE=/nonexistent; idle_fp_count')" == $'0\n0' ]] || fail "idle_fp_count: 파일이 없으면 0"
! grep -q 'IDLE_FALSE_POSITIVES' "$KIT/files/scripts/ticket-loop.sh" || fail "부모에 남지 않는 변수 IDLE_FALSE_POSITIVES 를 아직 쓴다"
grep -q 'idle false positives $(idle_fp_count)' "$KIT/files/scripts/ticket-loop.sh" && grep -q -- '--argjson idle "$(idle_fp_count)"' "$KIT/files/scripts/ticket-loop.sh" || fail "요약 줄·기록이 idle_fp_count 를 쓰지 않음"
echo "ok  idle 오판 수(일하던 워커를 idle 로 본 것만)가 서브셸(bg_wait)을 넘어 요약·기록에 남음"

# PR 을 찾은 뒤의 정리 대기(pr_settle): 이슈에 IN_REVIEW_LABEL 이 붙었으면 idle 을 기다리지 않고, idle 이면 바로, 둘 다 아니면
# PR_SETTLE_SEC 에서 넘어간다(0.9.1 까지는 idle 하나만 10분 — cmux lifecycle 이 비면 10분을 다 썼다)
settle_case() {  # $1 라벨 있음(1/0), $2 terminal_idle 종료 코드 → "idle 호출 수|경고 줄 수"
  (cd "$W" && HAS="$1" IRC="$2" bash -c '
    set -euo pipefail
    n_idle=0; warns=0
    issue_has_label() { [[ "$1" == 7 && "$2" == in-review && "$HAS" == 1 ]]; }
    terminal_idle() { n_idle=$((n_idle + 1)); return "$IRC"; }
    log() { [[ "$1" != warn ]] || warns=$((warns + 1)); }
    IN_REVIEW_LABEL=in-review; PR_SETTLE_SEC=0
    source fn.sh
    pr_settle 7 h; echo "$n_idle|$warns"')
}
[[ "$(settle_case 1 1)" == "0|0" ]] || fail "pr_settle: 라벨이 있는데 idle 을 기다림: $(settle_case 1 1)"
[[ "$(settle_case 0 0)" == "1|0" ]] || fail "pr_settle: idle 인데 넘어가지 않음: $(settle_case 0 0)"
[[ "$(settle_case 0 3)" == "1|0" ]] || fail "pr_settle: 터미널에 닿지 못하는데 기다림: $(settle_case 0 3)"
[[ "$(settle_case 0 1)" == "1|1" ]] || fail "pr_settle: 라벨도 idle 도 없으면 상한에서 한 줄 남기고 넘어가야: $(settle_case 0 1)"
! grep -q 'terminal_idle "${handle}" "$IDLE_WAIT_MS"' "$KIT/files/scripts/ticket-loop.sh" || fail "PR 뒤에 아직 idle 을 IDLE_WAIT_MS(10분)까지 기다린다"
echo "ok  PR 뒤 정리 대기(라벨·idle·상한)"

# CI 소요는 GitHub 체크 시각으로: 가장 이른 시작 → 가장 늦은 끝. 시작 전 체크(0001-…)·빈 출력은 빼고, 못 읽으면 빈 값
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "$1 $2" == "pr checks" ]] || exit 1
printf '%s' "${CHECKS_JSON:-}"; exit "${CHECKS_RC:-0}"
GH
chmod +x "$W/bin/gh"
ci_case() { (cd "$W" && PATH="$W/bin:$PATH" CHECKS_JSON="$1" CHECKS_RC="${2:-0}" bash -c 'set -euo pipefail; source fn.sh; v="$(ci_run_sec 162)"; echo "[$v]"'); }
J='[{"startedAt":"2026-10-16T22:09:12Z","completedAt":"2026-10-16T22:10:17Z"},{"startedAt":"2026-10-16T22:09:12Z","completedAt":"2026-10-16T22:13:17Z"},{"startedAt":"2026-10-16T22:09:11Z","completedAt":"2026-10-16T22:10:50Z"}]'
[[ "$(ci_case "$J")" == "[246]" ]] || fail "ci_run_sec: rental-portal PR #162 의 체크 시각에서 246초가 아님: $(ci_case "$J")"
[[ "$(ci_case "$J" 8)" == "[246]" ]] || fail "ci_run_sec: gh 가 비0 으로 끝나도 출력은 읽어야: $(ci_case "$J" 8)"
[[ "$(ci_case '[{"startedAt":"0001-01-01T00:00:00Z","completedAt":"0001-01-01T00:00:00Z"},{"startedAt":"2026-10-16T22:09:11.5Z","completedAt":"2026-10-16T22:10:50Z"}]')" == "[99]" ]] \
  || fail "ci_run_sec: 시작 전 체크나 소수 초를 다루지 못함"
[[ "$(ci_case '')" == "[]" && "$(ci_case '[]')" == "[]" && "$(ci_case 'not json')" == "[]" ]] || fail "ci_run_sec: 못 읽으면 빈 값이어야"
grep -qF 'ci_sec="$(ci_run_sec "${pr}")"; [[ -n "$ci_sec" ]] || ci_sec=$(( $(date +%s) - ci_started ))' "$KIT/files/scripts/ticket-loop.sh" || fail "CI 통과 뒤 ci_run_sec 를 쓰지 않거나 못 읽을 때 루프가 잰 값으로 돌아가지 않음"
echo "ok  CI 소요(GitHub 체크 시각)"

# 병합 재시도(이슈 #7): GitHub 일시 장애(5xx·네트워크·"Base branch was modified")만 GH_TRIES 번까지 다시 하고, 실패할 때마다 먼저
# 이미 병합됐는지 본다. 브랜치 보호 같은 거절은 바로 1 — 사람에게 넘기는 자리다
MG="$T/merge"; mkdir -p "$MG/bin"
sed -n '/^GH_TRANSIENT_RE=/p; /^merge_pr() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$MG/fn.sh"
grep -q '^merge_pr() ' "$MG/fn.sh" && grep -q '^GH_TRANSIENT_RE=' "$MG/fn.sh" || fail "merge_pr 를 찾지 못함"
cat > "$MG/bin/gh" <<'GH'
#!/usr/bin/env bash
nth() { local i="$1" f="$2" l; l="$(sed -n "${i}p" "$f")"; [[ -n "$l" ]] || l="$(tail -n1 "$f")"; printf '%s' "$l"; }   # 넘치면 마지막 줄
case "$1 $2" in
  "pr merge") c=$(( $(cat "$MG/mc") + 1 )); echo "$c" > "$MG/mc"; echo "$*" >> "$MG/args"
              l="$(nth "$c" "$MG/merges")"; [[ "$l" == ok ]] && exit 0; printf '%s\n' "$l" >&2; exit 1 ;;
  "pr view") c=$(( $(cat "$MG/vc") + 1 )); echo "$c" > "$MG/vc"; nth "$c" "$MG/states"; echo ;;
  *) exit 1 ;;
esac
GH
chmod +x "$MG/bin/gh"
merge_case() {  # $1 pr view 가 차례로 낼 state(공백으로 가름), 나머지: gh pr merge 가 차례로 낼 결과(ok 또는 오류 문구) — 둘 다 마지막 값이 이어짐
                # → "종료 코드|병합 호출 수|경고 수" (MERGE_ERR 는 $MG/err)
  tr ' ' '\n' <<<"$1" > "$MG/states"; shift; printf '%s\n' "$@" > "$MG/merges"; echo 0 > "$MG/mc"; echo 0 > "$MG/vc"; : > "$MG/args"
  (cd "$MG" && PATH="$MG/bin:$PATH" MG="$MG" bash -c '
    set -euo pipefail
    warns=0; log() { [[ "$1" != warn ]] || warns=$((warns + 1)); }; dim_lines() { cat >/dev/null; }
    MERGE_METHOD=squash; GH_TRIES=3; GH_RETRY_SEC=0
    source fn.sh
    rc=0; merge_pr 77 || rc=$?
    printf "%s" "$MERGE_ERR" > "$MG/err"; echo "$rc|$(cat "$MG/mc")|$warns"')
}
E502='non-200 OK status code: 502 Bad Gateway body: "bad gateway\n"'
[[ "$(merge_case OPEN ok)" == "0|1|0" && "$(cat "$MG/args")" == "pr merge 77 --squash" ]] || fail "merge_pr: 한 번에 병합되는 경우: $(merge_case OPEN ok) / $(cat "$MG/args")"
[[ "$(merge_case OPEN "$E502" ok)" == "0|2|1" ]] || fail "merge_pr: 502 한 번 뒤 다시 해 병합하지 않음(#7): $(merge_case OPEN "$E502" ok)"
[[ "$(merge_case OPEN "$E502")" == "1|3|2" && "$(cat "$MG/err")" == "$E502" ]] || fail "merge_pr: 502 가 이어지면 GH_TRIES 번 뒤 1 이어야: $(merge_case OPEN "$E502") / $(cat "$MG/err")"
[[ "$(merge_case MERGED "$E502")" == "0|1|1" ]] || fail "merge_pr: 502 를 받았지만 병합된 PR 을 다시 병합하려 함: $(merge_case MERGED "$E502")"
[[ "$(merge_case "OPEN MERGED" "$E502" "X Pull request #77 was already merged")" == "0|2|2" ]] || fail "merge_pr: 다시 해 보니 이미 병합됨을 성공으로 보지 않음"
[[ "$(merge_case OPEN "HTTP 503: Service Unavailable (https://api.github.com/graphql)" "dial tcp: lookup api.github.com: no such host" ok)" == "0|3|2" ]] \
  || fail "merge_pr: REST 5xx·네트워크 오류를 일시 장애로 보지 않음"
[[ "$(merge_case OPEN "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" ok)" == "0|2|1" ]] || fail "merge_pr: Base branch was modified 를 다시 하지 않음"
P='X Pull request #77 is not mergeable: the base branch policy prohibits the merge.'
[[ "$(merge_case OPEN "$P" ok)" == "1|1|0" && "$(cat "$MG/err")" == "$P" ]] || fail "merge_pr: 브랜치 보호 거절을 다시 함: $(merge_case OPEN "$P" ok)"
SCRIPT="$KIT/files/scripts/ticket-loop.sh"
[[ "$(grep -c 'gh pr merge "' "$SCRIPT")" == 1 ]] && grep -qF 'if ! merge_pr "${pr}"; then' "$SCRIPT" && grep -A1 -F 'if ! merge_pr "${pr}"; then' "$SCRIPT" | grep -q 'STOP_KIND=merge_failed$' \
  && grep -qF 'merge_pr "$pr" || { TRIAGE_NOTE=' "$SCRIPT" || fail "티켓 PR·수습 수정 PR 병합이 merge_pr 를 거치지 않거나 멈춤 종류가 merge_failed 가 아님"
echo "ok  병합 재시도(일시 장애만, 이미 병합됨은 성공, 브랜치 보호 거절은 바로 멈춤)"

# gh 읽기 재시도: 루프의 gh 를 감싼 함수가 읽기 호출만 일시 장애에 다시 하고, 쓰기·--watch·필드 있는 api(POST)·mutation 은 한 번만
# 부른다. 출력·종료 코드는 그대로 넘기고 다 실패하면 마지막 오류를 stderr 로 낸다. 함수는 도구 검사(command -v gh) 뒤에 있어야 한다
GW="$T/ghwrap"; mkdir -p "$GW/bin"
sed -n '/^GH_TRANSIENT_RE=/p; /^gh_read_only() {/,/^}/p; /^gh() {/,/^}/p' "$SCRIPT" > "$GW/fn.sh"
grep -q '^gh() {' "$GW/fn.sh" && grep -q '^gh_read_only() {' "$GW/fn.sh" && grep -q '^GH_TRANSIENT_RE=' "$GW/fn.sh" || fail "gh 감싸기 함수를 찾지 못함"
cat > "$GW/bin/gh" <<'GH'
#!/usr/bin/env bash
c=$(( $(cat "$GW/c") + 1 )); echo "$c" > "$GW/c"
if [[ $c -le $FAILS ]]; then printf '%s\n' "$MSG" >&2; exit 1; fi
printf 'out %s\n' "$*"; exit "$RC"
GH
chmod +x "$GW/bin/gh"
ghw_case() {  # $1 처음 실패할 횟수, $2 그 오류 문구, $3 성공 때 종료 코드, 나머지: gh 인자 → "종료 코드|호출 수|경고 수|stdout" (stderr 는 $GW/err)
  local fails="$1" msg="$2" rc="$3"; shift 3; echo 0 > "$GW/c"; : > "$GW/warns"
  (cd "$GW" && PATH="$GW/bin:$PATH" GW="$GW" FAILS="$fails" MSG="$msg" RC="$rc" bash -c '
    set -euo pipefail
    log() { [[ "$1" != warn ]] || echo x >> "$GW/warns"; }
    GH_TRIES=3; GH_RETRY_SEC=0
    source fn.sh
    rc=0; out="$(gh "$@" 2>"$GW/err")" || rc=$?
    echo "$rc|$(cat "$GW/c")|$(grep -c x "$GW/warns" || true)|$out"' _ "$@")
}
[[ "$(ghw_case 1 "$E502" 0 pr view 7 --json state)" == "0|2|1|out pr view 7 --json state" ]] || fail "gh: 읽기가 502 한 번 뒤 다시 하지 않음: $(ghw_case 1 "$E502" 0 pr view 7 --json state)"
[[ "$(ghw_case 5 "$E502" 0 pr view 7)" == "1|3|2|" ]] && grep -qF '502 Bad Gateway' "$GW/err" || fail "gh: 502 가 이어지면 GH_TRIES 번 뒤 오류를 내야: $(ghw_case 5 "$E502" 0 pr view 7) / $(cat "$GW/err")"
[[ "$(ghw_case 1 "gh: Bad Gateway (HTTP 502)" 0 api repos/o/r/issues/1 --jq .title)" == "0|2|1|out api repos/o/r/issues/1 --jq .title" ]] || fail "gh: GET api 를 다시 하지 않음"
[[ "$(ghw_case 1 "$E502" 0 api graphql -f 'query={ repository { id } }')" == "0|2|1|out api graphql -f query={ repository { id } }" ]] || fail "gh: GraphQL 조회를 다시 하지 않음"
[[ "$(ghw_case 0 "" 8 pr checks 7 --json bucket)" == "8|1|0|out pr checks 7 --json bucket" ]] || fail "gh: 종료 코드(8 대기)·출력을 그대로 넘기지 않음: $(ghw_case 0 "" 8 pr checks 7 --json bucket)"
NF='GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)'
[[ "$(ghw_case 1 "$NF" 0 pr view 7)" == "1|1|0|" ]] && grep -qF 'Could not resolve' "$GW/err" || fail "gh: 일시 장애가 아닌 오류를 다시 함"
for args in "issue comment 7 --body x" "pr merge 7 --squash" "issue close 7" "pr checks 7 --watch --fail-fast" "api repos/o/r/issues/1/comments -f body=x" "api repos/o/r/issues/1 -X PATCH"; do
  # shellcheck disable=SC2086
  [[ "$(ghw_case 1 "$E502" 0 $args)" == "1|1|0|" ]] || fail "gh: 쓰기·--watch·POST api 를 다시 함($args): $(ghw_case 1 "$E502" 0 $args)"
done
[[ "$(ghw_case 1 "$E502" 0 api graphql -f 'query=mutation { x }')" == "1|1|0|" ]] || fail "gh: GraphQL mutation 을 다시 함"
[[ "$(grep -n '^for tool in gh jq git; do' "$SCRIPT" | cut -d: -f1)" -lt "$(grep -n '^gh() {' "$SCRIPT" | cut -d: -f1)" ]] || fail "gh 함수가 도구 검사보다 먼저 정의됨(gh 가 없어도 검사를 통과한다)"
grep -qF 'branch="$(gh pr view "${pr}" --json headRefName -q .headRefName || true)"' "$SCRIPT" && grep -qF '[[ -z "$branch" ]] || git -C "$ROOT" push -q origin --delete "${branch}"' "$SCRIPT" \
  || fail "병합 뒤 브랜치 조회가 실패하면 멈추거나 빈 이름으로 지움"
echo "ok  gh 읽기 재시도(읽기만 — 쓰기·--watch·POST api·mutation 은 한 번, 출력·종료 코드 그대로)·병합 뒤 브랜치 조회 실패에 멈추지 않음"

# CI 대기: --watch 는 API 오류 한 번에도 1 이다(체크 실패와 같은 코드). 1 이면 체크 상태를 다시 읽어 실패·취소가 있을 때만 실패, 다 통과면
# 통과, 도는 체크가 있으면 GH_TRIES 번까지 다시 본다. 못 읽으면 전처럼 실패
sed -n '/^ci_passed() {/,/^}/p; /^wait_checks_appear() {/,/^}/p; /^bg_wait() {/,/^}/p' "$SCRIPT" > "$GW/ci.sh"
grep -q '^ci_passed() {' "$GW/ci.sh" && grep -q '^bg_wait() {' "$GW/ci.sh" || fail "ci_passed·bg_wait 를 찾지 못함"
cat > "$GW/bin/gh" <<'GH'
#!/usr/bin/env bash
case " $* " in
  *" --watch "*) c=$(( $(cat "$GW/w") + 1 )); echo "$c" > "$GW/w"; set -- $WATCH; i=$c; [[ $i -le $# ]] || i=$#; exit "${!i}" ;;
  *" bucket "*) printf '%s\n' "$BUCKETS" ;;
  *" name "*) echo 1 ;;
esac
GH
ci2_case() {  # $1 --watch 가 차례로 낼 종료 코드(공백, 마지막 값이 이어짐), $2 체크 상태(bucket) → "종료 코드|watch 횟수|경고 수"
  echo 0 > "$GW/w"; : > "$GW/warns"
  (cd "$GW" && PATH="$GW/bin:$PATH" GW="$GW" WATCH="$1" BUCKETS="$2" bash -c '
    set -euo pipefail
    log() { [[ "$1" != warn ]] || echo x >> "$GW/warns"; }
    GH_TRIES=3; CI_APPEAR_TIMEOUT_SEC=5; BG_PID=""
    source ci.sh
    rc=0; ci_passed 7 || rc=$?
    echo "$rc|$(cat "$GW/w")|$(grep -c x "$GW/warns" || true)"')
}
[[ "$(ci2_case 0 "")" == "0|1|0" ]] || fail "ci_passed: 통과한 watch: $(ci2_case 0 "")"
[[ "$(ci2_case 1 "fail pass")" == "1|1|0" && "$(ci2_case 1 "cancel pass")" == "1|1|0" ]] || fail "ci_passed: 실패·취소한 체크가 있는데 실패가 아님"
[[ "$(ci2_case 1 "pass skipping")" == "0|1|1" ]] || fail "ci_passed: watch 는 1 이지만 다 통과했는데 실패로 봄: $(ci2_case 1 "pass skipping")"
[[ "$(ci2_case "1 0" "pass pending")" == "0|2|1" ]] || fail "ci_passed: 도는 체크가 있는데 다시 보지 않음: $(ci2_case "1 0" "pass pending")"
[[ "$(ci2_case 1 "pending")" == "1|3|2" ]] || fail "ci_passed: GH_TRIES 번 뒤에도 끝내지 않음: $(ci2_case 1 pending)"
[[ "$(ci2_case 1 "")" == "1|1|0" ]] || fail "ci_passed: 체크 상태를 못 읽으면 실패여야: $(ci2_case 1 "")"
echo "ok  CI 대기(--watch 가 1 이면 체크 상태를 다시 읽어 실패가 있을 때만 실패)"

# 수리 끝 알아채기: idle 이 끝내 안 잡혀도(cmux lifecycle 공백) 새 커밋이 push 돼 REPAIR_SETTLE_SEC 동안 그대로이고 워크트리가 깨끗하면 끝.
# 커밋이 없거나 워크트리가 더러우면 제한 시간까지 기다린다(1). idle 이 잡히면 새 커밋이 있을 때 바로 끝(0), 새 커밋이 아직 없으면 화면이
# 그대로인 idle 을 IDLE_STRIKES 번 연달아 볼 때만 끝(호출부가 "새 커밋 없음"으로 멈춘다) — 2026-10-20 rental-portal #251 에서 수리
# 프롬프트 직후의 묵은 idle 하나로 5초 만에 멈췄고 워커는 2분 뒤 push 했다
repair_case() {  # $1 수리 뒤 head(공백으로 가른 차례, 마지막 값이 이어짐), $2 커밋 안 된 파일(빈 값이면 깨끗), $3 terminal_idle 종료 코드,
                 # $4 terminal_tail 화면(차례, 마지막 값이 이어짐) → "종료 코드|경고 줄 수"
  (cd "$W" && W="$W" NEWHEAD="$1" DIRTY="$2" IRC="$3" SCREENS="${4:-same}" HC="$W/hc" TC="$W/tc" bash -c '
    set -euo pipefail
    echo 0 > "$HC"; echo 0 > "$TC"; warns="$W/warns"; : > "$warns"
    nth() { local i="$1"; shift; [[ $i -le $# ]] || i=$#; echo "${!i}"; }   # $1 번째 값(넘치면 마지막)
    send_prompt() { :; }; progress_check() { :; }; die() { echo "die $*"; exit 9; }; idle_wait_ms() { echo 1; }
    terminal_idle() { sleep 0.05; return "$IRC"; }
    terminal_tail() { local c; c=$(( $(cat "$TC") + 1 )); echo "$c" > "$TC"; nth "$c" $SCREENS; }
    pr_head_sha() { local c; c=$(( $(cat "$HC") + 1 )); echo "$c" > "$HC"; [[ $c -eq 1 ]] && echo aaa1111 || nth $(( c - 1 )) $NEWHEAD; }
    progress_dirty() { printf "%s" "$DIRTY"; }
    log() { [[ "$1" != warn ]] || echo x >> "$warns"; }
    PROGRESS_SEC=0; REPAIR_SETTLE_SEC=0; CUR_N=7; BACKEND_NAME=x; IDLE_STRIKES=3; IDLE_RECHECK_SEC=0
    source fn.sh
    rc=0; repair h "고쳐라" $(( $(date +%s) + 2 )) 77 || rc=$?
    echo "$rc|$(grep -c x "$warns" || true)"')
}
[[ "$(repair_case bbb2222 "" 1)" == "0|1" ]] || fail "repair: 새 커밋이 그대로이고 워크트리가 깨끗한데 끝내지 않음: $(repair_case bbb2222 "" 1)"
[[ "$(repair_case aaa1111 "" 1)" == "1|0" ]] || fail "repair: 새 커밋이 없는데 끝냄: $(repair_case aaa1111 "" 1)"
[[ "$(repair_case bbb2222 "a.ts" 1)" == "1|0" ]] || fail "repair: 커밋 안 된 변경이 있는데 끝냄: $(repair_case bbb2222 a.ts 1)"
[[ "$(repair_case bbb2222 "" 0)" == "0|0" ]] || fail "repair: idle 이고 새 커밋이 있는데 바로 끝내지 않음: $(repair_case bbb2222 "" 0)"
[[ "$(repair_case aaa1111 "" 0)" == "0|3" ]] || fail "repair: 새 커밋 없는 idle 을 IDLE_STRIKES 번 보고 끝내지 않음: $(repair_case aaa1111 "" 0)"
[[ "$(repair_case "aaa1111 bbb2222" "" 0)" == "0|1" ]] || fail "repair: 묵은 idle 뒤 들어온 커밋으로 끝내지 않음(#251): $(repair_case "aaa1111 bbb2222" "" 0)"
[[ "$(repair_case aaa1111 "" 0 "s1 s2")" == "0|4" ]] || fail "repair: 화면이 바뀌면 idle 을 처음부터 세야: $(repair_case aaa1111 "" 0 "s1 s2")"
grep -q 'repair "${handle}" "PR #${pr} 이 ${BASE_BRANCH}과 충돌한다.* "$deadline" "${pr}"' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -q 'repair "${handle}" "PR #${pr} 의 CI가 실패했다.* "$deadline" "${pr}"' "$KIT/files/scripts/ticket-loop.sh" || fail "수리 두 곳이 PR 번호를 넘기지 않음"
echo "ok  수리 끝 알아채기(idle 없이 새 커밋, 새 커밋 없는 idle 은 연달아 볼 때만)"

# CI 수리(repair_ci): 수리 뒤 head 가 바뀌면 0(충돌·CI 확인부터 다시), 그대로면 CI 를 한 번 더 보고 통과면 0, 실패면 1(호출부가 멈춘다).
# 2026-10-21 rental-portal #258: 러너 설치 경합으로 실패한 job 을 워커가 `gh run rerun --failed` 로만 다시 돌려 1분 뒤 통과했는데,
# 0.9.4 까지는 head 가 그대로라 "no new commit was pushed after the repair" 로 멈췄다
sed -n '/^repair_ci() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$W/rci.sh"
grep -q '^repair_ci() {' "$W/rci.sh" || fail "repair_ci 를 찾지 못함"
rci_case() {  # $1 수리 뒤 head(수리 전은 aaa1111), $2 ci_passed 종료 코드, $3 repair 종료 코드 → "종료 코드|ci_passed 호출 수|경고 수|단계(빈 단계는 _)"
  (cd "$W" && NEWHEAD="$1" CRC="$2" RRC="${3:-0}" HC="$W/rhc" bash -c '
    set -euo pipefail
    echo 0 > "$HC"; n_ci=0; warns=0; phases=""
    phase() { phases+="${1:-_} "; }
    repair() { [[ "$1" == h && "$4" == 77 ]] || { echo "repair args: $*"; exit 8; }; return "$RRC"; }
    pr_head_sha() { local c; c=$(( $(cat "$HC") + 1 )); echo "$c" > "$HC"; [[ "$1" == 77 ]] || exit 8; [[ $c -eq 1 ]] && echo aaa1111 || echo "$NEWHEAD"; }
    ci_passed() { [[ "$1" == 77 ]] || exit 8; n_ci=$((n_ci + 1)); return "$CRC"; }
    log() { [[ "$1" != warn ]] || warns=$((warns + 1)); }
    die() { echo "die $*"; exit 9; }
    source rci.sh
    rc=0; repair_ci 7 77 h $(( $(date +%s) + 60 )) || rc=$?
    echo "$rc|$n_ci|$warns|${phases% }"')
}
[[ "$(rci_case bbb2222 1)" == "0|0|0|repair _" ]] || fail "repair_ci: 새 커밋이 있으면 CI 를 다시 보지 않고 0 이어야: $(rci_case bbb2222 1)"
[[ "$(rci_case aaa1111 0)" == "0|1|1|repair _ ci _" ]] || fail "repair_ci: 새 커밋 없이 CI 가 통과(재실행만 한 수리)했는데 계속하지 않음(#258): $(rci_case aaa1111 0)"
[[ "$(rci_case aaa1111 1)" == "1|1|1|repair _ ci _" ]] || fail "repair_ci: 새 커밋도 없고 CI 도 실패인데 멈춤(1)이 아님: $(rci_case aaa1111 1)"
out="$(rci_case aaa1111 0 1 || true)"; [[ "$out" == "die #7: timed out while repairing CI" ]] || fail "repair_ci: 수리 제한 시간이면 멈춰야: $out"
grep -q 'if ! repair_ci "${n}" "${pr}" "${handle}" "$deadline"; then' "$KIT/files/scripts/ticket-loop.sh" \
  && grep -qF 'reason="#${n}: no new commit was pushed after the repair, and CI still fails"' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "CI 수리 호출부가 repair_ci 의 1 에서만 멈추지 않음"
! grep -q 'before="$(pr_head_sha "${pr}")"' <(sed -n '/^run_ticket() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh") || fail "run_ticket 이 아직 head 비교만으로 수리 결과를 가른다"
grep -q 'repair "${handle}" "PR #${pr} 의 CI가 실패했다.*코드와 무관하면 코드를 바꾸지 말고 \\`gh run rerun <run-id> --failed\\` 로 실패한 job만 다시 돌려라(push할 커밋이 없어도 된다)' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "CI 수리 프롬프트에 러너·네트워크 오류면 재실행만 하라는 안내가 없음"
echo "ok  CI 수리 뒤 새 커밋이 없으면 CI 를 다시 봄(재실행만 한 수리는 통과면 계속, 실패면 멈춤)"

# 기록: PR 을 알아채기까지(pr_pickup_sec) — 값이 있을 때만
sed -n '/^idle_fp_count() /p; /^record_ticket() {/,/^}/p; /^PH_NAME=/p; /^phase() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" > "$W/rec.sh"
sed -n '/^claude_project_dir() /p; /^ticket_session_dirs() {/,/^}/p; /^session_tokens() {/,/^}/p; /^report_tokens() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" >> "$W/rec.sh"
grep -q '^session_tokens() {' "$W/rec.sh" && grep -q '^report_tokens() {' "$W/rec.sh" || fail "토큰 함수(session_tokens·report_tokens)를 찾지 못함"
rec_case() {  # $1 CUR_PICKUP_SEC, [$2 source 뒤 덧붙일 설정] → 기록 한 줄
  (cd "$W" && P="$1" EXTRA="${2:-}" bash -c '
    set -euo pipefail
    spec_of_ticket() { echo 40; }; log() { :; }
    source rec.sh
    ROOT=/x; LOG_FILE=/x/.ticket-loop/loop.log; RECORDS_FILE="$PWD/rec.jsonl"; : > "$RECORDS_FILE"
    CUR_N=7; CUR_TITLE=t; CUR_PR=77; CUR_STARTED_ISO=s; CUR_STARTED=$(date +%s); CUR_CI_SEC=246; CUR_ROUND=0; CUR_MODEL=""; AGENT=claude; CUR_PICKUP_SEC="$P"
    CLAUDE_CONFIG_DIR="$PWD/no-claude"   # 사용자 세션 기록을 읽지 않게
    eval "$EXTRA"
    record_ticket merged; cat "$RECORDS_FILE"')
}
[[ "$(rec_case 638 | jq -c '[.pr_pickup_sec, .ci_sec]')" == "[638,246]" ]] || fail "기록에 pr_pickup_sec 가 없음: $(rec_case 638)"
[[ "$(rec_case "" | jq 'has("pr_pickup_sec")')" == false ]] || fail "PR 을 못 찾은 기록에 pr_pickup_sec 가 있음"
[[ "$(rec_case "" | jq -r .log)" == .ticket-loop/loop.log ]] || fail "기록에 이 실행의 로그(저장소 루트 기준)가 없음: $(rec_case "")"
[[ "$(rec_case "" | jq 'has("post_merge")')" == false ]] || fail "병합 뒤 검증을 정하지 않은 기록에 post_merge 가 있음"
grep -q 'summary: wall-clock .*PR #${pr}${CUR_PICKUP_SEC:+ (picked up after ${CUR_PICKUP_SEC}s)}' "$KIT/files/scripts/ticket-loop.sh" || fail "요약 줄에 PR 을 알아채기까지가 없음"
echo "ok  PR 을 알아채기까지(요약·기록)"

# 단계별 시간(구현·수리·CI·병합 뒤 검증): phase 는 지금 단계를 닫고 새 단계를 연다. 시각을 주면 그때로(PR 생성 시각으로 구현을 닫고
# 첫 CI 를 연다), 지금 단계가 시작된 때보다 이르면 그때로 당긴다(겹쳐 세지 않는다). 빈 단계는 세지 않는다
out="$(cd "$W" && bash -c 'set -euo pipefail; source rec.sh; PH_AT=1000
  phase impl 1010; phase "" 1100; phase ci 1100; phase "" 1150   # 구현 90(PR 1100에 열림), 첫 CI 는 PR 이 열린 때부터 50
  phase repair 1160; phase "" 1200; phase ci 1190; phase "" 1250  # 수리 40, 수리 뒤 CI 는 1190 을 1200 으로 당겨 50
  phase post 1300; phase "" 1340; phase impl 1400; phase "" 1390  # 검증 40, 거꾸로 간 시각은 0
  echo "$PH_IMPL $PH_REPAIR $PH_CI $PH_POST ${PH_NAME:-_} $PH_AT"')" || fail "phase 실행 실패: $out"
[[ "$out" == "90 40 100 40 _ 1400" ]] || fail "phase 단계 시간이 다름(구현 수리 CI 검증 단계 시각): $out"
# 기록: 네 값을 늘 남기고, 열린 단계(멈춘 때의 CI 등)는 기록하는 시각에 닫는다
rec="$(rec_case "" 'PH_IMPL=1800; PH_REPAIR=300; PH_CI=400; PH_POST=2700; PH_NAME=ci; PH_AT=$(( $(date +%s) - 20 ))')"
jq -e '.impl_sec == 1800 and .repair_sec == 300 and .ci_wait_sec >= 420 and .ci_wait_sec < 480 and .post_merge_sec == 2700' <<<"$rec" >/dev/null || fail "기록의 단계별 시간이 다름(열린 CI 단계를 닫아야): $rec"
[[ "$(rec_case "" | jq -c '[.impl_sec, .repair_sec, .ci_wait_sec, .post_merge_sec]')" == "[0,0,0,0]" ]] || fail "단계를 지나지 않은 기록의 단계별 시간이 0 이 아님: $(rec_case "")"
# run_ticket·repair 자리: 에이전트가 뜨면 구현, PR 생성 시각에 구현을 닫고 첫 CI 는 그 시각부터, 충돌 수리는 수리, PR 없이 멈추면
# 수습 전에 구현을 닫는다. 티켓마다 비운다
RT="$(sed -n '/^run_ticket() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh")"
grep -A1 '^  ensure_agent_started "${n}" "${handle}"$' <<<"$RT" | grep -qx '  phase impl' \
  && grep -qxF '  phase "" "$created"   # 구현은 PR이 열린 때까지(GitHub 시각)' <<<"$RT" \
  && grep -qF 'local round=0 state ci_from="$created"' <<<"$RT" \
  && grep -qF '    phase ci "$ci_from"; ci_from=""' <<<"$RT" \
  && grep -A1 '^    if ci_passed "${pr}"; then$' <<<"$RT" | grep -qx '      phase ""' \
  && grep -B1 'repair "${handle}" "PR #${pr} 이 ${BASE_BRANCH}과 충돌한다' <<<"$RT" | grep -qx '      phase repair' \
  && grep -A1 '^  if \[\[ $rc -ne 0 \]\]; then$' <<<"$RT" | grep -q '^    phase ""' \
  && grep -qxF '  PH_NAME=""; PH_AT="$started_at"; PH_IMPL=0; PH_REPAIR=0; PH_CI=0; PH_POST=0' <<<"$RT" \
  && sed -n '/^record_ticket() {/,/^}/p' "$KIT/files/scripts/ticket-loop.sh" | grep -q '^  phase ""' \
  || fail "run_ticket·record_ticket 의 단계 전환 자리가 다름"
echo "ok  단계별 시간(구현·수리·CI·병합 뒤 검증 — phase·기록·전환 자리)"

# 토큰: Claude Code 세션 기록(가짜 CLAUDE_CONFIG_DIR)에서 워커·서브에이전트·무인 수습 세션의 응답 usage 를 더한다. 같은 응답의 줄(같은
# message.id)은 한 번, 시작 시각 앞(앞선 시도)·끝 시각 뒤는 빼고, 다른 티켓(issue-70, loop-triage-70-…)은 넣지 않는다. 깨진 줄은 건너뛴다
TK="$W/tok"; WTD=/wt/o-r/worktrees; enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
u() { printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$@"; }
mkdir -p "$TK/projects/$(enc "$WTD/issue-7")/s1/subagents" "$TK/projects/$(enc "$WTD/loop-triage-7-120000")" "$TK/projects/$(enc "$WTD/issue-70")" \
  "$TK/projects/$(enc "$WTD/loop-triage-70-120000")" "$TK/projects/$(enc /orca/ws/issue-7)"
{ u 2026-10-21T09:00:00.000Z m0 1000 1000 1000 1000   # 앞선 시도
  u 2026-10-21T10:00:01.000Z m1 1 10 100 1000; u 2026-10-21T10:00:01.500Z m1 1 10 100 1000   # 내용 블록 둘 — 한 번만
  echo '{"type":"user","timestamp":"2026-10-21T10:00:02Z","message":{"role":"user","content":"x"}}'; echo 'not json {'
  u 2026-10-21T10:30:00.000Z m2 2 20 200 2000
  u 2026-10-21T13:00:00.000Z m9 5000 5000 5000 5000; } > "$TK/projects/$(enc "$WTD/issue-7")/s1.jsonl"   # 끝 뒤(사람이 이어 씀)
u 2026-10-21T10:10:00.000Z m3 3 30 300 3000 > "$TK/projects/$(enc "$WTD/issue-7")/s1/subagents/agent-a.jsonl"
u 2026-10-21T11:00:00.000Z m4 4 40 400 4000 > "$TK/projects/$(enc "$WTD/loop-triage-7-120000")/t.jsonl"
u 2026-10-21T10:20:00.000Z m5 50 500 5000 50000 > "$TK/projects/$(enc /orca/ws/issue-7)/o.jsonl"
u 2026-10-21T10:20:00.000Z x1 9 9 9 9 > "$TK/projects/$(enc "$WTD/issue-70")/a.jsonl"; u 2026-10-21T10:20:00.000Z x2 9 9 9 9 > "$TK/projects/$(enc "$WTD/loop-triage-70-120000")/b.jsonl"
tok() { (cd "$W" && CLAUDE_CONFIG_DIR="$TK" WORKTREE_DIR="$WTD" BRANCH_PREFIX=issue- A="$1" B="$2" X="${3:-}" bash -c 'set -euo pipefail; source rec.sh; ticket_session_dirs 7 $X | session_tokens "$A" "$B"'); }
[[ "$(tok 2026-10-21T09:30:00Z 2026-10-21T12:00:00Z)" == '{"input":10,"output":100,"cache_write":1000,"cache_read":10000}' ]] || fail "토큰 합이 다름(워커·서브에이전트·수습, 중복·시간 밖·다른 티켓 제외): $(tok 2026-10-21T09:30:00Z 2026-10-21T12:00:00Z)"
[[ "$(tok 2026-10-21T09:30:00Z 2026-10-21T12:00:00Z /orca/ws/issue-7 | jq -c '[.input, .output]')" == "[60,600]" ]] || fail "WORKTREE_DIR 밖 작업 폴더(Orca)의 세션 기록을 더하지 않음"
[[ -z "$(tok 2026-10-22T00:00:00Z "")" ]] || fail "응답이 없으면 토큰은 빈 값이어야 함: $(tok 2026-10-22T00:00:00Z "")"
# 기록: 이 티켓의 작업 폴더(CUR_AGENT_PATHS)와 시작 시각부터 지금까지. Codex 와 세션 기록이 없을 때는 tokens 를 남기지 않는다
rec="$(rec_case "" "CLAUDE_CONFIG_DIR='$TK'; WORKTREE_DIR='$WTD'; BRANCH_PREFIX=issue-; CUR_STARTED_ISO=2026-10-21T09:30:00Z; CUR_AGENT_PATHS=\$'$WTD/issue-7\\n/orca/ws/issue-7\\n'")"
[[ "$(jq -c .tokens <<<"$rec")" == '{"input":5060,"output":5600,"cache_write":11000,"cache_read":65000}' ]] || fail "기록의 tokens 가 다름(끝 시각 없이 지금까지): $rec"
[[ "$(rec_case "" "CLAUDE_CONFIG_DIR='$TK'; WORKTREE_DIR='$WTD'; BRANCH_PREFIX=issue-; CUR_STARTED_ISO=2026-10-21T09:30:00Z; AGENT=codex" | jq 'has("tokens")')" == false ]] || fail "Codex 기록에 tokens 가 있음"
[[ "$(rec_case "" | jq 'has("tokens")')" == false ]] || fail "세션 기록이 없는데 tokens 가 있음"
# 리포트: tokens 가 없는 기록만 그 기록의 시작~끝으로 메운다(Codex·이미 있는 값은 그대로, WORKTREE_DIR 이 없으면 아무것도)
recs='[{"issue":7,"agent":"claude","started":"2026-10-21T09:30:00Z","finished":"2026-10-21T12:00:00Z"},{"issue":7,"agent":"codex","started":"2026-10-21T09:30:00Z","finished":"2026-10-21T12:00:00Z"},{"issue":7,"started":"2026-10-21T09:30:00Z","finished":"2026-10-21T12:00:00Z","tokens":{"input":1,"output":1,"cache_write":1,"cache_read":1}}]'
out="$(cd "$W" && CLAUDE_CONFIG_DIR="$TK" WORKTREE_DIR="$WTD" BRANCH_PREFIX=issue- R="$recs" bash -c 'set -euo pipefail; source rec.sh; report_tokens <<<"$R"')"
[[ "$(jq -c '[.[].tokens.output]' <<<"$out")" == "[100,null,1]" ]] || fail "report_tokens 가 다름: $out"
[[ "$(cd "$W" && CLAUDE_CONFIG_DIR="$TK" R="$recs" bash -c 'set -euo pipefail; source rec.sh; report_tokens <<<"$R"' | jq -c '[.[].tokens.output]')" == "[null,null,1]" ]] || fail "WORKTREE_DIR 없이 report_tokens 가 메움"
grep -qF "map(select(.spec == \$spec))' | report_tokens)\"" "$KIT/files/scripts/ticket-loop.sh" && grep -qF 'CUR_AGENT_PATHS+="${wt_path}"' "$KIT/files/scripts/ticket-loop.sh" && grep -qF 'CUR_AGENT_PATHS+="${t_path}"' "$KIT/files/scripts/ticket-loop.sh" \
  || fail "리포트가 report_tokens 를 거치지 않거나, 워커·수습 작업 폴더를 CUR_AGENT_PATHS 에 넣지 않음"
echo "ok  티켓 토큰(세션 기록 합·중복·시간 창·수습 세션·기록·리포트 메우기)"

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
                     {"number":4,"title":"T05: 다섯","state":"open","url":"https://x/4","assignees":0},
                     {"number":45,"title":"T06: 여섯","state":"closed","url":"https://x/45","assignees":0},
                     {"number":46,"title":"T07: 일곱","state":"closed","url":"https://x/46","assignees":0},
                     {"number":47,"title":"T08: 여덟","state":"closed","url":"https://x/47","assignees":0},
                     {"number":48,"title":"T09: 아홉","state":"closed","url":"https://x/48","assignees":0}]' \
  --argjson prs '[{"number":50,"title":"T01 PR","body":"- [x] a\n- [ ] b","state":"MERGED","url":"https://x/p50","createdAt":"2026-10-12T00:20:00Z","mergedAt":"2026-10-12T00:30:00Z","headRefName":"issue-41-one"},
                  {"number":51,"title":"T03 PR","body":"","state":"MERGED","url":"https://x/p51","createdAt":"2026-10-11T00:40:00Z","mergedAt":"2026-10-11T01:00:00Z","headRefName":"issue-43-three"},
                  {"number":52,"title":"T04 PR","body":"","state":"MERGED","url":"https://x/p52","createdAt":"2026-10-11T02:00:00Z","mergedAt":"2026-10-11T03:00:00Z","headRefName":"issue-44"},
                  {"number":53,"title":"T06 PR","body":"","state":"MERGED","url":"https://x/p53","createdAt":"2026-10-12T01:50:00Z","mergedAt":"2026-10-12T03:30:00Z","headRefName":"issue-45-six"},
                  {"number":54,"title":"T07 PR","body":"","state":"MERGED","url":"https://x/p54","createdAt":"2026-10-12T04:00:00Z","mergedAt":"2026-10-12T04:10:00Z","headRefName":"issue-46-seven"},
                  {"number":55,"title":"T08 PR","body":"","state":"MERGED","url":"https://x/p55","createdAt":"2026-10-13T00:40:00Z","mergedAt":"2026-10-13T00:50:00Z","headRefName":"issue-47-eight"},
                  {"number":56,"title":"T09 PR","body":"","state":"MERGED","url":"https://x/p56","createdAt":"2026-10-13T02:10:00Z","mergedAt":"2026-10-13T02:11:00Z","headRefName":"issue-48-nine"}]' \
  --argjson recs '[{"spec":40,"issue":41,"title":"T01: 하나","result":"merged","started":"2026-10-12T00:00:00Z","finished":"2026-10-12T00:31:00Z","wall_sec":1860,"repairs":1,"idle_false_positives":0,"agent":"claude","pr":50,"ci_sec":200,"post_merge":"통과 90초","model":"Opus 5.5"},
                   {"spec":40,"issue":42,"title":"T02: 둘","result":"stopped","reason":"워커가 PR 없이 멈췄습니다","started":"2026-10-12T01:00:00Z","finished":"2026-10-12T01:10:00Z","wall_sec":600,"repairs":0,"idle_false_positives":2,"agent":"claude"},
                   {"spec":40,"issue":43,"title":"T03: 셋","result":"merged","started":"2026-10-11T00:00:00Z","finished":"2026-10-11T01:01:00Z","wall_sec":3660,"repairs":0,"idle_false_positives":0,"agent":"claude","pr":51,"ci_sec":100,"post_merge":"failed in 12s","model":"Opus 5.5"},
                   {"spec":40,"issue":44,"title":"T04: 넷","result":"merged","started":"2026-10-11T02:00:00Z","finished":"2026-10-11T03:01:00Z","wall_sec":3660,"repairs":0,"idle_false_positives":0,"agent":"claude","pr":52,"ci_sec":100,"post_merge":"passed on retry in 300s (first run failed in 2640s)","model":"Opus 5.5","triage":"resumed (project, fix PR #131 merged): 기대값 <열> 맞춤"},
                   {"spec":40,"issue":45,"title":"T06: 여섯","result":"stopped","reason":"수리 뒤 새 커밋 없음","started":"2026-10-12T01:00:00Z","finished":"2026-10-12T02:00:00Z","wall_sec":3600,"repairs":1,"idle_false_positives":0,"agent":"claude","pr":53,"post_merge":"skipped","model":"Opus 5.5"},
                   {"spec":40,"issue":46,"title":"T07: 일곱","result":"stopped","reason":"정리 중 예기치 않은 종료","started":"2026-10-12T03:50:00Z","finished":"2026-10-12T04:20:00Z","wall_sec":1800,"repairs":0,"idle_false_positives":0,"agent":"claude","pr":54,"ci_sec":60,"post_merge":"passed in 30s","model":"Opus 5.5"},
                   {"spec":40,"issue":47,"title":"T08: 여덟","result":"merged","started":"2026-10-13T00:00:00Z","finished":"2026-10-13T01:30:00Z","wall_sec":5400,"impl_sec":1800,"repair_sec":300,"ci_wait_sec":420,"post_merge_sec":2700,"repairs":1,"idle_false_positives":0,"agent":"claude","pr":55,"ci_sec":400,"post_merge":"passed in 2700s","model":"Opus 5.5","tokens":{"input":2000,"output":222000,"cache_write":826000,"cache_read":83300000}},
                   {"spec":40,"issue":48,"title":"T09: 아홉","result":"merged","started":"2026-10-13T02:00:00Z","finished":"2026-10-13T02:11:40Z","wall_sec":700,"impl_sec":600,"repair_sec":0,"ci_wait_sec":0,"post_merge_sec":0,"repairs":0,"idle_false_positives":0,"agent":"claude","pr":56,"ci_sec":-1,"post_merge":"skipped","model":"Opus 5.5","tokens":{"input":500,"output":900,"cache_write":0,"cache_read":0}}]' \
  "$REPORT_JQ" > "$T/report.html" || fail "스펙 리포트 jq 실패"
for want in '<!doctype html>' '<html lang="en">' 'PR #50' 'Acceptance criteria 1/2' '>Merged<' '>Stopped<' 'Stop reason: 워커가 PR 없이 멈췄습니다' 'Opus 5.5' 'PR created→merged' 'not recorded' '1 repair · post-merge check passed</div>' '0 repairs · post-merge check failed</div>' 'post-merge check passed on retry (first run failed) · triage' 'triage resumed (project, fix PR #131 merged): 기대값 &lt;열&gt; 맞춤' 'T01: 하나'; do
  grep -qF "$want" "$T/report.html" || fail "스펙 리포트에 '$want' 없음"
done
# head 가 정확히 issue-44 인 PR #52 는 T04 의 PR 이고(Merged 3건), 이슈 4 에는 붙지 않는다(기록도 PR 도 없는 이슈 4 는 Not started)
[[ "$(grep -o 'PR #52' "$T/report.html" | wc -l | tr -d ' ')" == "1" ]] || fail "스펙 리포트: head 가 issue-44 인 PR #52 가 한 번 나와야 함"
[[ "$(grep -o 'badge ok">Merged<' "$T/report.html" | wc -l | tr -d ' ')" == "6" ]] || fail "스펙 리포트: Merged 배지가 6건(41·43·44·46·47·48)이어야 함"
grep -qF '<div class="v">7</div><div class="l">Merged</div>' "$T/report.html" || fail "스펙 리포트: KPI Merged 가 7(멈춘 뒤 병합 포함)여야 함"
# 멈춘 뒤 루프 밖에서 병합된 티켓(#45): 배지·멈춘 사유·멈춘 뒤 병합까지 걸린 시간, 경과는 멈출 때까지라고 밝히고, 마친 시각은 병합 시각.
# 0.9.6까지 멈춘 기록에 남던 post_merge "skipped"는 그리지 않는다. 루프가 병합하고 나서 멈춘 티켓(#46)은 Merged 에 멈춘 사유를 단다
row45="$(grep -F 'https://x/45"' "$T/report.html")"; row46="$(grep -F 'https://x/46"' "$T/report.html")"
for want in 'badge warn">Merged after stop<' 'Stop reason: 수리 뒤 새 커밋 없음' '1 repair · merged outside the loop 1h 30m after the stop' '1h 0m<div class="muted small">loop, until the stop</div>'; do
  grep -qF "$want" <<<"$row45" || fail "스펙 리포트: 멈춘 뒤 병합된 행에 '$want' 없음: $row45"
done
! grep -q 'post-merge check skipped' <<<"$row45" || fail "스펙 리포트: 병합 전에 멈춘 기록의 post_merge skipped 를 그림: $row45"
grep -qF "$(jq -rn '"2026-10-12T03:30:00Z" | fromdate | strflocaltime("%Y-%m-%d<br>%H:%M")')" <<<"$row45" || fail "스펙 리포트: 멈춘 뒤 병합된 행의 마친 시각이 병합 시각이 아님: $row45"
grep -qF 'badge ok">Merged<' <<<"$row46" && grep -qF 'Stop reason: 정리 중 예기치 않은 종료' <<<"$row46" && grep -qF 'post-merge check passed</div>' <<<"$row46" && ! grep -q 'after the stop' <<<"$row46" \
  || fail "스펙 리포트: 루프가 병합한 뒤 멈춘 행이 다름: $row46"
[[ "$(grep -o 'badge muted">Not started<' "$T/report.html" | wc -l | tr -d ' ')" == "1" ]] || fail "스펙 리포트: 이슈 4 가 Not started 여야 함(issue-44 PR 이 #4 에 붙음?)"
# 구현·CI·병합 뒤 검증 열과 경과 막대. 0.9.8 기록(#47·#48)은 단계별 시간 그대로(구현에 수리 포함), 지난 기록은 어림한다: 구현은 PR 생성
# 시각 − 시작(수리가 있었으면 "excl. repairs", PR 생성이 시작과 같으면 —), PR 없이 멈춘 기록은 경과 전부, CI 는 ci_sec(수리가 있었으면
# "last run only"), 병합 뒤 검증은 결과 문자열의 초를 더한 값. 결과 브리프에는 걸린 시간을 다시 적지 않는다
cells() { grep -F "https://x/$1\"" "$T/report.html"; }
for pair in \
  '47|<td class="nw">35m<div class="muted small">incl. repair 5m</div></td><td class="nw">7m</td><td class="nw">45m</td><td class="nw">1h 30m<div class="bar" title="implementation 35m · CI 7m · post-merge check 45m · other 3m"><i class="s-impl" style="width:38.8%"></i><i class="s-ci" style="width:7.7%"></i><i class="s-post" style="width:50%"></i></div><div class="muted small">other 3m</div></td>' \
  '48|<td class="nw">10m</td><td class="nw">none<div class="muted small">path excluded</div></td><td class="nw">—</td><td class="nw">11m<div class="bar"' \
  '41|<td class="nw">20m<div class="muted small">excl. repairs</div></td><td class="nw">3m<div class="muted small">last run only</div></td><td class="nw">1m</td>' \
  '42|<td class="nw">10m</td><td class="nw">—</td><td class="nw">—</td>' \
  '43|<td class="nw">40m</td><td class="nw">1m</td><td class="nw">12s</td><td class="nw">1h 1m<div class="bar"' \
  '44|<td class="nw">—</td><td class="nw">1m</td><td class="nw">49m</td>' \
  '45|<td class="nw">50m<div class="muted small">excl. repairs</div></td><td class="nw">—</td><td class="nw">—</td><td class="nw">1h 0m<div class="muted small">loop, until the stop</div><div class="bar" title="implementation 50m · other 10m">' \
  '4|<td class="nw">—</td><td class="nw">—</td><td class="nw">—</td><td class="nw">—</td>'; do
  grep -qF "${pair#*|}" <<<"$(cells "${pair%%|*}")" || fail "스펙 리포트: #${pair%%|*} 행의 단계 열이 다름: $(cells "${pair%%|*}")"
done
grep -qF 'post-merge check skipped' <<<"$(cells 48)" && ! grep -q 'class="bar"' <<<"$(cells 4)" || fail "스펙 리포트: CI 없는 PR 의 검증 건너뜀이 없거나 기록 없는 행에 막대가 있음"
! grep -o '<div class="bits">[^<]*</div>' "$T/report.html" | grep -qE ' in [0-9]+s|CI [0-9]' || fail "스펙 리포트: 결과 브리프에 걸린 시간이 남음(열로 옮겼다)"
# 토큰 열: 합(네 값)과 out·new in(캐시 밖 입력 + 캐시 쓰기)·cached, 정확한 값은 title. 기록에 없으면 —
grep -qF '<td class="nw"><span title="input 2000 · cache write 826000 · cache read 83300000 · output 222000">84.3M</span><div class="muted small">out 222k<br>new in 828k<br>cached 83.3M</div></td><td class="nw">Opus 5.5</td>' <<<"$(cells 47)" \
  && grep -qF '>1k</span><div class="muted small">out 900<br>new in 500<br>cached 0</div>' <<<"$(cells 48)" \
  && grep -qF '<td class="nw">—</td><td class="nw">Opus 5.5</td>' <<<"$(cells 41)" || fail "스펙 리포트: 토큰 열이 다름: $(cells 47)"
for want in '<div class="v">84.3M</div><div class="l">Tokens (output 222k)</div>' '<div class="v">2h 55m</div><div class="l"><span class="dot s-impl"></span>Implementation</div>' '<div class="v">14m</div><div class="l"><span class="dot s-ci"></span>CI</div>' '<div class="v">1h 36m</div><div class="l"><span class="dot s-post"></span>Post-merge check</div>'; do
  grep -qF "$want" "$T/report.html" || fail "스펙 리포트: 단계 합계 KPI '$want' 없음"
done
echo "ok  스펙 리포트 렌더(head 가 issue-N 그대로인 PR, 멈춘 뒤 병합된 티켓, 구현·CI·병합 뒤 검증 열 포함)"

# npx 껍질: 새 저장소에 --yes 로 설치하면 install.sh 결과에 더해 loop.env(BACKEND 줄)와 kit.json(커밋·ref)이 생긴다.
# 두 번째 실행은 loop.env 를 건드리지 않고, cmux 는 아직 거절한다
N="$T/npx"; mkdir -p "$N"; git -C "$N" init -q -b main; git -C "$N" commit -q --allow-empty -m init
out="$(cd "$N" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca)" || fail "npx 껍질 init 실패"
[[ -x "$N/scripts/ticket-loop.sh" && -f "$N/.claude/skills/setup-ticket-loop/SKILL.md" ]] || fail "npx 껍질이 install.sh 를 부르지 않음"
# 첫 줄은 루프와 같은 머리줄(kit_banner 와 글자까지 같다)
want="$(logc "kit_banner \"ticket-loop-kit $(cat "$KIT/VERSION") ($(git -C "$KIT" rev-parse HEAD | cut -c1-7))\"" | awk 'NF')"
[[ "$(awk 'NF { print; exit }' <<<"$out")" == "$want" ]] || fail "npx 껍질의 첫 줄이 루프 머리줄과 다르다: $(awk 'NF { print; exit }' <<<"$out")"
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

# npx 껍질, 플래그 없는 init 의 기본값은 기존 loop.env 의 BACKEND·AGENT 다(#4). tmux 설치본에 init --yes 를 돌리면 tmux 로 가고
# Orca 등록을 시도하지 않으며 Next steps 에 Orca 항목이 없고 "Keeping" 경고도 없다. 명시한 --backend 는 여전히 이긴다(그때만 "Keeping").
# 모르는 이름이면 경고 한 줄 뒤 지금의 기본값(orca·claude)으로 가고 실패하지 않는다. 가짜 orca CLI 는 불리면 표식 파일을 남긴다
E="$T/npx-env"; mkdir -p "$E/.ticket-loop" "$T/fake-orca"; git -C "$E" init -q -b main; git -C "$E" commit -q --allow-empty -m init
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 1\n' "$T/fake-orca/called" > "$T/fake-orca/orca"; chmod +x "$T/fake-orca/orca"
printf 'BACKEND="${BACKEND:-tmux}"\n' > "$E/.ticket-loop/loop.env"
out="$(cd "$E" && ORCA_CLI="$T/fake-orca/orca" node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential 2>&1)" || fail "loop.env BACKEND=tmux 에서 init --yes 실패: $out"
grep -qF 'Backend: tmux (from .ticket-loop/loop.env)' <<<"$out" || fail "loop.env 의 BACKEND=tmux 가 기본값이 되지 않음: $out"
grep -qE 'Orca Settings|Orca CLI|Registered the repo with Orca|Orca registration|Orca: already' <<<"$out" && fail "tmux 설치본인데 Orca 등록·안내가 나옴: $out"
[[ ! -e "$T/fake-orca/called" ]] || fail "tmux 설치본인데 orca CLI 를 불렀다"
grep -q 'Keeping' <<<"$out" && fail "loop.env 의 값을 그대로 쓰는데 Keeping 경고가 나옴: $out"
grep -qxF 'BACKEND="${BACKEND:-tmux}"' "$E/.ticket-loop/loop.env" || fail "loop.env 의 BACKEND 줄이 바뀜"
grep -qxF 'AGENT="${AGENT:-claude}"' "$E/.ticket-loop/loop.env" || fail "AGENT 줄이 없는 loop.env 에 기본 claude 를 덧붙이지 않음"
# 명시한 --backend orca 가 이긴다: orca 로 진행하고 Keeping BACKEND=tmux 경고, 배너의 Backend 에는 loop.env 표시가 없다
out="$(cd "$E" && node "$KIT/bin/ticket-loop-kit.js" init --yes --backend orca --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "--backend orca init 실패: $out"
grep -qE '^▸ Backend: Orca · ' <<<"$out" || fail "--backend orca 가 loop.env 의 tmux 에 밀림: $out"
grep -qF 'Keeping BACKEND=tmux in .ticket-loop/loop.env' <<<"$out" || fail "--backend orca 인데 Keeping BACKEND=tmux 경고가 없음: $out"
grep -qxF 'BACKEND="${BACKEND:-tmux}"' "$E/.ticket-loop/loop.env" || fail "--backend orca 가 loop.env 를 고침"
# AGENT 도 같다(VAR=값 표기도 읽는다): codex 가 기본이 되고 Next steps 도 Codex 기준
E2="$T/npx-env-agent"; mkdir -p "$E2/.ticket-loop"; git -C "$E2" init -q -b main; git -C "$E2" commit -q --allow-empty -m init
printf 'BACKEND=tmux\nAGENT="${AGENT:-codex}"\n' > "$E2/.ticket-loop/loop.env"
out="$(cd "$E2" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential 2>&1)" || fail "loop.env AGENT=codex 에서 init --yes 실패: $out"
grep -qF 'Backend: tmux (from .ticket-loop/loop.env) · Agent: Codex CLI (from .ticket-loop/loop.env)' <<<"$out" || fail "loop.env 의 AGENT=codex 가 기본값이 되지 않음: $out"
grep -q 'In Codex' <<<"$out" || fail "AGENT=codex 인데 Codex 다음 단계 안내가 없음: $out"
grep -q 'Keeping' <<<"$out" && fail "AGENT 를 그대로 쓰는데 Keeping 경고가 나옴: $out"
[[ -f "$E2/.codex/rules/ticket-loop.rules" ]] || fail "AGENT=codex 가 install.sh 로 넘어가지 않음"
# loop.env 가 없으면 지금과 같은 기본값(orca·claude)이고 loop.env 표시가 없다
E3="$T/npx-env-none"; mkdir -p "$E3"; git -C "$E3" init -q -b main; git -C "$E3" commit -q --allow-empty -m init
out="$(cd "$E3" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "loop.env 없는 init 실패: $out"
grep -qxF '▸ Backend: Orca · Agent: Claude Code' <<<"$out" || fail "loop.env 가 없는데 기본값이 orca·claude 가 아니다: $out"
# 모르는 이름: 경고 한 줄 뒤 기본값으로 진행, 종료 코드 0, loop.env 는 그대로
printf 'BACKEND="${BACKEND:-zellij}"\nAGENT="${AGENT:-gemini}"\n' > "$E3/.ticket-loop/loop.env"
out="$(cd "$E3" && node "$KIT/bin/ticket-loop-kit.js" init --yes --no-skills --no-github --no-git-credential --no-orca 2>&1)" || fail "모르는 BACKEND 가 loop.env 에 있으면 실패하면 안 된다: $out"
grep -qF 'Ignoring BACKEND=zellij in .ticket-loop/loop.env' <<<"$out" && grep -qF 'Ignoring AGENT=gemini in .ticket-loop/loop.env' <<<"$out" || fail "모르는 loop.env 값에 경고가 없음: $out"
grep -qxF '▸ Backend: Orca · Agent: Claude Code' <<<"$out" || fail "모르는 loop.env 값인데 기본값으로 가지 않음: $out"
grep -qxF 'BACKEND="${BACKEND:-zellij}"' "$E3/.ticket-loop/loop.env" && grep -qxF 'AGENT="${AGENT:-gemini}"' "$E3/.ticket-loop/loop.env" || fail "모르는 값을 init 이 고쳐 씀"
echo "ok  npx 껍질 기본값은 기존 loop.env 의 BACKEND·AGENT(명시 플래그 우선, 모르는 값은 경고 뒤 기본값)"
echo "smoke 통과"
