---
name: setup-agent-loop
description: "agent-loop-kit 설치 뒤, 이 저장소에 맞게 티켓 무인 루프의 프로젝트별 설정(검증 명령·orca.yaml·CI·워커 규칙·implement)을 채우고 PR을 연다."
disable-model-invocation: true
---

<!-- agent-loop-kit 관리 파일: install.sh가 덮어쓴다. 고칠 때는 키트 저장소에서 고친다. -->

`install.sh`가 놓은 템플릿의 `__PLACEHOLDER__`를 이 저장소의 사실로 채우고, 루프가 기대는 저장소 파일을 갖춘다. 판단 근거는 가이드북(키트 `docs/ticket-loop-guide.pdf`) 4장이다. 결과는 브랜치 하나와 PR 하나다.

## 1. 전제 확인

- `.agent-loop/kit.json`이 있다. 없으면 키트 설치부터 하라고 안내하고 멈춘다.
- `docs/agents/issue-tracker.md`가 있다. 없으면 사용자에게 `/setup-matt-pocock-skills`를 먼저 실행하라고 하고 멈춘다(사용자만 부를 수 있는 스킬이다).

## 2. 탐색

아래를 읽어 사실을 모은다. 추측한 값은 "추정"으로 표시해 둔다.

- 기본 브랜치: `gh repo view --json defaultBranchRef`
- 언어·패키지 관리자: lockfile(`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock` …), `packageManager` 필드
- 기존 명령: `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`의 lint·typecheck·test·build. 단일 테스트 파일을 돌리는 방법
- CI: `.github/workflows/*`의 트리거·`paths`/`paths-ignore`, 실행 명령
- 무거운 테스트: 실제 서버·DB·고정 포트를 쓰는 통합·E2E 스위트와 그 명령, 쓰는 포트, 필요한 env 파일
- DB 마이그레이션 도구와 번호 규칙, 개발·운영 DB를 가르는 단서(env 파일의 호스트)
- `.env*` 파일 이름(내용은 출력하지 않는다)
- `CLAUDE.md`/`AGENTS.md`의 `## Agent skills` 블록, 코딩 표준 문서 유무
- PR·문서에 쓰는 언어(최근 PR 몇 건)

## 3. 결정을 한 번에 확인받기

다음 표를 채워 사용자에게 보여 주고 한 번에 확인받는다. 추천값을 먼저 쓴다.

| 항목 | 값 |
|---|---|
| `BACKEND` | `orca` 또는 `cmux` — `.agent-loop/loop.env`에 이미 있으면(npx 설치기가 쓴다) 그 값. 워크트리·에이전트 터미널을 누가 맡나 |
| `WORKTREE_SETUP_CMD` | cmux일 때만. 새 워크트리에서 에이전트를 띄우기 전에 돌릴 의존성 설치·env 복사 명령(`LOOP_ROOT_PATH`, `LOOP_WORKTREE_PATH` 사용 가능). Orca는 `orca.yaml` setup이 같은 일을 한다 |
| `__BASE__` | 기본 브랜치 |
| `__TYPECHECK__` | 수시 타입 검사 명령(없으면 lint 중 빠른 것) |
| `__TEST_FILE__` | 단일 테스트 파일 실행 형태, 예 `pnpm exec vitest run <file>` |
| `__VERIFY__` | lint → 전체 테스트 → build 한 명령. 없으면 만들 스크립트 이름(예 `verify`) |
| `__PR_LANGUAGE__` | PR 본문 언어 |
| `__MIGRATION_RULE__` | 마이그레이션 규칙 한 문장, 또는 "없음"(줄 삭제) |
| `__HEAVY_TESTS_RULE__` | 워커가 돌리지 않을 무거운 테스트와 PR 표기 문구 |
| `orca.yaml` setup | 의존성 설치 명령, 복사할 env 파일과 안전 조건 |
| `POST_MERGE_CMD` 등 | 병합 뒤 검증 명령·복사 파일, 또는 끔 |
| `POST_MERGE_PORT` | 그 명령이 띄우는 고정 포트(예 `next dev`의 3000). 루프가 병합마다 비기를 기다리고, 시작할 때 차 있으면 알린다. 없으면 비움 |
| `REPORT_DIR` | 스펙 리포트 HTML 디렉터리. 기본 `docs/loop-reports`를 바꿀 이유가 있을 때만 |
| `CI_SKIP_REGEX` | CI가 건너뛰는 경로와 같은 정규식, 또는 없음 |

## 4. 쓰기

새 브랜치(`chore/agent-loop-setup`)를 `origin/<기본 브랜치>`에서 만들고 다음을 쓴다.

1. **`__VERIFY__` 명령**: 없으면 패키지 스크립트·Makefile 타깃으로 만든다(lint → 전체 테스트 → build 순서, 앞이 실패하면 멈춤).
2. **템플릿 채우기**: `.claude/skills/implement/SKILL.md`, `.claude/skills/pr/SKILL.md`, `.agent-loop/worker-rules.md`의 `__PLACEHOLDER__`를 모두 바꾼다. "없음"인 항목은 그 문장·줄을 지운다.
3. **`orca.yaml`**(`BACKEND=orca`일 때만): `scripts.setup`에 설치 명령, env 파일 복사(`$ORCA_ROOT_PATH` → `$ORCA_WORKTREE_PATH`, 운영 값이 섞이면 복사하지 않는 조건 포함), `setupAgentStartupPolicy: wait-for-setup`. 파일 맨 위 주석에 Orca 앱의 Command Source를 "orca.yaml only"로 바꿔야 쓰인다고 적는다.
4. **`.agent-loop/loop.env`**: 루프의 저장소별 기본값을 `VAR="${VAR:-값}"` 꼴로 쓴다(`BACKEND`, `CI_SKIP_REGEX`, `POST_MERGE_CMD`, `POST_MERGE_COPY`, `POST_MERGE_PORT`, cmux면 `WORKTREE_SETUP_CMD`, 필요하면 `MERGE_METHOD`). 이미 있는 줄(npx 설치기가 쓴 `BACKEND`)은 그대로 둔다.
5. **CI**: PR에서 도는 워크플로가 없으면 `__VERIFY__`를 도는 최소 워크플로를 만든다(비밀 값 없이). 경로 필터를 두면 `CI_SKIP_REGEX`와 같은 경로로 맞춘다.
6. **`docs/agents/ticket-loop.md`**: 이 저장소의 운영 문서. 흐름(`/grill-with-docs` → `/to-spec` → `/to-tickets` → `bash scripts/ticket-loop.sh --parent <스펙>` → 스펙 리포트 `docs/loop-reports/spec-<N>.html` 검수 → `/retro`), 실행 명령, 위 결정 표, 사람이 할 일(Orca 앱 설정, 병합, 리포트 PR 커밋), 복구는 가이드북 10장과 `bash scripts/ticket-state.sh N`을 가리킨다. `POST_MERGE_PORT`가 있으면 "실행 전 `lsof -nP -iTCP:<포트> -sTCP:LISTEN`으로 비어 있는지 본다"와 "로그가 '포트 … 사용 중'에서 조용하면 멈춤이 아니라 대기다(가이드북 R10)"를 적는다. 키트 버전은 `.agent-loop/kit.json`을 가리킨다.
   `docs/loop-reports/README.md`(키트 템플릿)는 `REPORT_DIR`를 바꿨을 때만 그 경로로 옮긴다.
7. **`CLAUDE.md`**(없으면 `AGENTS.md`)의 `## Agent skills` 블록에 두 줄을 더한다: 작업 흐름은 `docs/agents/ticket-loop.md`, 티켓 구현 절차는 `.claude/skills/implement/SKILL.md`가 단일 진실. 리뷰는 `ticket-review`.

## 5. 검증

다음이 모두 참이어야 끝난다.

- `grep -rn '__[A-Z_]*__' .claude/skills/implement .claude/skills/pr .agent-loop` 결과가 없다.
- `__VERIFY__`를 한 번 돌려 통과한다(실패하면 원인을 보고하고, 기존 실패인지 이번 변경 탓인지 가른다).
- `bash scripts/ticket-loop.sh --dry-run`이 저장소·기준 브랜치·병합 뒤 검증 설정을 찍고 정상 종료한다(`POST_MERGE_PORT`를 정했으면 그 포트가 차 있을 때 "주의: 포트 … 사용 중" 줄이 나오는지도 한 번 본다).
- `orca.yaml`의 setup 명령(cmux면 `WORKTREE_SETUP_CMD`)을 메인 체크아웃에서 그대로 실행해 성공한다(설치 명령만, 복사는 건너뛴다).

## 6. PR

`install.sh`가 바꾼 파일(스크립트, 스킬, `.gitignore`, `.claude/settings.json`, `.agent-loop/kit.json`)까지 함께 커밋하고 PR을 연다. 본문에 결정 표, 검증 결과, 사람이 할 일을 적는다.

- Orca면: Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source "orca.yaml only", "Wait for setup to complete before starting agent" 켜기. cmux면: 루프를 cmux 터미널 안에서 돌린다(소켓 모드 기본값 cmuxOnly)
- PR 병합(워커 규칙·스킬은 `origin/<기본 브랜치>`에 있어야 워커가 본다)
- 병합 뒤 작은 티켓 하나로 `bash scripts/ticket-loop.sh --max 1`을 지켜보기
