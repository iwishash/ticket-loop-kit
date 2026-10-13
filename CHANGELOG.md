# Changelog

## 0.6.0 — 2026-10-13

mattpocock 스킬을 "26개 전부 기본 설치"에서 "루프가 부르는 것만"으로 줄이고, 설치 전에 같은 스킬의 다른 설치를 검사한다. 질문은 "GitHub 이슈 구현 자동화 키트가 설치자에게 다른 사람의 방법론 스킬 26개를 강요하는 게 맞나"였다. 조사 결과 루프 스크립트는 스킬에 기대지 않고, `implement` 템플릿이 `tdd`와 `ticket-review` 둘만 Skill 도구로 부른다.

- `sync-mattpocock-skills.sh`: upstream `plugin.json` 전체 대신 두 묶음만 들인다. core(`tdd`, `code-review` → `ticket-review`)는 항상, workflow(`grill-with-docs`·`to-spec`·`to-tickets`·`retro`와 그것들이 부르는 `grilling`·`domain-modeling`·`writing-for-agents`)는 `--workflow`일 때만. 플래그가 없으면 지난 매니페스트의 선택을 따른다(0.5 이하 설치본은 `to-tickets`가 있었으니 유지). 지난 설치가 두 묶음 밖에 들인 스킬(0.5 이하의 26개 중 나머지 17개)은 **지우지 않고** `kept`로 이어 가며 같은 upstream 커밋으로 계속 동기화한다 — 키트가 넣은 것이니 사용자가 쓰고 있을 수 있다(`implement-spec`, `grill-me` 등). `--prune`을 줄 때만 지운다. 손으로 지운 것은 다시 들이지 않고, upstream에서 사라진 것은 그대로 둔다. `setup-matt-pocock-skills`만 역할이 대체됐으니 지운다. 본문의 `/setup-matt-pocock-skills` 안내는 `/setup-ticket-loop`로 바꾼다. `rsync` 대신 `rm -rf` + `cp -R`이라 `rsync`가 더는 필요 없다. `--ref <ref>`(옛 위치 인자도 받음), `--check [--json]`, `--force`, `--no-check`, `--prune`. 매니페스트에 `sets`·`workflow`·`kept`가 추가됐다. 테스트용 `MATTPOCOCK_UPSTREAM`
- 충돌 사전 검사(`--check`): Claude Code 문서의 이름 충돌 규칙을 근거로 다섯 가지를 본다 — 플러그인이 이 저장소에 켜짐(`enabledPlugins`를 user < project < local 순으로 병합, 둘 다 로드됨), `~/.claude/skills/<이름>`(개인 스킬이 프로젝트 스킬을 가림), `npx skills`의 `skills-lock.json`·심볼릭 링크(두 도구가 같은 디렉터리를 덮어씀 → 차단), `.claude/skills/code-review`(내장 `/code-review`를 대체), 매니페스트에 없는 같은 이름·`.claude/commands/`. 종료 코드 0 없음 · 1 경고 · 3 차단. Claude Code 자체는 중복을 경고하지 않는다
- `install.sh`: 아무것도 바꾸기 전에 `--check`를 돌려 차단이면 멈춘다(`--force-skills`로 강행, `--no-skills`로 건너뜀). `--workflow-skills`/`--no-workflow-skills`, `--prune-skills`. 템플릿 `docs/agents/issue-tracker.md`(upstream `issue-tracker-github.md` + 티켓 루프 관례, 없을 때만). Next steps에서 `/setup-matt-pocock-skills` 단계 제거
- `bin/ticket-loop-kit.js`: 설치 단계 체크리스트 전에 충돌 목록을 보여 주고, 항목이 "Vendor tdd + ticket-review"와 "Also vendor the planning skills"(지난 설치의 선택을 기본값으로)로 나뉘었다. 지난 설치가 두 묶음 밖에 들인 스킬이 있으면 "Remove the other skills an earlier install vendored" 항목이 생긴다(기본 꺼짐 = 유지). 플러그인이 켜져 있으면 "Disable plugin … for this repo" 항목이 생기고, 고르면 설치 뒤 `claude plugin disable <id> --scope project`를 돈다(`.claude/settings.json`에 남아 팀이 같이 받는다). `rsync` 경고 제거
- `setup-ticket-loop`: 전제에서 `/setup-matt-pocock-skills`를 뺐다. `docs/agents/issue-tracker.md`는 설치기 템플릿이 놓고, 없으면 설치 명령 재실행을 안내한다. `tdd`·`ticket-review` 존재 확인. 7단계가 `CLAUDE.md`의 `## Agent skills` 블록에 `### Issue tracker` 소제목을 보장한다(벤더링된 스킬이 트래커 설정을 그 블록으로 받는다)
- README(영·한)에 「mattpocock 스킬: 무엇을 들이고, 무엇을 검사하나」 절. 필요한 도구에서 `rsync` 제거. 가이드북 3장 표·4장 5·6단계·부록 E. PDF 재빌드
- `tests/smoke.sh`: 가짜 upstream 저장소로 동기화를 네트워크 없이 검사한다(core만 → 2개, `--workflow` → 9개, 자동 유지, `--no-workflow` → 7개 제거, 0.5 매니페스트에서 두 묶음 밖 스킬 유지·동기화(`kept`)·upstream에 없는 것 그대로·손으로 지운 것 복구 안 함·`setup-matt-pocock-skills` 제거·`--prune`으로 삭제, 이름 바꾸기·본문 치환, 프로젝트 소유 `implement` 유지). `--check`는 가짜 `HOME`으로 다섯 경우와 종료 코드, local이 project를 덮는 플러그인 판정, `--json`. `install.sh`와 npx 껍질이 차단 충돌에서 파일을 놓지 않고 멈춤. `issue-tracker.md` 템플릿 배치·유지
- `ticket-loop.sh`: 이번 실행에서 끝난 스펙(하위 이슈가 모두 닫혀 루프가 닫은 것)이 있으면 끝날 때 회고를 권하는 안내 한 줄을 남긴다 — `/retro`가 읽을 자료(로그, 스펙 리포트 또는 뽑는 방법, 병합된 PR 본문의 "남은 판단 사항"·"검증하지 못한 것")와, 저장소에 `retro` 스킬이 없으면 그 사실. 종료 알림에도 한 줄 붙는다. 권고일 뿐 회고를 자동으로 돌리지 않는다. `/retro`는 사람이 후보를 보고 고르는 대화형 스킬이고, 환경 수정은 PR로 가는 것이 맞고, 워커 세션 기록은 다른 경로·머신에 있을 수 있어서다
- 이미 설치된 저장소: 재설치해도 스킬이 사라지지 않는다. workflow 묶음과 두 묶음 밖의 17개가 모두 유지·갱신되고 `setup-matt-pocock-skills`만 지워진다. 덜어내고 싶으면 `--prune-skills`. `docs/agents/issue-tracker.md`가 이미 있으면(`/setup-matt-pocock-skills`가 만든 것) 그대로 둔다. 바뀐 것은 `git diff --stat .claude/skills`로 보고 PR에 넣는다

## 0.5.1 — 2026-10-13

- README를 영어로 바꿨다. 한국어 원문은 `README.ko.md`로 남긴다(같은 내용, 서로 링크)
- 스펙 리포트 HTML의 고정 문구(제목·열 이름·상태 배지·KPI 라벨·시간 단위·바닥글)를 영어로 바꿨다(`lang="en"`). GitHub에서 가져온 이슈·PR 제목과 본문, 기록의 중단 사유는 원문 그대로다. 기록 파일 `tickets.jsonl`의 값은 바뀌지 않고, `post_merge`("통과 N초"·"실패 N초"·"건너뜀")만 표시할 때 영어로 바꾼다. `tests/smoke.sh`의 기대 문구, 템플릿 `docs/loop-reports/README.md`, 가이드북 7장 9단계 표·부록 B, 부록 D 재생성

## 0.5.0 — 2026-10-13

실제 작업 프로젝트에서 루프를 돌리고 `/retro`를 한 결과 두 가지를 들여왔다.

- 스펙 이슈 자동 닫기. 티켓을 병합해 닫은 뒤(`--parent` 값, 없으면 GitHub의 부모 이슈)와 `--parent` 실행이 정상 종료할 때(티켓이 없어 리포트만 만드는 경우 포함), 스펙의 하위 이슈 목록을 세어 모두 닫혔으면 스펙 이슈를 코멘트와 함께 닫는다(`close_spec_if_done`). 요약 값 `sub_issues_summary`가 아니라 목록의 `state`를 센다 — 선행 이슈 요약처럼 늦게 바뀔 수 있어서. 하위 이슈가 없거나 하나라도 열려 있거나 스펙이 이미 닫혔으면 아무것도 하지 않고, 닫기에 실패하면 로그 한 줄로 알린다. 스펙 닫기가 리포트보다 먼저라 리포트 머리의 스펙 상태에 반영된다. `tests/smoke.sh`가 가짜 `gh`로 세 경우(모두 닫힘 → 닫는다, 하나 열림 → 안 닫는다, 하위 이슈 없음 → 안 닫는다)를 본다
- 손댄 무거운 테스트 파일 1회 실행. 워커 규칙·`implement`·`pr` 템플릿이 "무거운 테스트는 돌리지 말고 미실행이라고 적어라"에서 "전체는 돌리지 않되, 이번 티켓에서 추가·수정한 그 파일만 PR을 열기 직전에 1회 돌리고 파일과 결과를 PR 본문 '검증'에 적어라(손대지 않았으면 '없음')"로 바뀌었다. 워커가 새로 쓴 통합 테스트가 병합 뒤 검증에서 처음 돌아 깨지면 루프가 그 자리에서 멈추기 때문이다. 자리표 `__HEAVY_TESTS_RULE__`(자유 문장) 대신 `__HEAVY_TESTS__`(스위트 이름·경로)와 `__HEAVY_TEST_FILE__`(파일 하나를 돌리는 명령, 예 `pnpm exec vitest run --config vitest.integration.config.ts <file>`)을 쓰고, `/setup-ticket-loop`의 탐색 항목과 결정 표가 그 둘을 묻는다. 없으면 "없음"으로 그 줄·문단을 지운다
- 이미 설치된 저장소: 템플릿은 프로젝트 소유라 `install.sh`가 바꾸지 않는다. `.ticket-loop/worker-rules.md`의 무거운 테스트 줄과 `implement`의 검증 문단, `pr`의 "검증"·"검증하지 못한 것" 줄을 키트 템플릿을 보고 손으로 옮긴다. 스크립트와 `setup-ticket-loop`는 재설치로 바뀐다
- 가이드북: 4장 11단계 워커 규칙 예시, 7장 5·6단계, 11장 운영 리듬("스펙 이슈 닫기"를 사람 일에서 뺌), 12장 FAQ, 부록 B-2·B-3, 부록 D 재생성, 부록 E 두 행. PDF 재빌드

## 0.4.0 — 2026-10-13

키트 이름을 `agent-loop-kit`에서 `ticket-loop-kit`으로 바꿨다 — 루프의 단위는 에이전트가 아니라 티켓이다. 두 단계를 한 번에 했다.

- 저장소·패키지: GitHub 저장소 `iwishash/ticket-loop-kit`(옛 주소는 GitHub가 넘겨 주지만 설치 명령은 새 이름을 쓴다), `package.json` 이름·`bin`, 껍질 파일 `bin/ticket-loop-kit.js`, 설치 명령 `npx github:iwishash/ticket-loop-kit init`, `KIT_REPO` 기본값
- 설치본과의 약속: 설치 경로 `.agent-loop/` → `.ticket-loop/`, 스킬 `setup-agent-loop` → `setup-ticket-loop`, 설정 브랜치 `chore/ticket-loop-setup`, `.gitignore` 줄 `/.ticket-loop/*.log`·`*.jsonl`, `kit.json`·`loop.env`·`worker-rules.md` 경로. `ORCA_*`·`orca.yaml`은 그대로
- `install.sh` 0단계가 0.3 이하 설치본을 옮긴다 — `.agent-loop/`(없으면 `.orca-loop/`)를 `.ticket-loop/`로 `git mv`(로그·기록·`loop.env` 포함), 옛 스킬 두 이름 제거, `.gitignore`의 옛 줄 두 벌 제거, 옛 경로를 아직 가리키는 파일 목록 경고(네 이름 모두). 새 경로가 이미 있으면 옛 디렉터리는 경고와 함께 남긴다
- `tests/smoke.sh`: 0.3 설치본 마이그레이션 시나리오(`git mv` 이력, `loop.env`·`tickets.jsonl` 유지, 옛 스킬·`.gitignore` 줄 제거)와 옛 경로 둘이 함께 있을 때의 경고
- 가이드북: 본문의 경로·스킬 이름, 부록 D 재생성, 부록 E에 한 행. PDF 재빌드

README에 「여러 컴퓨터에서 같은 저장소를 돌릴 때」 절. 클론만으로 돌고 재설치는 키트 갱신 때만, 백엔드는 컴퓨터마다 환경변수로, 동시에 돌릴 때는 티켓을 나누고 스펙 리포트는 한 컴퓨터에서.

## 0.3.0 — 2026-10-12

cmux 백엔드를 실제 티켓 1건(boiler-webapp #39 → PR #40, cmux 0.65, 벽시계 7분, 수리 0회, idle 오판 0회, 정리·기록 정상)으로 확인했다. 초안이 문서로만 가정했던 것 중 두 가지가 틀려 고쳤다 — `--json`은 명령 뒤에 둬야 JSON이 나온다(앞에 두면 `OK workspace:N` 한 줄이라 jq가 id를 못 찾는다), `workspace close`는 에이전트 프로세스가 살아 있으면 `--force` 없이 `confirmation_required`로 거부한다. 옛 이름 `new-workspace` 대신 `workspace create`를 쓰고 `CMUX_QUIET=1`로 deprecation 줄을 막는다. 맞았던 가정: `workspace create --json --id-format uuids`의 `workspace_id`·`surface_id`, lane 이름 `todo|working|needs-attention|review|done`, `rpc surface.input_state`가 uuid를 받고 `--command`로 띄운 claude에 훅이 붙어 `lifecycle`을 보고하는 것(워크스페이스 셸의 PATH 앞에 cmux의 claude shim이 있다). README·npx 껍질·가이드 개정 이력에서 "초안"을 뺐다.

고침: 백엔드 분리 때 들어간 `orca_set_status`의 `local` 한 문장이 같은 문장에서 선언한 `status`를 바로 써서 `set -u`에 걸려, 첫 실제 티켓(boiler-webapp #34)에서 워크트리를 만든 직후 루프가 죽었다(워커는 혼자 계속 돌았다). 줄을 나눴다. `tests/smoke.sh`가 가짜 `orca`로 Orca 백엔드 함수를 전부 한 번씩 불러 이런 실수를 잡는다.

npx 껍질의 프롬프트를 키보드로 고르는 방식으로 바꿨다. 백엔드는 ↑↓·j/k·숫자로 옮기고 Enter로 확정하는 목록, 설치 단계는 Space로 켜고 끄는 체크리스트(a 전부, n 없음)다. q·Esc·Ctrl+C로 중단한다(종료 코드 130). 출력에 색을 넣었다 — 터미널일 때만, `NO_COLOR`·`TERM=dumb`이면 끈다. 한글 폭을 세어 열을 맞추고, 설명은 터미널 폭에 맞게 잘라(…) 줄이 접히지 않게 하며, 다시 그릴 때는 실제 행 수만큼 올린다(좁은 창에서 제목 줄이 키마다 쌓이던 문제). 프롬프트 동안 커서를 숨긴다. origin 이 실제로 쓰는 주소(`git ls-remote --get-url`, insteadOf 적용)가 SSH면 "gh 토큰으로 push" 단계를 기본으로 끈다 — HTTPS 키체인 대기 문제가 없는 곳이라서. 의존성은 여전히 없다(readline raw 모드). 껍질·`install.sh`·스킬 동기화 스크립트가 화면에 찍는 글(프롬프트·진행 줄·다음 단계·도움말·경고)은 영어다. 설치되는 파일(`loop.env` 주석, 템플릿, 스킬)과 `ticket-loop.sh --help`는 그대로 한국어다. `install.sh`도 터미널일 때만 색을 넣고(`NO_COLOR`·`TERM=dumb` 존중) "Next steps"의 번호·명령을 칠한다.

`CI_SKIP_CMD`. 저장소 CI의 경로 필터가 순서 규칙이 있는 `paths` 목록처럼 정규식 하나로 안 써질 때, 바뀐 파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 저장소 스크립트를 꽂는다(`CI_SKIP_REGEX`보다 먼저 본다, 실패하면 기다리는 쪽). 문서·`--help`·설정 스킬의 문구를 "CI를 건너뛰는 규칙"에서 "저장소 CI의 경로 필터를 루프에 알려 주는 값, 필터가 없으면 비움"으로 고쳤다 — 루프가 정하는 규칙이 아니다.

이름에서 Orca를 뺐다. 설치 경로 `.orca-loop/` → `.agent-loop/`, 스킬 `setup-orca-loop` → `setup-agent-loop`, 설정 브랜치 `chore/agent-loop-setup`, 가이드북 제목 「티켓 무인 루프 가이드북」과 파일 `docs/ticket-loop-guide.pdf`. Orca 전용인 `ORCA_CLI`·`ORCA_ROOT_PATH`·`orca.yaml`은 그대로다. `install.sh`가 0.2 이하 설치본을 옮긴다 — `.orca-loop/`를 `git mv`(로그·기록 포함), 옛 스킬 디렉터리와 `.gitignore` 옛 줄 제거, 옛 경로를 아직 가리키는 파일 목록 경고. npx 껍질은 `loop.env`를 설치기 뒤에 써서 마이그레이션과 순서가 맞다. `tests/smoke.sh`에 마이그레이션 시나리오.

백엔드 분리. `ticket-loop.sh`가 워크트리·에이전트 터미널에 하는 일(Orca CLI 호출 11곳)을 함수 아홉 개(`_check`, `_worktree_create`, `_worktree_remove`, `_send`, `_type`, `_interrupt`, `_wait_idle`, `_tail`, `_set_status`)로 뽑고 `.orca-loop/loop.env`의 `BACKEND=orca|cmux`로 고른다. Orca 구현은 명령이 그대로다. cmux 구현은 초안이다 — 루프가 `git worktree add` + `WORKTREE_SETUP_CMD`로 워크트리를 준비하고 `cmux new-workspace --command`로 에이전트를 띄우며, idle은 `cmux rpc surface.input_state`의 `lifecycle`을 폴링한다(이벤트 이름에 기대지 않는다). 새 변수 `BACKEND`, `CMUX_CLI`, `WORKTREE_DIR`, `WORKTREE_SETUP_CMD`. 로그 첫 줄에 백엔드를 적고, 스펙 리포트 머리말에서 "ORCA"를 뺐다. `tests/smoke.sh`가 두 백엔드의 함수 집합이 같은지와 공통부가 백엔드 CLI를 직접 부르지 않는지 검사한다. npx 껍질에서 cmux를 고를 수 있다(초안 표시). `/setup-orca-loop` 결정 표에 `BACKEND`·`WORKTREE_SETUP_CMD`.

npx 껍질. 설치 명령이 `npx github:iwishash/agent-loop-kit init`이 됐다(저장소가 비공개라 npm 발행 대신 github: 경로. 공개로 돌리면 그대로 동작하고, 그때 npm에 올리면 `npx agent-loop-kit init`으로 짧아진다). `bash <(gh api …)` 경로는 그대로 남는다.

- `package.json`·`bin/agent-loop-kit.js`: Node 18+, 의존성 없음. 백엔드를 묻고(지금은 Orca만, cmux는 백엔드 분리 뒤), 설치 단계를 켜고 끄고, `.orca-loop/loop.env`에 `BACKEND="${BACKEND:-orca}"` 줄을 쓴 뒤(파일이 없으면 만들고, 있으면 그 줄만 없을 때 덧붙인다) 검증된 `install.sh`를 `KIT_DIR`로 부른다. 터미널이 아니거나 `--yes`면 묻지 않는다
- `install.sh`: `KIT_COMMIT` 환경변수를 받는다. npx가 받은 패키지에는 `.git`이 없어 껍질이 npx 캐시의 `package-lock.json`에서 커밋을, `package.json` 스펙에서 `#ref`를 읽어 `kit.json`에 `commit`·`ref`(`npx` / `npx#v0.3.0` / `local`)로 남긴다
- `tests/smoke.sh`: 껍질 문법·버전 일치, 임시 저장소에 `--yes` 설치, 재실행이 `loop.env`를 바꾸지 않음, `BACKEND` 줄 없는 `loop.env`에 덧붙임, cmux·모르는 인자 거절
- 확인한 것: `npx --yes git+file://<키트 복사본>` 과 `#<태그>` 로 받아 임시 저장소에 설치되고 `kit.json`에 커밋·ref가 남는다(이 PC). 푸시 뒤 `npx github:iwishash/agent-loop-kit init --yes`와 `#main` 고정형도 빈 npm 캐시·HTTPS(키체인 자격 증명)로 실제 설치됨

## 0.2.0 — 2026-10-12

저장소 이름을 `orca-loop-kit`에서 `agent-loop-kit`으로 바꿨다(GitHub가 옛 주소를 새 주소로 넘겨 주지만 설치 명령은 새 이름을 쓴다). 설치 경로 `.orca-loop/`, 스킬 `setup-orca-loop`, `ORCA_*` 변수는 그대로다 — 설치된 저장소와의 약속이고, Orca가 아직 유일한 백엔드이기 때문이다.

rsrehab/rental-portal의 가이드북 3판(PR #80, 두 번째 스펙 실측)을 들여왔다. `install.sh`를 다시 돌리면 `ticket-loop.sh`와 `setup-orca-loop`가 바뀌고 `.gitignore`에 한 줄, `docs/loop-reports/README.md`가 더해진다.

- `ticket-loop.sh`
  - 스펙 리포트: `--parent` 실행이 정상 종료하면 `REPORT_DIR/spec-<N>.html`(티켓별 상태·결과 브리프·경과 시간·모델·마친 시각)을 jq로 그린다. 티켓마다 `RECORDS_FILE`(`.orca-loop/tickets.jsonl`)에 기록 한 줄을 남기고(`merged`·`no-merge`·`stopped`), 기록이 없는 티켓은 PR 시각으로 대신한다. 끝난 스펙은 `--parent`를 다시 돌리면 리포트만 만든다. 새 변수 `RECORDS_FILE`, `REPORT_DIR`, `MODEL_REGEX`
  - 포트 대기: `POST_MERGE_PORT`가 차 있으면 점유 프로세스(`node pid …`)와 기한을 한 줄 적고 30초마다 다시 본다. 시작할 때 이미 차 있으면 "주의" 한 줄(키트 추가분 — 멈추지 않는다)
  - 터미널 재시도: `orca terminal wait`가 타임아웃도 아닌 이상 응답으로 끝나면(사람이 Orca에서 워커 워크트리를 열 때) 터미널 읽기를 10초 간격 5번 다시 해 보고, 전부 실패할 때만 끊긴 것으로 본다
  - 티켓 처리 중 `die`하면 그 티켓을 `stopped`로 기록한다
- `install.sh`: `.gitignore`에 `/.orca-loop/*.jsonl`, 템플릿 `docs/loop-reports/README.md`(없을 때만)
- `/setup-orca-loop`: 결정 표에 `POST_MERGE_PORT`·`REPORT_DIR`, 운영 문서에 스펙 리포트 검수와 포트 대기(R10) 안내
- `docs/`: 가이드북 3판(PDF·HTML). 부록 E에 키트 추가분 한 행
- `tests/smoke.sh`: 리포트 jq를 고정 자료로 그려 본다, `.gitignore` jsonl 줄과 리포트 README 확인

## 0.1.0 — 2026-10-12

첫 공개. rsrehab/rental-portal의 티켓 루프(v1.7 실측, 가이드북 2판 PR #63)에서 범용 부분을 떼어 냈다.

- `install.sh`: 관리 파일 덮어쓰기, 템플릿은 없을 때만, mattpocock 스킬 벤더링, `.gitignore`·`deny` 병합, 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록, `.orca-loop/kit.json`
- `/setup-orca-loop` 스킬: 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`·`pr`을 저장소에 맞춰 채우고 PR
- `ticket-loop.sh`: 가이드북 2판 스크립트 + 저장소별 기본값 파일 `.orca-loop/loop.env`
- `docs/`: 가이드북 2판(PDF·HTML·빌드 스크립트)
