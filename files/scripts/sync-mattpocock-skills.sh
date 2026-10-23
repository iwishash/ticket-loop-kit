#!/usr/bin/env bash
set -euo pipefail

# mattpocock/skills 중 티켓 루프가 쓰는 것만 이 저장소의 .agents/skills/에 프로젝트 단위로 들인다(벤더링).
# .claude/skills/<이름>은 그 링크다 — Codex는 .agents/skills/를, Claude Code는 .claude/skills/를 읽는다. 한 사본, 두 에이전트(`npx skills add`와 같은 배치).
# 0.6 이하가 .claude/skills/<이름>에 실제 디렉터리로 들인 것은 매니페스트를 보고 .agents/skills/로 옮기고(git mv) 링크를 남긴다.
#
# 플러그인 설치 대신 파일을 커밋하는 이유:
#   - Orca 워커 워크트리와 클라우드 세션이 clone만으로 같은 버전을 쓴다(사용자 PC 설치 상태와 무관)
#   - 무인 루프 도중 자동 업데이트로 스킬 동작이 바뀌지 않는다 — 올릴 때만 이 스크립트를 돌린다
#   - 프로젝트가 소유한 스킬(implement·pr)과 이름을 바꾼 스킬(ticket-review)을 upstream 위에 덮어 쓴다
#
# 두 묶음:
#   core      tdd, code-review(→ ticket-review). implement 스킬이 Skill 도구로 직접 부른다 — 항상 들인다
#   workflow  grill-with-docs, to-spec, to-tickets, retro와 그것들이 부르는 grilling, domain-modeling, writing-for-agents.
#             스펙 → 티켓 → 회고 흐름을 Claude Code 안에서 할 때만 켠다(--workflow). 루프 자체는 없어도 돈다
#   upstream의 나머지 스킬(ask-matt, wizard, teach …)은 새 설치본에는 들이지 않는다. 쓰고 싶으면 플러그인으로 따로 설치한다
#   kept      지난 설치(0.5 이하의 26개 등)가 들였지만 위 두 묶음에 없는 스킬. 사용자가 이미 쓰고 있을 수 있으니 지우지 않고 계속 동기화한다.
#             --prune 을 줄 때만 지운다. upstream 에서 사라진 것은 그대로 둔다. 손으로 지운 것은 다시 들이지 않는다.
#             setup-matt-pocock-skills 만 예외로 늘 지운다 — 이 키트가 docs/agents/issue-tracker.md 와 /setup-ticket-loop 로 그 역할을 대신한다
#
# 사용법:
#   bash scripts/sync-mattpocock-skills.sh                      # upstream main 최신, workflow 묶음은 지난 설치를 따른다
#   bash scripts/sync-mattpocock-skills.sh --ref <ref>          # 태그·커밋 고정(옛 형식 `<ref>` 위치 인자도 받는다)
#   bash scripts/sync-mattpocock-skills.sh --workflow           # workflow 묶음도 들인다 (--no-workflow: 빼고 지운다)
#                                                               # 플래그가 없으면: 지난 매니페스트의 선택 > 새 설치는 mattpocock-skills 플러그인이
#                                                               # 이 저장소에 켜져 있으면 끔(기획 스킬은 플러그인이 준다), 아니면 켬. codex 는 늘 켬
#   bash scripts/sync-mattpocock-skills.sh --prune              # 지난 설치가 들인 kept 스킬을 지운다(기본은 유지·동기화)
#   bash scripts/sync-mattpocock-skills.sh --check [--json]     # 들이지 않고 충돌만 검사한다(아래). 종료 0 없음 · 1 경고 · 3 차단
#   --force   차단 수준 충돌이 있어도 들인다        --no-check   검사를 건너뛴다(설치기가 먼저 검사했을 때)
#   --agent <claude|codex>   워커 에이전트(기본 claude). plugin·global 검사는 Claude Code에만 있는 일이라 claude 일 때만 한다
#
# 하는 일:
#   1. 같은 스킬이 다른 경로로 이미 설치돼 있는지 검사한다. Claude Code는 중복을 경고하지 않으므로 여기서 본다
#        plugin          (claude) mattpocock-skills 플러그인이 이 저장소에 켜져 있다 → core 는 그래도 들이고(선택기에 /tdd 와 /mattpocock-skills:tdd
#                        가 같이 보인다) 기획 스킬은 플러그인이 준다. 새 설치의 workflow 기본값을 끄는 근거                              알림
#        global          (claude) ~/.claude/skills/<이름> 이 있다 → 개인 스킬이 프로젝트 스킬을 가려 여기 둔 버전이 쓰이지 않는다  경고
#                        (codex) ~/.agents/skills/<이름> 이 있다 → Codex 는 합치지 않고 둘 다 선택기에 보인다                     알림
#        skills-cli      `npx skills add` 가 둔 skills-lock.json, 또는 이 저장소의 .agents/skills/<이름> 이 아닌 곳을 가리키는 링크
#                        → 두 도구가 같은 디렉터리를 덮어쓴다. 우리 배치의 링크(.claude/skills/<이름> → ../../.agents/skills/<이름>)는 정상  차단
#        builtin-shadow  code-review 스킬 디렉터리가 있다 → Claude Code 내장 /code-review 를 대체한다. 이 키트는 ticket-review 를 쓴다  경고
#        foreign         .agents/skills/<이름>(또는 옛 자리 .claude/skills/<이름>)이 있지만 지난 동기화 목록에 없다 → 이번에 덮어쓴다  알림
#        commands        .claude/commands/<이름>.md 가 있다 → 스킬이 우선하지만 둘이 남는다                                      알림
#        kept            지난 설치가 들였지만 이번 묶음에 없는 스킬이 있다 → 유지·동기화한다(--prune 이면 지운다)                알림
#   2. upstream .claude-plugin/plugin.json 에서 core(+workflow, +kept) 스킬 경로를 찾아 복사한다
#   3. PROJECT_OWNED 스킬(implement·pr, 그리고 매니페스트 project_owned 에 저장소가 더 적은 이름 — 예: 손으로 고쳐 쓰는 ticket-review)은
#      건드리지 않는다(이 저장소가 직접 관리). 그 밖의 스킬은 덮어쓰되, 지난 동기화의 upstream 커밋 사본과 달랐으면(커밋된 로컬 수정 포함)
#      요약에 `overwrote local edits: <이름>` 을 낸다 — git 에서 되돌리고 project_owned 에 적으라는 뜻이다
#   4. code-review → ticket-review 로 이름을 바꾼다. Claude Code 내장 /code-review 와 이름이 겹치기 때문이다.
#      다른 스킬 본문의 code-review 참조와, 들이지 않는 /setup-matt-pocock-skills 안내(→ /setup-ticket-loop)도 같이 바꾼다
#   5. 지운다(.agents/skills/.mattpocock.json 기준 — 0.6 이하는 .claude/skills/.mattpocock.json): --no-workflow 로 뺀 workflow 묶음, setup-matt-pocock-skills, --prune 일 때 kept 전부.
#      매니페스트에 없는 디렉터리와 프로젝트 소유 스킬은 절대 건드리지 않는다
#   6. 버전·커밋·묶음·kept·설치 목록을 .agents/skills/.mattpocock.json 에 남긴다(0.6 이하: .claude/skills/.mattpocock.json — 옮긴다)
# 끝나면 `git diff --stat .agents/skills .claude/skills`로 바뀐 것을 보고 커밋한다.

UPSTREAM="${MATTPOCOCK_UPSTREAM:-https://github.com/mattpocock/skills.git}"
CORE_SKILLS=(tdd code-review)
WORKFLOW_SKILLS=(grill-with-docs to-spec to-tickets retro grilling domain-modeling writing-for-agents)
PROJECT_OWNED=(implement pr)
SUPERSEDED=(setup-matt-pocock-skills)   # 이 키트가 역할을 대신한다 — 지난 설치에 있으면 지운다
RENAME_FROM="code-review"
RENAME_TO="ticket-review"

REF="main"; WORKFLOW="auto"; MODE="sync"; JSON=0; FORCE=0; CHECK=1; PRUNE=0; AGENT="claude"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --agent) AGENT="$2"; shift ;;
    --workflow) WORKFLOW=1 ;;
    --no-workflow) WORKFLOW=0 ;;
    --prune) PRUNE=1 ;;
    --check) MODE="check" ;;
    --json) JSON=1 ;;
    --force) FORCE=1 ;;
    --no-check) CHECK=0 ;;
    -h|--help) awk 'NR > 2 && /^#/ { on = 1; sub(/^# ?/, ""); print; next } on { exit }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) REF="$1" ;;
  esac
  shift
done

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not installed." >&2; exit 1; }
done

case "$AGENT" in claude|codex) ;; *) echo "unknown agent: $AGENT (claude | codex)" >&2; exit 2 ;; esac

ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/.agents/skills"            # 정본 — Codex 가 읽는다
CLAUDE_SKILLS="$ROOT/.claude/skills"   # 링크 — Claude Code 가 읽는다
MANIFEST="$DEST/.mattpocock.json"
OLD_MANIFEST="$CLAUDE_SKILLS/.mattpocock.json"   # 0.6 이하
[[ -f "$MANIFEST" || ! -f "$OLD_MANIFEST" ]] || MANIFEST="$OLD_MANIFEST"   # 아직 옮기기 전이면 옛것을 읽는다(--check 는 바꾸지 않는다)
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS_HOME="${CODEX_AGENTS_HOME:-$HOME/.agents}"

# 스킬 디렉터리가 있는가 — 새 자리(.agents/skills) 또는 옛 자리(.claude/skills 의 실제 디렉터리). 링크는 디렉터리로 치지 않는다
skill_dir_exists() { [[ -d "$DEST/$1" && ! -L "$DEST/$1" ]] || [[ -d "$CLAUDE_SKILLS/$1" && ! -L "$CLAUDE_SKILLS/$1" ]]; }
# .claude/skills/<이름> → ../../.agents/skills/<이름>. 실제 디렉터리가 남아 있으면(옛 배치의 사본 또는 foreign — 검사에서 알렸다) 지운다
link_claude() {
  local n="$1" l="$CLAUDE_SKILLS/$1"
  if [[ -L "$l" ]]; then
    [[ "$(readlink "$l")" == "../../.agents/skills/$n" ]] && return 0
    rm "$l"
  elif [[ -e "$l" ]]; then
    if git -C "$ROOT" ls-files --error-unmatch ".claude/skills/$n" >/dev/null 2>&1; then git -C "$ROOT" rm -rq ".claude/skills/$n"; else rm -rf "$l"; fi
  fi
  mkdir -p "$CLAUDE_SKILLS"
  ln -s "../../.agents/skills/$n" "$l"
}
unlink_claude() { [[ -L "$CLAUDE_SKILLS/$1" ]] && rm "$CLAUDE_SKILLS/$1" || true; }

has_name() { local n s; n="$1"; shift; for s in "$@"; do [[ "$s" == "$n" ]] && return 0; done; return 1; }
is_owned() { has_name "$1" "${PROJECT_OWNED[@]}"; }

# 매니페스트 project_owned: 저장소가 손으로 고쳐 쓰는 스킬을 더 적어 둔 것(예: 이름을 바꿔 들인 ticket-review 에 검사를 보탠 저장소).
# 여기 적힌 이름은 implement·pr 처럼 건드리지 않고, 다음 매니페스트에도 그대로 남긴다. 저장소에 놓이는 이름(ticket-review)으로 적는다 —
# upstream 이름(code-review)으로 적었으면 그렇게 읽는다(그대로 두면 skip 한 뒤 "not in this kit's skill set" 으로 지운다)
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ "$n" == "$RENAME_FROM" ]] && n="$RENAME_TO"
    has_name "$n" "${PROJECT_OWNED[@]}" || PROJECT_OWNED+=("$n")
  done < <(jq -r '(.project_owned // [])[] | strings' "$MANIFEST" 2>/dev/null)
fi

# enabledPlugins 는 user < project < local 순으로 같은 id 를 덮는다(Claude Code 문서). 마지막으로 값을 준 파일이 이긴다
plugin_enabled_in() {   # 출력: "<id>\t<file>" (켜진 것만)
  local f ids id val
  for id in $(for f in "$CLAUDE_HOME/settings.json" "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
                [[ -f "$f" ]] && jq -r '(.enabledPlugins // {}) | keys[]' "$f" 2>/dev/null; done | grep '^mattpocock-skills@' | sort -u); do
    val=""; local src=""
    for f in "$CLAUDE_HOME/settings.json" "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
      [[ -f "$f" ]] || continue
      # `// empty` 는 false 도 비우므로 has 로 본다 — local 의 false 가 project 의 true 를 덮어야 한다
      v="$(jq -r --arg id "$id" '(.enabledPlugins // {}) | if has($id) then (.[$id] | tostring) else empty end' "$f" 2>/dev/null)"
      [[ -n "$v" ]] && { val="$v"; src="$f"; }
    done
    if [[ "$val" == true ]]; then printf '%s\t%s\n' "$id" "${src#"$ROOT/"}"; fi
  done
  return 0
}

# workflow 묶음: 명시 플래그 > 지난 매니페스트(workflow 값, 없으면 to-tickets 가 들어 있었는지) > 새 설치의 기본값.
# 새 설치: (claude) mattpocock-skills 플러그인이 이 저장소에 켜져 있으면 끔 — 기획 스킬은 플러그인이 이 머신에서 준다. core 는 그래도 들인다
# (implement 가 부르고, 이름을 바꾸고, 커밋에 고정해야 하므로). 플러그인이 없으면 켬 — 스펙 → 티켓 → 회고 흐름을 바로 쓸 수 있게.
# codex 에는 플러그인이 없으니 켬. upstream 전부(26개)를 들이는 길은 두지 않는다(0.6 결정)
WF_REASON=""   # 자동으로 정했을 때 요약에 적는 근거. 명시 플래그면 비어 있다
if [[ "$WORKFLOW" == auto ]]; then
  if [[ -f "$MANIFEST" ]]; then
    WORKFLOW=0
    if jq -e '.workflow == true or ((.skills // []) | index("to-tickets") != null)' "$MANIFEST" >/dev/null 2>&1; then WORKFLOW=1; fi
    WF_REASON="the previous install's choice ($([[ $WORKFLOW -eq 1 ]] && echo '--no-workflow removes them' || echo '--workflow adds them'))"
  else
    WF_PLUGIN=""
    [[ "$AGENT" == claude ]] && WF_PLUGIN="$(plugin_enabled_in | cut -f1 | head -n1)"
    if [[ -n "$WF_PLUGIN" ]]; then
      WORKFLOW=0; WF_REASON="plugin $WF_PLUGIN is enabled for this repo and provides them on this machine; other clones and cloud sessions need the plugin too (--workflow vendors them for every clone)"
    else
      WORKFLOW=1; WF_REASON="no mattpocock-skills plugin is enabled for this repo (--no-workflow skips them)"
    fi
  fi
fi
WANTED=("${CORE_SKILLS[@]}")
[[ $WORKFLOW -eq 1 ]] && WANTED+=("${WORKFLOW_SKILLS[@]}")
# 저장소에 놓이는 이름(code-review 는 ticket-review 로)
DEST_NAMES=()
for n in "${WANTED[@]}"; do [[ "$n" == "$RENAME_FROM" ]] && n="$RENAME_TO"; DEST_NAMES+=("$n"); done

# kept: 지난 설치가 들였지만 이번 묶음에 없는 스킬. 디렉터리가 아직 있을 때만(손으로 지운 것은 다시 들이지 않는다).
# core·workflow 이름은 플래그가 결정하므로 여기 들지 않고, SUPERSEDED 는 늘 지운다
KEPT=()
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    has_name "$n" "${DEST_NAMES[@]}" "${CORE_SKILLS[@]}" "${WORKFLOW_SKILLS[@]}" "${PROJECT_OWNED[@]}" "${SUPERSEDED[@]}" && continue
    skill_dir_exists "$n" || continue
    KEPT+=("$n")
  done < <(jq -r '((.skills // []) + (.kept // [])) | unique[]' "$MANIFEST" 2>/dev/null)
fi

# ---------- 1. 충돌 검사 ----------
FINDINGS=()   # 각 항목: severity|kind|detail|fix
add_finding() { FINDINGS+=("$1|$2|$3|$4"); }

check_conflicts() {
  local n line id src where
  if [[ "$AGENT" == claude ]]; then
    while IFS=$'\t' read -r id src; do
      [[ -n "$id" ]] || continue
      add_finding info plugin "plugin $id is enabled for this repo ($src) — tdd and ticket-review are vendored anyway (the picker also shows /${id%%@*}:tdd); the planning skills can come from the plugin on this machine" \
        "claude plugin disable $id --scope project — only if the vendored copies should be the only ones that load; then vendor the planning skills too (--workflow)"
    done < <(plugin_enabled_in)
    for n in "${DEST_NAMES[@]}"; do
      if [[ -e "$CLAUDE_HOME/skills/$n/SKILL.md" ]]; then
        add_finding warn global "~/.claude/skills/$n exists — a personal skill shadows the project copy, so the vendored $n is never the one that runs" \
          "remove ~/.claude/skills/$n (npx skills remove $n -g, or rm -rf) or accept that this machine runs its own copy"
      fi
    done
  else
    for n in "${DEST_NAMES[@]}"; do
      if [[ -e "$AGENTS_HOME/skills/$n/SKILL.md" ]]; then
        add_finding info global "~/.agents/skills/$n exists — Codex does not merge same-named skills; both appear in the skill selector" \
          "remove ~/.agents/skills/$n if the committed copy should be the only one"
      fi
    done
  fi
  if [[ -f "$ROOT/skills-lock.json" ]] && jq -e '(.skills // {}) | to_entries | map(select(.value.source == "mattpocock/skills")) | length > 0' "$ROOT/skills-lock.json" >/dev/null 2>&1; then
    add_finding block skills-cli "skills-lock.json lists mattpocock/skills — \`npx skills\` and this script would overwrite each other's files" \
      "npx skills remove <skill…> (or delete skills-lock.json and the .agents/skills copies), then rerun"
  fi
  # 링크: .claude/skills/<이름> → ../../.agents/skills/<이름> 은 이 키트의 배치다. 다른 곳을 가리키거나 .agents/skills/<이름> 자체가 링크면 다른 도구다
  for n in "${DEST_NAMES[@]}" "$RENAME_FROM"; do
    if [[ -L "$CLAUDE_SKILLS/$n" && "$(readlink "$CLAUDE_SKILLS/$n")" != "../../.agents/skills/$n" ]]; then
      add_finding block skills-cli ".claude/skills/$n is a symbolic link to $(readlink "$CLAUDE_SKILLS/$n") — installed by another tool (this kit links to ../../.agents/skills/$n)" \
        "remove the link and its target, then rerun"
    fi
    if [[ -L "$DEST/$n" ]]; then
      add_finding block skills-cli ".agents/skills/$n is a symbolic link ($(readlink "$DEST/$n")) — installed by another tool" \
        "remove the link and its target, then rerun"
    fi
  done
  if skill_dir_exists "$RENAME_FROM"; then
    where=".agents/skills"; [[ -d "$DEST/$RENAME_FROM" ]] || where=".claude/skills"
    add_finding warn builtin-shadow "$where/$RENAME_FROM exists — a project skill named code-review replaces Claude Code's built-in /code-review; this kit vendors it as $RENAME_TO" \
      "rm -rf $where/$RENAME_FROM"
  fi
  for n in "${DEST_NAMES[@]}"; do
    if skill_dir_exists "$n" && ! is_owned "$n"; then
      if [[ ! -f "$MANIFEST" ]] || ! jq -e --arg n "$n" '(.skills // []) | index($n) != null' "$MANIFEST" >/dev/null 2>&1; then
        where=".agents/skills"; [[ -d "$DEST/$n" && ! -L "$DEST/$n" ]] || where=".claude/skills"
        add_finding info foreign "$where/$n exists but was not placed by this script — it will be overwritten" ""
      fi
    fi
    if [[ -f "$ROOT/.claude/commands/$n.md" ]]; then
      add_finding info commands ".claude/commands/$n.md exists — the skill takes precedence, but both remain" "delete the command file if the skill replaces it"
    fi
  done
  if [[ ${#KEPT[@]} -gt 0 ]]; then
    if [[ $PRUNE -eq 1 ]]; then
      add_finding info kept "${#KEPT[@]} skills from an earlier install are outside the selected sets (${KEPT[*]}) — --prune removes them" ""
    else
      add_finding info kept "${#KEPT[@]} skills from an earlier install are outside the selected sets (${KEPT[*]}) — kept and synced; pass --prune to remove them" ""
    fi
  fi
  for n in "${SUPERSEDED[@]}"; do
    if skill_dir_exists "$n" && [[ -f "$MANIFEST" ]] && jq -e --arg n "$n" '(.skills // []) | index($n) != null' "$MANIFEST" >/dev/null 2>&1; then
      add_finding info superseded "$n will be removed — this kit replaces it (docs/agents/issue-tracker.md + /setup-ticket-loop)" ""
    fi
  done
  return 0   # set -e: 마지막 검사가 거짓이어도 함수가 실패로 끝나지 않게
}

print_findings() {   # 사람용 출력. 반환: 0 없음 · 1 경고 · 3 차단
  local rc=0 f sev kind detail fix tag
  if [[ $JSON -eq 1 ]]; then
    { for f in "${FINDINGS[@]+"${FINDINGS[@]}"}"; do
        IFS='|' read -r sev kind detail fix <<<"$f"
        jq -n --arg s "$sev" --arg k "$kind" --arg d "$detail" --arg x "$fix" '{severity: $s, kind: $k, detail: $d, fix: $x}'
      done; } | jq -s .
  else
    for f in "${FINDINGS[@]+"${FINDINGS[@]}"}"; do
      IFS='|' read -r sev kind detail fix <<<"$f"
      case "$sev" in block) tag="✗";; warn) tag="!";; *) tag="·";; esac
      printf '  %s %-14s %s\n' "$tag" "$kind" "$detail" >&2
      [[ -z "$fix" ]] || printf '    %s→ %s\n' "" "$fix" >&2
    done
  fi
  for f in "${FINDINGS[@]+"${FINDINGS[@]}"}"; do
    case "${f%%|*}" in block) rc=3 ;; warn) [[ $rc -eq 0 ]] && rc=1 ;; esac
  done
  return $rc
}

if [[ $CHECK -eq 1 || "$MODE" == check ]]; then
  check_conflicts
  rc=0; print_findings || rc=$?
  if [[ "$MODE" == check ]]; then exit $rc; fi
  if [[ $rc -eq 3 && $FORCE -eq 0 ]]; then
    echo "Skill sync stopped: another tool manages mattpocock skills in this repo (see above). Resolve it, or rerun with --force." >&2
    exit 3
  fi
fi

# ---------- 1'. 배치 마이그레이션 (0.6 이하: .claude/skills/<이름> 실제 디렉터리 → .agents/skills/<이름> + 링크) ----------
# 이번에 관리할 이름(묶음 + kept)의 옛 자리 디렉터리를 먼저 옮긴다 — 덮어쓸 것도 옮긴 뒤 덮어써야 git 이 이동+수정으로 본다.
# 프로젝트 소유·매니페스트 밖 디렉터리는 건드리지 않는다. 추적 중이면 git mv 로 이력을 잇는다
moved=()
for n in "${DEST_NAMES[@]}" "${KEPT[@]+"${KEPT[@]}"}"; do
  is_owned "$n" && continue
  [[ -d "$CLAUDE_SKILLS/$n" && ! -L "$CLAUDE_SKILLS/$n" && ! -e "$DEST/$n" ]] || continue
  mkdir -p "$DEST"
  if git -C "$ROOT" ls-files --error-unmatch ".claude/skills/$n" >/dev/null 2>&1; then git -C "$ROOT" mv ".claude/skills/$n" ".agents/skills/$n"; else mv "$CLAUDE_SKILLS/$n" "$DEST/$n"; fi
  link_claude "$n"
  moved+=("$n")
done
if [[ "$MANIFEST" == "$OLD_MANIFEST" && -f "$OLD_MANIFEST" ]]; then
  mkdir -p "$DEST"
  if git -C "$ROOT" ls-files --error-unmatch ".claude/skills/.mattpocock.json" >/dev/null 2>&1; then git -C "$ROOT" mv ".claude/skills/.mattpocock.json" ".agents/skills/.mattpocock.json"; else mv "$OLD_MANIFEST" "$DEST/.mattpocock.json"; fi
  MANIFEST="$DEST/.mattpocock.json"
fi
[[ ${#moved[@]} -eq 0 ]] || echo "  moved   ${#moved[@]} skills from .claude/skills/ to .agents/skills/ (${moved[*]}; links left behind — Codex reads .agents/skills)"

# ---------- 2. upstream ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mattpocock-skills.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone -q "$UPSTREAM" "$WORK/src"
git -C "$WORK/src" checkout -q "$REF"
COMMIT="$(git -C "$WORK/src" rev-parse HEAD)"
VERSION="$(jq -r .version "$WORK/src/.claude-plugin/plugin.json")"
# upstream main은 마지막 태그 뒤 미출시 changeset을 품고 있다 — version만 적으면 내용을 못 담는다(2026-10-10 "1.3.2" 혼동).
PENDING="$(find "$WORK/src/.changeset" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' ')"

# 이름으로 upstream 경로를 찾는다(디렉터리가 옮겨져도 plugin.json 의 목록을 따른다). macOS 기본 bash 3.2 에는 mapfile 이 없다
UP_PATHS=()
while IFS= read -r p; do UP_PATHS+=("$p"); done < <(jq -r '.skills[]' "$WORK/src/.claude-plugin/plugin.json" | sed 's#^\./##')
path_in() { local n p; n="$1"; shift; for p in "$@"; do [[ "$(basename "$p")" == "$n" ]] && { echo "$p"; return 0; }; done; return 1; }
path_of() { path_in "$1" "${UP_PATHS[@]}"; }

# code-review 스킬 이름과 그 참조를 ticket-review로 바꾼다. 스킬 이름으로 쓰인 자리만 바꾼다
# (`code-review` 백틱, "code-review" 따옴표, /code-review, name: 줄, ./code-review/ 경로).
# 들이지 않는 /setup-matt-pocock-skills 를 부르라는 안내는 /setup-ticket-loop 로(이 키트가 docs/agents/issue-tracker.md 를 놓는다).
rename_refs() {   # <디렉터리>
  local f
  while IFS= read -r -d '' f; do
    sed -i.bak -E \
      -e "s#^name: ${RENAME_FROM}\$#name: ${RENAME_TO}#" \
      -e "s#\`${RENAME_FROM}\`#\`${RENAME_TO}\`#g" \
      -e "s#\"${RENAME_FROM}\"#\"${RENAME_TO}\"#g" \
      -e "s#/${RENAME_FROM}([^-a-z]|\$)#/${RENAME_TO}\\1#g" \
      -e "s#/setup-matt-pocock-skills#/setup-ticket-loop#g" \
      "$f"
    rm -f "$f.bak"
  done < <(find "$1" -name '*.md' -print0)
}

# 로컬 수정 판정: 덮어쓸 디렉터리는 지난 동기화의 upstream 커밋(매니페스트 commit)에 같은 치환을 한 사본과 같아야 한다.
# 다르면 저장소가 손으로 고친 것이다(커밋했어도 잡힌다 — HEAD 와 비교하면 커밋된 수정은 못 본다). 덮어쓰되 요약에 알린다.
# 지난 매니페스트의 skills 에 없던 디렉터리(project_owned 에서 방금 뺀 것, foreign)도 같은 잣대로 본다.
# 그 커밋을 받지 못했거나(이력 재작성) 그때의 plugin.json 에 그 이름이 없으면 판정하지 않는다
PREV_COMMIT=""
if [[ -f "$MANIFEST" ]]; then
  PREV_COMMIT="$(jq -r '.commit // empty' "$MANIFEST" 2>/dev/null)" || PREV_COMMIT=""
fi
PREV_PATHS=()
if [[ -n "$PREV_COMMIT" ]]; then
  if git -C "$WORK/src" cat-file -e "$PREV_COMMIT^{commit}" 2>/dev/null \
     && git -C "$WORK/src" worktree add -q --detach "$WORK/prev" "$PREV_COMMIT" 2>/dev/null && [[ -f "$WORK/prev/.claude-plugin/plugin.json" ]]; then
    while IFS= read -r p; do PREV_PATHS+=("$p"); done < <(jq -r '.skills[]' "$WORK/prev/.claude-plugin/plugin.json" | sed 's#^\./##')
  else
    echo "  note    could not compare with the previous sync's upstream commit (${PREV_COMMIT:0:7}) — local edits to vendored skills are overwritten without notice this time"
  fi
fi
locally_edited() {   # <저장소 이름> — 0: 지난 동기화 사본과 다르다(로컬 수정)
  local name="$1" up p
  up="$name"; [[ "$name" == "$RENAME_TO" ]] && up="$RENAME_FROM"
  [[ -d "$DEST/$name" && ! -L "$DEST/$name" ]] || return 1
  p="$(path_in "$up" "${PREV_PATHS[@]+"${PREV_PATHS[@]}"}")" || return 1
  [[ -f "$WORK/prev/$p/SKILL.md" ]] || return 1
  rm -rf "$WORK/expect"; mkdir -p "$WORK/expect"
  cp -R "$WORK/prev/$p" "$WORK/expect/$name"
  rename_refs "$WORK/expect/$name"
  ! diff -rq -x .DS_Store "$WORK/expect/$name" "$DEST/$name" >/dev/null 2>&1   # Finder 가 둔 .DS_Store 는 수정이 아니다
}
overwrote=()
vendor() {   # <upstream 경로> <저장소 이름>: 덮어쓰고 링크하고 참조를 바꾼다. 로컬 수정이 있었으면 적어 둔다
  local src="$1" name="$2"
  if locally_edited "$name"; then overwrote+=("$name"); fi
  rm -rf "${DEST:?}/$name"
  cp -R "$src" "$DEST/$name"
  link_claude "$name"
  rename_refs "$DEST/$name"
  installed+=("$name")
}

mkdir -p "$DEST"
installed=()
for s in "${WANTED[@]}"; do
  p="$(path_of "$s")" || { echo "upstream plugin.json has no skill named $s" >&2; exit 1; }
  src="$WORK/src/$p"
  [[ -f "$src/SKILL.md" ]] || { echo "upstream has no $p/SKILL.md" >&2; exit 1; }
  name="$s"
  [[ "$name" == "$RENAME_FROM" ]] && name="$RENAME_TO"
  if is_owned "$name"; then
    [[ -d "$DEST/$name" && ! -L "$DEST/$name" ]] && link_claude "$name"   # 링크만 챙긴다 — 본문은 저장소 것
    echo "  skip    $name (project-owned)"; continue
  fi
  vendor "$src" "$name"
done

# kept 스킬도 같은 upstream 커밋으로 맞춘다. upstream 에서 사라진 것은 받아올 곳이 없으니 그대로 둔다(--prune 으로만 지운다)
n_sets=${#installed[@]}
kept_stale=()
if [[ $PRUNE -eq 0 ]]; then
  for name in "${KEPT[@]+"${KEPT[@]}"}"; do
    if p="$(path_of "$name")" && [[ -f "$WORK/src/$p/SKILL.md" ]]; then
      vendor "$WORK/src/$p" "$name"
    else
      link_claude "$name"
      kept_stale+=("$name"); echo "  kept    $name (no longer in upstream — left as is)"
    fi
  done
fi

# 지난 동기화 목록에 있었지만 이번에 들이지도 kept 로 남기지도 않은 스킬을 지운다: --no-workflow 로 뺀 묶음, SUPERSEDED, --prune 일 때 kept 전부.
# 프로젝트 소유 스킬과 매니페스트 밖 디렉터리는 건드리지 않는다
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    has_name "$old" "${installed[@]}" "${kept_stale[@]+"${kept_stale[@]}"}" && continue
    is_owned "$old" && continue
    skill_dir_exists "$old" || continue
    [[ -L "$DEST/$old" ]] || rm -rf "${DEST:?}/$old"
    if [[ -L "$CLAUDE_SKILLS/$old" ]]; then rm "$CLAUDE_SKILLS/$old"
    elif [[ -d "$CLAUDE_SKILLS/$old" ]]; then
      if git -C "$ROOT" ls-files --error-unmatch ".claude/skills/$old" >/dev/null 2>&1; then git -C "$ROOT" rm -rq ".claude/skills/$old"; else rm -rf "${CLAUDE_SKILLS:?}/$old"; fi
    fi
    if has_name "$old" "${SUPERSEDED[@]}"; then echo "  removed $old (superseded by /setup-ticket-loop)"
    elif has_name "$old" "${KEPT[@]+"${KEPT[@]}"}"; then echo "  removed $old (--prune)"
    else echo "  removed $old (not in this kit's skill set)"; fi
  done < <(jq -r '((.skills // []) + (.kept // [])) | unique[]' "$MANIFEST" 2>/dev/null)
fi
kept_now=()
[[ $PRUNE -eq 1 ]] || kept_now=("${KEPT[@]+"${KEPT[@]}"}")

jq -n --arg ref "$REF" --arg commit "$COMMIT" --arg version "$VERSION" --argjson pending "$PENDING" \
  --arg synced "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson workflow "$([[ $WORKFLOW -eq 1 ]] && echo true || echo false)" \
  --argjson skills "$(printf '%s\n' "${installed[@]}" "${kept_stale[@]+"${kept_stale[@]}"}" | jq -R . | jq -s 'map(select(length > 0)) | sort')" \
  --argjson kept "$(printf '%s\n' "${kept_now[@]+"${kept_now[@]}"}" | jq -R . | jq -s 'map(select(length > 0)) | sort')" \
  --argjson core "$(printf '%s\n' "${CORE_SKILLS[@]}" | sed "s/^${RENAME_FROM}\$/${RENAME_TO}/" | jq -R . | jq -s .)" \
  --argjson wf "$(printf '%s\n' "${WORKFLOW_SKILLS[@]}" | jq -R . | jq -s .)" \
  --argjson owned "$(printf '%s\n' "${PROJECT_OWNED[@]}" | jq -R . | jq -s .)" \
  '{upstream: "mattpocock/skills", ref: $ref, commit: $commit, version: $version, pending_changesets: $pending, synced_at: $synced,
    renamed: {"code-review": "ticket-review"}, project_owned: $owned, sets: {core: $core, workflow: $wf}, workflow: $workflow, kept: $kept, skills: $skills}' > "$MANIFEST"

kept_note=""
if [[ ${#kept_now[@]} -gt 0 ]]; then
  stale_note=""; [[ ${#kept_stale[@]} -eq 0 ]] || stale_note="; ${#kept_stale[@]} not in upstream any more, left as is"
  kept_note=", kept ${#kept_now[@]} from an earlier install (${kept_now[*]}${stale_note}) — --prune drops them"
fi
echo "  mattpocock/skills ${VERSION} + ${PENDING} unreleased changesets (${COMMIT:0:7}) → ${n_sets} skills synced (core$([[ $WORKFLOW -eq 1 ]] && echo ' + workflow'))${kept_note}"
[[ -z "$WF_REASON" ]] || echo "  planning skills: $([[ $WORKFLOW -eq 1 ]] && echo vendored || echo 'not vendored') — ${WF_REASON}"
echo "  project-owned (update by hand): ${PROJECT_OWNED[*]} — check the upstream CHANGELOG for changes to carry over"
if [[ ${#overwrote[@]} -gt 0 ]]; then
  echo "  overwrote local edits: ${overwrote[*]} — these differed from the previous sync's upstream copy. Restore them from git (git checkout HEAD -- .agents/skills/<name>) and list the name under project_owned in .agents/skills/.mattpocock.json to keep them next time"
fi
