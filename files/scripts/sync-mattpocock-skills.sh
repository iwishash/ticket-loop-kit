#!/usr/bin/env bash
set -euo pipefail

# mattpocock/skills를 이 저장소의 .claude/skills/에 프로젝트 단위로 들인다(벤더링).
#
# 플러그인 설치 대신 파일을 커밋하는 이유:
#   - Orca 워커 워크트리와 클라우드 세션이 clone만으로 같은 버전을 쓴다(사용자 PC 설치 상태와 무관)
#   - 무인 루프 도중 자동 업데이트로 스킬 동작이 바뀌지 않는다 — 올릴 때만 이 스크립트를 돌린다
#   - 프로젝트가 소유한 스킬(implement·pr)과 이름을 바꾼 스킬(ticket-review)을 upstream 위에 덮어 쓴다
#
# 사용법:
#   bash scripts/sync-mattpocock-skills.sh            # upstream main 최신
#   bash scripts/sync-mattpocock-skills.sh <ref>      # 태그·커밋 고정
#
# 하는 일:
#   1. upstream .claude-plugin/plugin.json의 skills 목록(플러그인 공식 세트) + EXTRA_SKILLS를 복사한다
#   2. PROJECT_OWNED 스킬(implement·pr)은 건드리지 않는다(이 저장소가 직접 관리)
#   3. code-review → ticket-review로 이름을 바꾼다. Claude Code 내장 /code-review와 이름이 겹치기 때문이다.
#      다른 스킬 본문의 code-review 스킬 참조도 같이 바꾼다
#   4. 지난 동기화에 있었지만 이번 목록에 없는 스킬은 지운다(.claude/skills/.mattpocock.json 기준)
#   5. 버전·커밋·설치 목록을 .claude/skills/.mattpocock.json에 남긴다
# 끝나면 `git diff --stat .claude/skills`로 바뀐 것을 보고 커밋한다.

REF="${1:-main}"
UPSTREAM="https://github.com/mattpocock/skills.git"
EXTRA_SKILLS=("skills/misc/git-guardrails-claude-code")
PROJECT_OWNED=("implement" "pr")
RENAME_FROM="code-review"
RENAME_TO="ticket-review"

for tool in git jq rsync; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool 이(가) 없습니다." >&2; exit 1; }
done

ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/.claude/skills"
MANIFEST="$DEST/.mattpocock.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mattpocock-skills.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

git clone -q "$UPSTREAM" "$WORK/src"
git -C "$WORK/src" checkout -q "$REF"
COMMIT="$(git -C "$WORK/src" rev-parse HEAD)"
VERSION="$(jq -r .version "$WORK/src/.claude-plugin/plugin.json")"
# upstream main은 마지막 태그 뒤 미출시 changeset을 품고 있다 — version만 적으면 내용을 못 담는다(2026-10-10 "1.3.2" 혼동).
PENDING="$(find "$WORK/src/.changeset" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' ')"

# macOS 기본 bash 3.2에는 mapfile이 없다
PATHS=()
while IFS= read -r p; do PATHS+=("$p"); done < <(jq -r '.skills[]' "$WORK/src/.claude-plugin/plugin.json" | sed 's#^\./##')
PATHS+=("${EXTRA_SKILLS[@]}")

is_owned() { local s; for s in "${PROJECT_OWNED[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

installed=()
for p in "${PATHS[@]}"; do
  src="$WORK/src/$p"
  [[ -f "$src/SKILL.md" ]] || { echo "upstream에 $p/SKILL.md가 없습니다." >&2; exit 1; }
  name="$(basename "$p")"
  is_owned "$name" && { echo "skip $name (프로젝트 소유)"; continue; }
  [[ "$name" == "$RENAME_FROM" ]] && name="$RENAME_TO"
  rsync -a --delete "$src/" "$DEST/$name/"
  installed+=("$name")
done

# code-review 스킬 이름과 그 참조를 ticket-review로 바꾼다. 스킬 이름으로 쓰인 자리만 바꾼다
# (`code-review` 백틱, "code-review" 따옴표, /code-review, name: 줄, ./code-review/ 경로).
for name in "${installed[@]}"; do
  while IFS= read -r -d '' f; do
    sed -i.bak -E \
      -e "s#^name: ${RENAME_FROM}\$#name: ${RENAME_TO}#" \
      -e "s#\`${RENAME_FROM}\`#\`${RENAME_TO}\`#g" \
      -e "s#\"${RENAME_FROM}\"#\"${RENAME_TO}\"#g" \
      -e "s#/${RENAME_FROM}([^-a-z]|\$)#/${RENAME_TO}\\1#g" \
      "$f"
    rm -f "$f.bak"
  done < <(find "$DEST/$name" -name '*.md' -print0)
done

# 지난 동기화 목록에서 빠진 스킬 제거(프로젝트 소유 스킬과 목록 밖 디렉터리는 건드리지 않는다)
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r old; do
    keep=0
    for n in "${installed[@]}"; do [[ "$n" == "$old" ]] && keep=1; done
    is_owned "$old" && keep=1
    if [[ $keep -eq 0 && -d "$DEST/$old" ]]; then rm -rf "${DEST:?}/$old"; echo "removed $old (upstream 목록에서 빠짐)"; fi
  done < <(jq -r '.skills[]' "$MANIFEST")
fi

jq -n --arg ref "$REF" --arg commit "$COMMIT" --arg version "$VERSION" --argjson pending "$PENDING" \
  --arg synced "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson skills "$(printf '%s\n' "${installed[@]}" | jq -R . | jq -s 'sort')" \
  --argjson owned "$(printf '%s\n' "${PROJECT_OWNED[@]}" | jq -R . | jq -s .)" \
  '{upstream: "mattpocock/skills", ref: $ref, commit: $commit, version: $version, pending_changesets: $pending, synced_at: $synced,
    renamed: {"code-review": "ticket-review"}, project_owned: $owned, skills: $skills}' > "$MANIFEST"

echo "mattpocock/skills ${VERSION} + 미출시 changeset ${PENDING}건 (${COMMIT:0:7}) → ${#installed[@]}개 스킬 동기화"
echo "프로젝트 소유(직접 갱신): ${PROJECT_OWNED[*]} — upstream 변경은 CHANGELOG에서 확인해 반영한다"
