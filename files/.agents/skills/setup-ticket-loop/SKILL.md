---
name: setup-ticket-loop
description: "ticket-loop-kit 설치 뒤, 이 저장소에 맞게 티켓 무인 루프의 프로젝트별 설정(검증 명령·orca.yaml·CI·워커 규칙·implement)을 채우고 PR을 연다."
disable-model-invocation: true
---

<!-- ticket-loop-kit 관리 파일: install.sh가 덮어쓴다. 고칠 때는 키트 저장소에서 고친다. .agents/skills/ 에 있고 .claude/skills/setup-ticket-loop 는 링크다 — Claude Code(/setup-ticket-loop)와 Codex($setup-ticket-loop) 둘 다 부른다. -->

`install.sh`가 놓은 템플릿의 `__PLACEHOLDER__`를 이 저장소의 사실로 채우고, 루프가 기대는 저장소 파일을 갖춘다. 판단 근거는 가이드북(키트 `docs/ticket-loop-guide.pdf`) 4장이다. 결과는 브랜치 하나와 PR 하나다.

## 1. 전제 확인

- `.ticket-loop/kit.json`이 있다. 없으면 키트 설치부터 하라고 안내하고 멈춘다.
- `docs/agents/issue-tracker.md`가 있다. 설치기가 템플릿(GitHub 이슈를 `gh`로 읽고 쓰는 관례, 라벨, 티켓 루프 관례)을 없을 때만 놓는다. 없으면(0.5 이하 키트로 설치한 저장소) 설치 명령을 다시 실행하라고 안내하고 멈춘다. 벤더링된 `ticket-review`·`to-tickets`·`to-spec`과 이 저장소의 `implement`가 이 파일을 읽는다.
- `.agents/skills/tdd`와 `.agents/skills/ticket-review`가 있다(`implement`가 부른다). 없으면 `bash scripts/sync-mattpocock-skills.sh`를 돌리라고 안내한다. `.claude/skills/<이름>`은 그 링크다(0.6 이하 설치본은 실제 디렉터리 — 설치 명령을 다시 실행하면 옮겨진다).

## 2. 탐색

아래를 읽어 사실을 모은다. 추측한 값은 "추정"으로 표시해 둔다.

- 기본 브랜치: `gh repo view --json defaultBranchRef`
- 언어·패키지 관리자: lockfile(`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock` …), `packageManager` 필드
- 기존 명령: `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`의 lint·typecheck·test·build. 단일 테스트 파일을 돌리는 방법
- CI: `.github/workflows/*`의 트리거·`paths`/`paths-ignore`, 실행 명령
- 무거운 테스트: 실제 서버·DB·고정 포트를 쓰는 통합·E2E 스위트와 그 명령, 쓰는 포트, 필요한 env 파일. 그 스위트의 파일 하나만 돌리는 방법(별도 config·스크립트, 예 `pnpm exec vitest run --config vitest.integration.config.ts <file>`)
- DB 마이그레이션 도구와 번호 규칙, 개발·운영 DB를 가르는 단서(env 파일의 호스트)
- `.env*` 파일 이름(내용은 출력하지 않는다)
- `AGENTS.md`의 `## Agent skills` 블록(0.6 이하 설치본은 `CLAUDE.md`에 있다), `CLAUDE.md`에 `@AGENTS.md` 줄이 있는지, 코딩 표준 문서 유무
- `.ticket-loop/loop.env`의 `AGENT`(npx 설치기가 쓴다. 없으면 claude)
- PR·문서에 쓰는 언어(최근 PR 몇 건)

## 3. 결정을 한 번에 확인받기

다음 표를 채워 사용자에게 보여 주고 한 번에 확인받는다. 추천값을 먼저 쓴다.

| 항목 | 값 |
|---|---|
| `BACKEND` | `orca`, `cmux` 또는 `tmux` — `.ticket-loop/loop.env`에 이미 있으면(npx 설치기가 쓴다) 그 값. 워크트리·에이전트 터미널을 누가 맡나 |
| `AGENT` | `claude` 또는 `codex` — `loop.env`에 이미 있으면 그 값. 워커를 띄울 에이전트. 프리셋이 기동 명령·배너·스킬 접두사(`/implement` ↔ `$implement`)를 정한다. `codex`는 아직 실측 전이라고 표에 적는다 |
| `WORKTREE_SETUP_CMD` | cmux·tmux일 때만. 새 워크트리에서 에이전트를 띄우기 전에 돌릴 의존성 설치·env 복사 명령(`LOOP_ROOT_PATH`, `LOOP_WORKTREE_PATH` 사용 가능). Orca는 `orca.yaml` setup이 같은 일을 한다. env 파일에 운영 값(운영 DB 주소·키)이 섞여 있으면 통째로 복사하지 않는다 — 워커는 권한 확인을 끄고 돈다. 워커의 테스트가 실제 DB를 써야 하면 개발 값만 가리킬 때만 복사하는 조건을 걸고, 테스트 DB를 따로 띄우는 저장소면 `.env.example` 같은 운영 값 없는 파일을 쓴다 |
| `__BASE__` | 기본 브랜치 |
| `__TYPECHECK__` | 수시 타입 검사 명령(없으면 lint 중 빠른 것) |
| `__TEST_FILE__` | 단일 테스트 파일 실행 형태, 예 `pnpm exec vitest run <file>` |
| `__VERIFY__` | lint → 전체 테스트 → build 한 명령. 없으면 만들 스크립트 이름(예 `verify`) |
| `__PR_LANGUAGE__` | PR 본문 언어 |
| `__MIGRATION_RULE__` | 마이그레이션 규칙 한 문장, 또는 "없음"(줄 삭제) |
| `__HEAVY_TESTS__` | 워커가 전체를 돌리지 않을 무거운 스위트의 이름·경로(예 `통합 테스트(tests/integration/)·E2E`). 없으면 "없음" — `worker-rules.md`의 그 줄과 `implement`·`pr`의 그 문단·줄을 지운다 |
| `__HEAVY_TEST_FILE__` | 그 스위트의 파일 하나를 돌리는 명령(예 `pnpm exec vitest run --config vitest.integration.config.ts <file>`). 워커는 자기가 추가·수정한 파일만 PR 직전 1회 돌리고, 전체는 루프가 병합 뒤(`POST_MERGE_CMD`) 돌린다 |
| `orca.yaml` setup | 의존성 설치 명령, 복사할 env 파일과 안전 조건 |
| `POST_MERGE_CMD` 등 | 병합 뒤 검증 명령·복사 파일, 또는 끔 |
| 스펙 끝 분기 | 무거운 스위트가 있을 때만 사용자에게 묻는다: 스펙이 끝날 때만 더 무겁게 돌릴 것이 있나(공유·클라우드 DB, 더 넓은 스위트·E2E). 있으면 그 무거운 쪽과 고르는 방법을 적고 아래 "스펙 끝 분기"대로 건다. 없으면 "없음" |
| `POST_MERGE_PORT` | 그 명령이 띄우는 고정 포트(예 `next dev`의 3000). 루프가 병합마다 비기를 기다리고, 시작할 때 차 있으면 알린다. 없으면 비움 |
| `POST_MERGE_RETRY_CMD` | `POST_MERGE_CMD`가 실패했을 때 딱 한 번 돌릴 재실행 명령. 그 스위트에 병합과 무관한 플레이크(시간 초과 등)가 있을 때만 — 사용자에게 묻는다. 같은 검증 워크트리에서 `POST_MERGE_FAILED_LOG`(첫 실행 로그 절대 경로)를 받아 돌고, 통과하면 루프는 계속 가며 이슈에 플레이크 의심 코멘트를 남긴다. 실패한 테스트만 다시 돌리는 저장소 스크립트(아래)를 만들어 커밋하고 그 스크립트를 건다. `POST_MERGE_EVERY`가 1이 아니면(기본 4) 묶음 실패의 원인 병합을 찾는 데도 이 명령을 지난 커밋에서 돌린다 — 설치된 의존성에 기대면 앞에 설치 명령을 붙인다(아래 예). 없으면 비움 |
| `POST_MERGE_EVERY` | 병합 뒤 검증을 병합 몇 개마다 돌리나. 기본 4 — 그대로면 `loop.env`에 쓰지 않는다. 그 명령이 짧으면(몇 분) 사용자에게 묻고 1(병합마다)을 권한다 — 묶어도 아끼는 시간이 없고 어느 병합이 깨뜨렸는지만 흐려진다. 0이면 개수로는 돌리지 않고 스펙·실행이 끝날 때만 돈다(깨진 기본 브랜치 위에 스펙 전체가 쌓일 수 있다). 스펙·실행이 끝날 때는 늘 돌고, 그 사이 병합은 다음 검증이 덮는다. 묶음이 실패하면 루프가 `POST_MERGE_RETRY_CMD`로 처음 실패하는 병합을 찾으므로, 묶을 때는 재실행 명령도 두기를 권한다 |
| `LOOP_TRIAGE` | 멈출 일(병합 뒤 검증 실패, 수리를 다 쓴 CI 실패·충돌, 워크트리 준비 실패, PR 없이 멈춘 워커)이 생기면 루프가 멈추기 전에 수습 세션을 띄워 `loop-triage` 스킬로 고쳐 보게 할지. 기본 켬(1) — `loop.env`에 쓰지 않는다. 수습 세션이 낸 수정 PR도 CI 뒤 사람 검토 없이 병합되므로, 그게 이 저장소에서 안 되는 이유가 있을 때만 사용자에게 묻고 `0`. 한 실행 횟수(`TRIAGE_MAX`, 기본 1)·제한 시간(`TRIAGE_TIMEOUT_SEC`, 기본 3600)은 바꿀 이유가 있을 때만 |
| `REPORT_DIR` | 스펙 리포트 HTML 디렉터리. 기본 `docs/loop-reports`를 바꿀 이유가 있을 때만 |
| `REPORT_OPEN` | 리포트를 쓴 뒤 기본 브라우저로 열기. 기본 켬(1). 끌 이유가 있을 때만 `0` — SSH 세션·화면 없는 Linux에서는 값과 무관하게 열지 않는다 |
| `CI_SKIP_REGEX` / `CI_SKIP_CMD` | 워크플로에 경로 필터(`paths`/`paths-ignore`)가 있을 때만. 루프가 그 필터를 따라 하도록 알려 주는 값이다 — 단순 제외 목록이면 정규식, 순서 규칙이 있으면 파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 저장소 스크립트. 필터가 없으면 둘 다 비움 |

`POST_MERGE_RETRY_CMD`를 쓰면 무엇을 다시 돌릴지는 저장소 스크립트가 정한다(키트는 테스트 도구에 묶이지 않는다). 검증 워크트리는 병합된 기본 브랜치라 스크립트가 커밋돼 있어야 돈다. vitest 예(`scripts/post-merge-retry.sh`, `POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh}"` — 앞의 설치는 이 저장소의 패키지 매니저 명령으로 바꾼다. 이미 설치돼 있으면 몇 초면 끝나고, 묶음 실패의 원인 병합을 찾을 때 지난 커밋의 의존성을 맞춘다) — 다른 도구면 그 도구의 실패 줄 모양에 맞게 고친다:

```bash
files=$(perl -pe 's/\e\[[0-9;]*m//g' "$POST_MERGE_FAILED_LOG" \
  | grep -oE 'FAIL +[^ ]+\.test\.ts' | awk '{print $2}' | sort -u)
[ -n "$files" ] || { echo "no failed test files found — not retrying"; exit 1; }
pnpm exec vitest run --config vitest.integration.config.ts $files
```

실패한 파일을 못 찾으면(설치·환경 점검 단계에서 실패) 다시 돌리지 않고 실패로 끝내야 한다 — 진짜 깨진 기본 브랜치가 재실행에 묻히지 않게. 로그에 ANSI 색 코드가 섞여 있고 macOS 기본 `sed`는 `\x1b`를 못 알아들어 `perl`로 지운다.

**스펙 끝 분기.** 루프는 병합 뒤 검증 명령(첫 실행·재실행·이분 탐색·수습 뒤 재검증)에 env 둘을 넘긴다. `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`는 이 검증이 스펙을 끝낸 병합을 덮으면 그 스펙 번호, 아니면 빈 값이다. `TICKET_LOOP_POST_MERGE_WHY`는 `every`·`spec_end`·`run_end`다. 무거운 쪽은 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`로 고른다 — 루프가 창이 찼는지를 먼저 보므로 `POST_MERGE_EVERY=1`이면 스펙 끝의 검증도 `WHY`가 `every`다. 고르는 부분은 한 파일에 두고 첫 실행 스크립트와 재실행 스크립트(`POST_MERGE_RETRY_CMD`를 쓰면)가 둘 다 맨 앞에서 source 한다. 재실행도 같은 값을 받으므로, 실패한 검증과 같은 쪽에서 다시 돈다. 스크립트를 커밋하고(검증 워크트리는 병합된 기본 브랜치다) `POST_MERGE_CMD="${POST_MERGE_CMD:-bash scripts/post-merge.sh}"`로 건다. `POST_MERGE_EVERY`는 가벼운 쪽의 길이로 정한다(몇 분이면 1 — 평소 검증은 병합마다, 무거운 쪽은 스펙마다 한 번). 무거운 쪽이 쓰는 비밀 값(공유 DB 주소 등)은 스크립트에 쓰지 않고 `POST_MERGE_COPY`로 복사되는 env 파일에서 읽게 한다:

```bash
# scripts/post-merge-env.sh — 첫 실행·재실행 스크립트가 맨 앞에서 source 한다
if [ -n "${TICKET_LOOP_POST_MERGE_SPEC_COMPLETE:-}" ]; then
  export TEST_DB=shared   # 무거운 쪽 — 이 저장소가 공유 DB·넓은 스위트를 고르는 방법으로 바꾼다
else
  export TEST_DB=local
fi
echo "post-merge: TEST_DB=${TEST_DB} (spec complete: ${TICKET_LOOP_POST_MERGE_SPEC_COMPLETE:-none})"
```

```bash
# scripts/post-merge.sh — POST_MERGE_CMD
. scripts/post-merge-env.sh
pnpm run test:integration   # 이 저장소의 무거운 스위트 명령
```

재실행 스크립트(위 `scripts/post-merge-retry.sh`)는 첫 줄에 `. scripts/post-merge-env.sh`를 더한다.

## 4. 쓰기

새 브랜치(`chore/ticket-loop-setup`)를 `origin/<기본 브랜치>`에서 만들고 다음을 쓴다.

1. **`__VERIFY__` 명령**: 없으면 패키지 스크립트·Makefile 타깃으로 만든다(lint → 전체 테스트 → build 순서, 앞이 실패하면 멈춤).
2. **템플릿 채우기**: `.agents/skills/implement/SKILL.md`, `.agents/skills/pr/SKILL.md`, `.ticket-loop/worker-rules.md`의 `__PLACEHOLDER__`를 모두 바꾼다. "없음"인 항목은 그 문장·줄을 지운다. `.codex/rules/ticket-loop.rules`(Codex 워커의 병합·강제 push 금지 — `.claude/settings.json`의 `deny`와 같은 내용)는 설치기가 기본 브랜치를 채워 놓는다 — 자리표가 남아 있지 않은지만 본다.
3. **`orca.yaml`**(`BACKEND=orca`일 때만): `scripts.setup`에 설치 명령, env 파일 복사(`$ORCA_ROOT_PATH` → `$ORCA_WORKTREE_PATH`, 운영 값이 섞이면 복사하지 않는 조건 포함), `setupAgentStartupPolicy: wait-for-setup`. 파일 맨 위 주석에 Orca 앱의 Command Source를 "orca.yaml only"로 바꿔야 쓰인다고 적는다.
4. **`.ticket-loop/loop.env`**: 루프의 저장소별 기본값을 `VAR="${VAR:-값}"` 꼴로 쓴다(`BACKEND`, `AGENT`, `CI_SKIP_REGEX`, `POST_MERGE_CMD`, `POST_MERGE_RETRY_CMD`, `POST_MERGE_COPY`, `POST_MERGE_PORT`, 기본 4와 다를 때만 `POST_MERGE_EVERY`, cmux·tmux면 `WORKTREE_SETUP_CMD`, 필요하면 `MERGE_METHOD`, 끌 때만 `LOOP_TRIAGE`). 이미 있는 줄(npx 설치기가 쓴 `BACKEND`·`AGENT`)은 그대로 둔다.
5. **CI**: PR에서 도는 워크플로가 없으면 `__VERIFY__`를 도는 최소 워크플로를 만든다(비밀 값 없이, 경로 필터 없이 — 필터는 저장소가 원할 때 두는 것이다). 이미 경로 필터가 있으면 `CI_SKIP_REGEX` 또는 `CI_SKIP_CMD`를 같은 판정이 나오게 맞추고, 문서만 바꾸는 PR과 코드 PR을 하나씩 떠올려 둘 다 맞는지 확인한다.
6. **`docs/agents/ticket-loop.md`**: 이 저장소의 운영 문서. 흐름(`/grill-with-docs` → `/to-spec` → `/to-tickets` → `bash scripts/ticket-loop.sh --parent <스펙>` → 스펙 리포트 `docs/loop-reports/spec-<N>.html` 검수 → `/retro`; Codex에서는 `/`를 `$`로), 실행 명령, 위 결정 표, 사람이 할 일(Orca 앱 설정, 병합, 리포트 PR 커밋, Codex면 저장소 `.codex/` 신뢰), 복구는 가이드북 10장과 `bash scripts/ticket-state.sh N`을 가리킨다. `POST_MERGE_PORT`가 있으면 "실행 전 `lsof -nP -iTCP:<포트> -sTCP:LISTEN`으로 비어 있는지 본다"와 "로그가 '포트 … 사용 중'에서 조용하면 멈춤이 아니라 대기다(가이드북 R10)"를 적는다. `POST_MERGE_CMD`가 있으면 "병합 뒤 검증 로그는 `LOG_FILE`과 같은 디렉터리의 `post-merge-N.log`(기본 저장소 루트의 `.ticket-loop/post-merge-N.log`)이고 루프의 '병합 뒤 검증 시작'·ERROR 줄에 절대 경로가 찍힌다. 검증 워크트리 안이 아니다"도 적는다(R10). `POST_MERGE_RETRY_CMD`가 있으면 "실패하면 한 번 재실행하고 출력은 같은 디렉터리의 `post-merge-N-retry.log`다. 재실행에서 통과하면 이슈에 '병합 뒤 검증 재시도 통과 — 플레이크 의심' 코멘트가 달리고 루프는 계속 간다 — 같은 테스트가 되풀이되면 고칠 대상이다. 재실행까지 실패하면 ERROR 줄에 두 로그가 찍힌다"도 적는다. `POST_MERGE_CMD`가 있고 `POST_MERGE_EVERY`가 1이 아니면(기본 4) "병합 뒤 검증은 병합 N개마다(0이면 개수로는 돌지 않는다)와 스펙·실행이 끝날 때 돈다. 그 사이 티켓의 요약·리포트에는 'deferred'가 찍히고, 다음 검증이 그 병합을 덮는다. 묶음이 실패하면 루프가 처음 실패하는 병합을 찾아 멈춤 사유에 적는다(검증 로그 옆 `post-merge-N-bisect-<커밋>.log`)"도 적는다. 스펙 끝 분기를 걸었으면 "스펙을 끝낸 병합을 덮는 검증만 <무거운 쪽>으로 돈다(`scripts/post-merge-env.sh`가 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`로 고른다). 어느 쪽이었는지는 검증 로그 첫 두 줄(루프가 넘긴 값, 스크립트가 고른 쪽)과 스펙 리포트의 '(…, spec #N complete)'로 본다"도 적는다. 무인 수습이 켜져 있으면(기본) "멈출 일이 생기면 루프가 먼저 수습 세션을 띄우고 판정을 기다린다. Slack에 '수습 시작'이 오면 기다리면 된다 — 고쳐지면 '이어 감'이, 아니면 진단이 붙은 멈춤 알림이 온다. 수습 세션의 수정 PR에는 `loop-triage` 라벨이 붙으니 나중에 몰아서 본다. 멈출 때마다 `.ticket-loop/stops/<id>.json`이 남고, 직접 이어받으려면 `/loop-triage <id>`(가이드북 10.6)"도 적는다. 키트 버전은 `.ticket-loop/kit.json`을 가리킨다.
   `docs/loop-reports/README.md`(키트 템플릿)는 `REPORT_DIR`를 바꿨을 때만 그 경로로 옮긴다.
7. **`AGENTS.md`**의 `## Agent skills` 블록이 정본이다(Codex는 `AGENTS.md`만 읽고, Claude Code는 `CLAUDE.md`를 읽는다). 없으면 만든다. 블록 안에 `### Issue tracker` 소제목과 "Issues live in GitHub Issues. See `docs/agents/issue-tracker.md`." 한 줄이 있어야 한다 — 벤더링된 스킬은 트래커 설정을 이 블록으로 받는다(없으면 `/setup-ticket-loop`를 실행하라고 사용자에게 되묻는다). 이어서 두 줄을 더한다: 작업 흐름은 `docs/agents/ticket-loop.md`, 티켓 구현 절차는 `.agents/skills/implement/SKILL.md`가 단일 진실. 리뷰는 `ticket-review`. 블록이 이미 있으면 그 안을 고치고 중복 블록을 만들지 않는다. 블록이 `CLAUDE.md`에 있으면(0.6 이하 설치본) `AGENTS.md`로 옮긴다. 그다음 `CLAUDE.md`에 `@AGENTS.md` 한 줄이 있게 한다(없으면 맨 위에 더한다. `CLAUDE.md`가 없으면 그 한 줄로 만든다) — Claude Code가 가져오기 문법으로 `AGENTS.md`를 읽는다.

## 5. 검증

다음이 모두 참이어야 끝난다.

- `grep -rn '__[A-Z_]*__' .agents/skills/implement .agents/skills/pr .ticket-loop .codex` 결과가 없다.
- `.claude/skills/implement`, `.claude/skills/pr`, `.claude/skills/tdd`, `.claude/skills/ticket-review`, `.claude/skills/loop-triage`가 `.agents/skills/<이름>`을 가리키는 링크다(`ls -l .claude/skills`).
- `__VERIFY__`를 한 번 돌려 통과한다(실패하면 원인을 보고하고, 기존 실패인지 이번 변경 탓인지 가른다).
- `bash scripts/ticket-loop.sh --dry-run`이 저장소·기준 브랜치·병합 뒤 검증 설정을 찍고 정상 종료한다(`POST_MERGE_PORT`를 정했으면 그 포트가 차 있을 때 "주의: 포트 … 사용 중" 줄이 나오는지도 한 번 본다).
- `orca.yaml`의 setup 명령(cmux·tmux면 `WORKTREE_SETUP_CMD`)을 메인 체크아웃에서 그대로 실행해 성공한다(설치 명령만, 복사는 건너뛴다).
- 스펙 끝 분기를 걸었으면 고르는 부분을 두 값으로 한 번씩 source 해 각각 가벼운 쪽·무거운 쪽을 고른다: `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE= bash -c '. scripts/post-merge-env.sh'`와 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE=1 bash -c '. scripts/post-merge-env.sh'`. 스위트 자체는 돌리지 않는다.

## 6. PR

`install.sh`가 바꾼 파일(스크립트, `.agents/skills/`와 `.claude/skills/` 링크, `.codex/rules/`, `.gitignore`, `.claude/settings.json`, `.ticket-loop/kit.json`)까지 함께 커밋하고 PR을 연다. 본문에 결정 표, 검증 결과, 사람이 할 일을 적는다.

- Orca면: Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source "orca.yaml only", "Wait for setup to complete before starting agent" 켜기. cmux면: 루프를 cmux 터미널 안에서 돌린다(소켓 모드 기본값 cmuxOnly). tmux면: `tmux`가 설치돼 있으면 된다 — 워커 창은 `tmux attach -t ticket-loop`으로 본다
- PR 병합(워커 규칙·스킬은 `origin/<기본 브랜치>`에 있어야 워커가 본다)
- 스펙 끝 분기의 무거운 쪽이 비밀 값을 쓰면: 루프를 돌리는 기계마다 메인 체크아웃의 그 env 파일(`POST_MERGE_COPY`)에 값을 둔다
- `AGENT=codex`면: 이 저장소의 `.codex/`를 Codex에서 신뢰해야 `.codex/rules`가 적용된다. `--dangerously-bypass-approvals-and-sandbox` 아래에서도 유지되는지는 실측 전이니 GitHub 브랜치 보호를 켠다
- 병합 뒤 작은 티켓 하나로 `bash scripts/ticket-loop.sh --max 1`을 지켜보기
