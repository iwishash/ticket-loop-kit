# Changelog

## Unreleased

npx 껍질의 프롬프트를 키보드로 고르는 방식으로 바꿨다. 백엔드는 ↑↓·j/k·숫자로 옮기고 Enter로 확정하는 목록, 설치 단계는 Space로 켜고 끄는 체크리스트(a 전부, n 없음)다. q·Esc·Ctrl+C로 중단한다(종료 코드 130). 출력에 색을 넣었다 — 터미널일 때만, `NO_COLOR`·`TERM=dumb`이면 끈다. 한글 폭을 세어 열을 맞추고, 설명은 터미널 폭에 맞게 잘라(…) 줄이 접히지 않게 하며, 다시 그릴 때는 실제 행 수만큼 올린다(좁은 창에서 제목 줄이 키마다 쌓이던 문제). 프롬프트 동안 커서를 숨긴다. origin 이 실제로 쓰는 주소(`git ls-remote --get-url`, insteadOf 적용)가 SSH면 "gh 토큰으로 push" 단계를 기본으로 끈다 — HTTPS 키체인 대기 문제가 없는 곳이라서. 의존성은 여전히 없다(readline raw 모드). 껍질·`install.sh`·스킬 동기화 스크립트가 화면에 찍는 글(프롬프트·진행 줄·다음 단계·도움말·경고)은 영어다. 설치되는 파일(`loop.env` 주석, 템플릿, 스킬)과 `ticket-loop.sh --help`는 그대로 한국어다.

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
