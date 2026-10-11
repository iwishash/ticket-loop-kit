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

python3 - "$KIT" <<'EOF' || fail "docs/guide.html 부록 D가 files/scripts/ticket-loop.sh와 다르다"
import html, re, sys
kit = sys.argv[1]
h = open(f"{kit}/docs/guide.html", encoding="utf-8").read()
m = re.search(r'<h3>D\..*?<pre class="script"><code>(.*?)</code></pre>', h, re.S)
s = open(f"{kit}/files/scripts/ticket-loop.sh", encoding="utf-8").read().rstrip("\n")
sys.exit(0 if m and html.unescape(m.group(1)) == s else 1)
EOF
echo "ok  부록 D 일치"

T="$(mktemp -d "${TMPDIR:-/tmp}/orca-loop-kit-smoke.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git -C "$T" init -q -b main
git -C "$T" commit -q --allow-empty -m init
run() { (cd "$T" && KIT_DIR="$KIT" bash "$KIT/install.sh" --no-skills --no-github --no-git-credential --no-orca >/dev/null); }

run
for f in scripts/ticket-loop.sh scripts/ticket-state.sh scripts/sync-mattpocock-skills.sh \
         .claude/skills/setup-orca-loop/SKILL.md .claude/skills/implement/SKILL.md .claude/skills/pr/SKILL.md \
         .orca-loop/worker-rules.md .orca-loop/kit.json; do
  [[ -f "$T/$f" ]] || fail "설치 뒤 $f 없음"
done
[[ -x "$T/scripts/ticket-loop.sh" ]] || fail "ticket-loop.sh 실행 권한 없음"
jq -e '.permissions.deny | index("Bash(gh pr merge:*)")' "$T/.claude/settings.json" >/dev/null || fail "deny 병합 안 됨"
grep -qxF '/.orca-loop/*.log' "$T/.gitignore" || fail ".gitignore 줄 없음"
echo "ok  첫 설치"

# 프로젝트 소유 파일은 두 번째 설치에서 유지돼야 한다
echo "project edit" >> "$T/.orca-loop/worker-rules.md"
jq '.permissions.deny += ["Bash(rm -rf:*)"]' "$T/.claude/settings.json" > "$T/s.json" && mv "$T/s.json" "$T/.claude/settings.json"
cp "$T/.claude/settings.json" "$T/before.json"; cp "$T/.gitignore" "$T/before.gitignore"
run
grep -q "project edit" "$T/.orca-loop/worker-rules.md" || fail "재설치가 프로젝트 소유 파일을 덮어씀"
cmp -s "$T/before.json" "$T/.claude/settings.json" || fail "재설치가 settings.json을 바꿈"
cmp -s "$T/before.gitignore" "$T/.gitignore" || fail "재설치가 .gitignore에 줄을 또 넣음"
echo "ok  재설치 멱등"

(cd "$T" && bash scripts/ticket-loop.sh --help >/dev/null) || fail "ticket-loop.sh --help"
echo "ok  ticket-loop.sh --help"
echo "smoke 통과"
