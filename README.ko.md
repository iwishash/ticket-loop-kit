# ticket-loop-kit

GitHub 이슈 티켓을 워크트리에서 한 건씩 무인으로 구현·검증·병합하는 **티켓 루프**를 다른 저장소에 설치하고 업데이트하는 키트. 워크트리와 에이전트 터미널은 백엔드(Orca 또는 cmux)가 맡는다.
원리와 운영은 [「티켓 무인 루프 가이드북」](docs/ticket-loop-guide.pdf)에 있다.
영문 README는 [README.md](README.md)다(이 파일이 한국어 원문).

## 설치

대상 저장소 루트에서:

```bash
npx github:iwishash/ticket-loop-kit init
```

백엔드와 설치 단계를 키보드로 고르고(↑↓·숫자·Space·Enter, q로 중단) `install.sh`를 부른 뒤 `.ticket-loop/loop.env`에 `BACKEND=` 줄을 쓴다. 묻지 않으려면 `--yes`(터미널이 아니면 자동). 색은 `NO_COLOR`로 끈다. SSH 별칭 원격이나 키체인 자격 증명을 쓰면 `gh auth setup-git`은 필요 없다. 키트 버전을 고정하려면 `npx github:iwishash/ticket-loop-kit#v0.5.1 init`. 저장소가 비공개인 동안은 이 저장소에 초대받고 `gh auth login` 뒤 `gh auth setup-git`을 한 번 해 두면 npx가 받아 간다(macOS 키체인에 GitHub 자격 증명이 있어도 된다).

npx 없이 bash로만 설치하려면:

```bash
bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

그다음 Claude Code에서:

1. `/setup-matt-pocock-skills` — `docs/agents/issue-tracker.md`가 아직 없을 때
2. `/setup-ticket-loop` — 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`를 이 저장소에 맞춰 채우고 PR을 연다

마지막으로 Orca 앱에서 Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기. PR을 병합한 뒤 `bash scripts/ticket-loop.sh --dry-run` → `--max 1`.

필요한 도구: `git`, `gh`(로그인), `jq`, `rsync`, Orca 앱과 CLI, Claude Code.

## 누가 무엇을 하나

| 주체 | 하는 일 |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) — 질문과 껍질 | 백엔드 선택, `.ticket-loop/loop.env`의 `BACKEND=` 줄(없을 때만), 설치 단계 켜고 끄기, 도구 점검, 설치한 키트 커밋을 `install.sh`에 넘김 |
| `install.sh` — 어느 저장소에서나 같은 부분 | 루프·진단·스킬 동기화 스크립트와 `setup-ticket-loop` 스킬 설치, mattpocock 스킬 벤더링(`code-review` → `ticket-review`), `.gitignore`·`deny` 병합, 라벨 6개, git 자격 증명(gh), Orca 등록, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` — 저장소를 읽어야 정하는 부분 | `implement`·`pr`·`worker-rules.md`의 `__PLACEHOLDER__` 채우기(검증 명령, 무거운 스위트와 그 파일 하나를 돌리는 명령 — 워커는 자기가 손댄 파일만 PR 직전 1회, 전체는 루프가 병합 뒤), `verify` 명령, `orca.yaml`, CI, `.ticket-loop/loop.env`, `docs/agents/ticket-loop.md`, `CLAUDE.md` 포인터 → PR |
| 사람 | Orca 앱 설정(Command Source "orca.yaml only"), PR 병합, `--max 1` 시험 지켜보기 |

키트의 `ticket-loop.sh`는 가이드북 3판 부록 D의 스크립트에 저장소별 기본값 파일 `.ticket-loop/loop.env` 읽기와 시작 전 포트 점검을 더한 것이다. `POST_MERGE_CMD`, `POST_MERGE_PORT` 같은 저장소 고정값은 거기에 `VAR="${VAR:-값}"` 꼴로 적어 커밋하고, 실행할 때 준 환경변수가 이긴다.

저장소 CI가 경로 필터(`paths`/`paths-ignore`)로 일부 PR에서 돌지 않는다면 `CI_SKIP_REGEX`(단순 제외 목록) 또는 `CI_SKIP_CMD`(파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 저장소 스크립트)로 같은 판정을 루프에 알려 준다. GitHub는 필터에 걸린 PR에 체크를 아예 만들지 않아 루프가 "아직 안 떴다"와 "안 뜬다"를 구별할 수 없기 때문이다. 이것은 루프가 정하는 규칙이 아니라 저장소 필터를 따라 하는 것이고, 필터가 없으면 비워 둔다(기본: 모든 PR에서 체크를 기다린다).

티켓을 병합해 닫은 뒤와 `--parent` 실행이 끝날 때, 루프는 그 스펙 이슈의 하위 이슈 목록을 세어 모두 닫혔으면 스펙 이슈도 코멘트와 함께 닫는다(요약 값이 아니라 목록을 센다). 하위 이슈가 하나라도 열려 있으면 그대로 둔다.

루프가 남기는 것은 세 가지다. 진행 로그 `.ticket-loop/loop-MMDD.log`(사람이 읽는다), 티켓별 기록 `.ticket-loop/tickets.jsonl`(기계별, 커밋하지 않는다), 그리고 `--parent <스펙>` 실행이 정상 종료할 때 쓰는 스펙 리포트 `docs/loop-reports/spec-<N>.html`(티켓별 상태·결과 브리프·경과 시간·모델 한 표, 사람이 보고 PR로 커밋한다). `POST_MERGE_PORT`를 정한 저장소에서는 포트가 차 있을 때 점유 프로세스를 적고 30초마다 다시 보며 기다린다. 시작할 때 이미 차 있으면 "주의" 한 줄을 적는다.

## 백엔드

루프 스크립트에서 워크트리·에이전트 터미널에 하는 일은 아홉 가지뿐이다(만들기·지우기·프롬프트 보내기·셸 입력·Ctrl-C·idle 대기·화면 읽기·상태 표시·시작 점검). 백엔드마다 같은 이름의 함수(`orca_*`, `cmux_*`)로 구현하고 `.ticket-loop/loop.env`의 `BACKEND=orca|cmux`로 고른다. 티켓 선택·PR·CI·수리·병합·병합 뒤 검증·기록·스펙 리포트는 한 벌이다.

| | Orca | cmux |
|---|---|---|
| 워크트리 | `orca worktree create`가 만들고 `orca.yaml` setup을 돌린다 | 루프가 `git worktree add`(`WORKTREE_DIR`, 기본 `~/.cache/ticket-loop/<owner-repo>/worktrees`) 뒤 `WORKTREE_SETUP_CMD`를 돌린다 |
| 에이전트 | Orca가 `--agent claude --prompt`로 띄운다 | `cmux workspace create --cwd … --command "claude … \"$(cat 프롬프트파일)\""` — 워크스페이스 셸의 claude shim이 Claude Code 훅을 붙인다 |
| idle 판정 | `orca terminal wait --for tui-idle`(블로킹) | `cmux rpc surface.input_state`의 `lifecycle`을 5초마다 읽는다(Claude Code 훅이 보고) |
| 입력·화면 | `orca terminal send / read` | `cmux paste --submit`, `send --force` + `send-key enter`, `read-screen --lines 25`. 보내기 전에 하이버네이션에서 깨운다 |
| 상태 표시 | `orca worktree set --workspace-status` | `cmux workspace status set`, `cmux pr`, `cmux log` |
| 실행 조건 | Orca 앱 실행 중, 저장소 등록 | cmux 터미널 안에서 실행(소켓 모드 기본값 `cmuxOnly`) |

두 백엔드 모두 실제 티켓 1건씩(boiler-webapp #34 Orca, #39 cmux)으로 확인했다. cmux 0.65 실측: `--json`은 명령 뒤에 둬야 JSON이 나오고(`workspace create --json --id-format uuids` → `workspace_id`·`surface_id`), lane은 `todo|working|needs-attention|review|done`, 프로세스가 살아 있는 워크스페이스는 `workspace close --force`로만 닫힌다. 루프는 cmux 터미널 안에서 띄워야 한다 — 소켓 모드 기본값이 `cmuxOnly`라 밖에서는 `cmux identify`가 거부된다.

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh` | `scripts/ticket-loop.sh` | 매번 덮어씀(키트 소유) |
| `files/scripts/ticket-state.sh` | `scripts/ticket-state.sh` | 매번 덮어씀 |
| `files/scripts/sync-mattpocock-skills.sh` | `scripts/sync-mattpocock-skills.sh` | 매번 덮어씀 |
| `files/.claude/skills/setup-ticket-loop/` | 같은 경로 | 매번 덮어씀 |
| `templates/.claude/skills/implement/`, `pr/` | 같은 경로 | 없을 때만(이후 프로젝트 소유) |
| `templates/.ticket-loop/worker-rules.md` | 같은 경로 | 없을 때만 |
| `templates/docs/loop-reports/README.md` | 같은 경로 | 없을 때만 |
| — | `.claude/skills/<mattpocock 스킬>` | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`(`/.ticket-loop/*.log`, `/.ticket-loop/*.jsonl`), `.claude/settings.json` `deny` | 줄·항목 병합 |
| — | GitHub 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.ticket-loop/kit.json` | 설치한 키트 커밋 기록 |

프로젝트별 값은 대상 저장소의 `.ticket-loop/loop.env`(루프 기본값, `BACKEND` 포함), `orca.yaml`(Orca), `.ticket-loop/worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 mattpocock 스킬만 바뀌고, 프로젝트 소유 파일(`loop.env` 포함)은 그대로다. 0.3 이하가 설치한 저장소는 설치기가 `.agent-loop/`(0.2 이하는 `.orca-loop/`)를 `.ticket-loop/`로 `git mv`하고(로그·기록 포함), 옛 스킬 `setup-agent-loop`·`setup-orca-loop`와 `.gitignore`의 옛 줄을 지운다. 그 뒤 옛 경로를 아직 가리키는 파일(`docs/agents/ticket-loop.md`, `CLAUDE.md`, `loop.env`의 `REPORT_DIR` 등)이 있으면 목록을 보여 주니 손으로 고쳐 같은 PR에 넣는다. 특정 버전으로 고정하려면 `npx github:iwishash/ticket-loop-kit#v0.5.1 init`(bash 경로는 `--ref v0.3.0`). 바뀐 것은 `git diff`로 보고 PR로 올린다. npx는 한 번 받은 저장소를 캐시하므로, 같은 ref로 다시 받으려면 `npx --yes --prefer-online` 또는 `npm cache clean --force`.

옵션: `--yes`, `--backend <orca|cmux>`, `--no-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). bash 경로는 `--ref <ref>`도 받는다(`bash install.sh --help`).

## 여러 컴퓨터에서 같은 저장소를 돌릴 때

한 번 설치한 저장소는 클론만 하면 다른 컴퓨터에서도 바로 돈다. 재설치는 키트 버전을 올릴 때만 한 컴퓨터에서 하고, 나머지는 `git pull`로 받는다.

- 루프에 필요한 것은 전부 커밋돼 있다 — `scripts/ticket-loop.sh`, `.ticket-loop/loop.env`(`BACKEND`, `WORKTREE_SETUP_CMD` 포함), `worker-rules.md`, `kit.json`, `implement`·`pr` 스킬. 기계별인 것은 `.ticket-loop/*.log`와 `tickets.jsonl`뿐이고 둘 다 `.gitignore`다. 새 컴퓨터에서는 빈 상태로 새로 쌓인다.
- 백엔드는 컴퓨터마다 달라도 된다. `loop.env`의 값은 `${BACKEND:-orca}` 꼴이라 실행할 때 준 환경변수가 이긴다 — A는 Orca로 `bash scripts/ticket-loop.sh N`, B는 cmux 터미널 안에서 `BACKEND=cmux bash scripts/ticket-loop.sh N`. cmux를 쓸 저장소는 `loop.env`에 `WORKTREE_SETUP_CMD`가 있어야 한다.
- 워크트리는 백엔드가 각자 자기 자리에 둔다(Orca는 Orca 설정 위치, cmux는 `~/.cache/ticket-loop/<owner-repo>/worktrees`). 저장소 안에는 흔적이 없어 컴퓨터끼리 충돌하지 않는다.
- 새 컴퓨터의 전제는 평소와 같다: `gh auth login`, `claude`, `jq`, 저장소의 패키지 매니저. cmux면 cmux 터미널 안에서 실행하고(소켓 모드 기본값 `cmuxOnly`) Settings의 Claude Code 통합이 켜져 있어야 한다 — 꺼져 있으면 `lifecycle`이 `unknown`만 돌아와 기동 유예 뒤 타임아웃으로 멈춘다.
- 동시에 돌릴 때는 티켓을 나눈다. 번호를 지정하면 브랜치(`issue-N-…`)가 갈라져 겹칠 일이 없다. 자동 선택은 담당자가 있거나 PR이 열린 티켓을 건너뛰고 워커가 시작하자마자 자기를 담당자로 넣지만, 두 루프가 몇 초 간격으로 같은 티켓을 집는 경합까지 막지는 못한다 — 자동 선택으로 함께 돌릴 거면 `--parent`나 `--label`로 범위를 가른다. 한쪽이 병합해 다른 쪽 PR에 충돌이 나면 루프의 수리 단계가 처리한다.
- 스펙 리포트(`--parent`)는 그 컴퓨터의 `tickets.jsonl`로 그리므로, 한 스펙은 한 컴퓨터에서 돌리는 편이 표가 온전하다. 기록이 없는 티켓은 PR 시각으로 대신 채운다.

## 키트를 고칠 때

- 루프 스크립트를 고치면 `python3 docs/sync-guide.py && bash docs/build-pdf.sh`로 부록 D와 PDF를 다시 만든다(`tests/smoke.sh`가 부록 D 일치를 검사한다).
- `bash tests/smoke.sh` — 임시 저장소에 설치해 보고(네트워크·GitHub 없이), 두 번 설치해도 결과가 같은지, 스펙 리포트 jq가 고정 자료로 그려지는지 확인한다.
- 바뀐 점은 `CHANGELOG.md`에, 버전은 `VERSION`·`package.json`과 태그로(`tests/smoke.sh`가 둘이 같은지 검사한다).
- `package.json`에 `prepare` 같은 빌드 단계를 두지 않는다. git에서 바로 받을 때 그 스크립트가 사용자 PC에서 돈다. npx 패키지에 들어가는 것은 `files` 목록(`bin`, `install.sh`, `files/`, `templates/`, `VERSION`)뿐이고 `docs/`·`tests/`는 빠진다.

## 검증 상태 (0.3.0, 2026-10-12)

확인한 것:

- `tests/smoke.sh` 통과: 문법, 부록 D 일치, 임시 저장소 설치, 재설치해도 프로젝트 소유 파일·`settings.json`·`.gitignore`가 바뀌지 않음, 스펙 리포트 jq 렌더(병합·중단·기록 없음 세 경우)
- 0.2.0의 스펙 리포트·포트 대기·터미널 재시도 코드는 rsrehab/rental-portal에서 실제 티켓 2건(#67·#68, 스펙 #65)으로 돈 범용 스크립트(가이드북 3판)를 그대로 가져온 것이다. 키트에서 더한 것은 `loop.env` 읽기와 시작 전 포트 점검뿐이다
- 스킬 동기화를 포함한 설치: mattpocock 1.3.1 + 미출시 changeset 16건(`49dd158`) 26개 스킬, `implement`·`pr`은 건너뜀
- 원격 한 줄 설치(`--ref v0.1.0`)로 받아 설치되고 `.ticket-loop/kit.json`에 `534653a`가 기록됨
- npx 껍질: 키트 복사본을 `git+file://`로 받아 `--yes` 설치되고 `kit.json`에 커밋·`ref`(`#태그`를 주면 `npx#<태그>`)가 남음. 대화형 경로(백엔드 선택, 항목별 질문, cmux 거절, Ctrl+D)는 pty로 확인. `npx github:iwishash/ticket-loop-kit init --yes`와 `#main` 고정형을 빈 npm 캐시에서 실제로 받아(비공개 저장소, SSH 키 없이 HTTPS + 키체인 자격 증명) 임시 저장소에 스킬 동기화까지 설치되고 `kit.json`에 `e707bfe`·`ref: npx`/`npx#main`이 남음

- 0.2 설치본 마이그레이션: 스모크 테스트가 `.orca-loop/`(규칙·`loop.env`·로그)와 옛 스킬·`.gitignore` 줄이 있는 임시 저장소에 설치해 `git mv`로 옮겨지고 아무것도 잃지 않음을 확인한다. rental-portal 실제 적용은 아직이다

- Orca 백엔드로 실제 티켓 1건(iwishash/boiler-webapp #34 → PR #38, 2026-10-12): 첫 설치(`npx … init` + 사용자가 `/setup-ticket-loop` 실행) 뒤 `bash scripts/ticket-loop.sh 34 --max 1`이 워크트리 생성 → 워커 기동 → PR → CI 8개 작업 대기 → 병합 → 이슈 닫힘 → 워크트리·브랜치 정리 → 기록(`tickets.jsonl`, 모델 포함)까지 벽시계 10분에 끝났다. 첫 시도에서 `orca_set_status`의 `set -u` 버그로 워크트리 생성 직후 죽었고(워커는 혼자 계속 돌았다) 고친 뒤 재실행한 결과다. 병합 뒤 검증은 그 저장소에 없어 건너뛰었다

- cmux 백엔드로 실제 티켓 1건(iwishash/boiler-webapp #39 → PR #40, 2026-10-12, cmux 0.65): cmux 터미널 안에서 `BACKEND=cmux WORKTREE_SETUP_CMD='pnpm install --frozen-lockfile --prefer-offline' bash scripts/ticket-loop.sh 39 --max 1`이 `git worktree add` → pnpm 설치 → `cmux workspace create --command "claude …"` → 훅이 보고하는 `lifecycle`로 idle 판정 → PR → CI 8개 작업 → 병합 → `workspace close --force`·워크트리·브랜치 정리 → 기록까지 벽시계 7분에 끝났다(수리 0회, idle 오판 0회). lane은 working → review → done으로 따라갔다. 초안의 가정 중 `--json` 위치와 `close --force` 두 가지가 틀려 고쳤고 나머지(JSON 필드명, lane 이름, uuid, 훅 주입)는 맞았다

아직 확인하지 않은 것 — 첫 적용 저장소에서 확인하고 여기를 갱신한다:

- `/setup-ticket-loop`는 boiler-webapp에서 사용자가 한 번 돌렸다(결과 PR은 병합됨). 질문 순서나 빠진 항목에 대한 피드백은 아직 없다
- `install.sh`의 라벨 생성·Orca 등록 단계는 시험에서 껐다. 명령 자체는 rsrehab/rental-portal에서 쓰던 것이다
- 키트판 `ticket-loop.sh`의 `POST_MERGE_CMD`·`POST_MERGE_PORT`·`CI_SKIP_CMD`·`CI_SKIP_REGEX` 경로와 수리 프롬프트 경로. boiler-webapp 1건은 병합 뒤 검증 없음·CI 경로 필터 없음·수리 0회였다. rental-portal(PR #82로 전환, `CI_SKIP_CMD`·`POST_MERGE_CMD` 설정)에서 실제 티켓을 돌리면 확인된다
- cmux 백엔드 전체. `--dry-run`이 cmux 터미널 밖에서 소켓 오류로 멈추는 것까지만 확인했다
- 출처 저장소 rsrehab/rental-portal은 아직 저장소 전용판 `scripts/orca-ticket-loop.sh`를 쓴다(키트로 전환하지 않음)
