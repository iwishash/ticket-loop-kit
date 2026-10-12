# agent-loop-kit

GitHub 이슈 티켓을 Orca 워크트리에서 한 건씩 무인으로 구현·검증·병합하는 **티켓 루프**를 다른 저장소에 설치하고 업데이트하는 키트.
원리와 운영은 [「Orca 티켓 무인 루프 가이드북」](docs/orca-ticket-loop-guide.pdf)에 있다.

## 설치

대상 저장소 루트에서:

```bash
npx github:iwishash/agent-loop-kit init
```

백엔드(지금은 Orca)와 설치 단계를 묻고 `.orca-loop/loop.env`에 `BACKEND=` 줄을 쓴 뒤 `install.sh`를 부른다. 묻지 않으려면 `--yes`(터미널이 아니면 자동). 키트 버전을 고정하려면 `npx github:iwishash/agent-loop-kit#v0.2.0 init`. 저장소가 비공개인 동안은 이 저장소에 초대받고 `gh auth login` 뒤 `gh auth setup-git`을 한 번 해 두면 npx가 받아 간다(macOS 키체인에 GitHub 자격 증명이 있어도 된다).

npx 없이 bash로만 설치하려면:

```bash
bash <(gh api repos/iwishash/agent-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

그다음 Claude Code에서:

1. `/setup-matt-pocock-skills` — `docs/agents/issue-tracker.md`가 아직 없을 때
2. `/setup-orca-loop` — 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`를 이 저장소에 맞춰 채우고 PR을 연다

마지막으로 Orca 앱에서 Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기. PR을 병합한 뒤 `bash scripts/ticket-loop.sh --dry-run` → `--max 1`.

필요한 도구: `git`, `gh`(로그인), `jq`, `rsync`, Orca 앱과 CLI, Claude Code.

## 누가 무엇을 하나

| 주체 | 하는 일 |
|---|---|
| `npx … init` (`bin/agent-loop-kit.js`) — 질문과 껍질 | 백엔드 선택, `.orca-loop/loop.env`의 `BACKEND=` 줄(없을 때만), 설치 단계 켜고 끄기, 도구 점검, 설치한 키트 커밋을 `install.sh`에 넘김 |
| `install.sh` — 어느 저장소에서나 같은 부분 | 루프·진단·스킬 동기화 스크립트와 `setup-orca-loop` 스킬 설치, mattpocock 스킬 벤더링(`code-review` → `ticket-review`), `.gitignore`·`deny` 병합, 라벨 6개, git 자격 증명(gh), Orca 등록, `.orca-loop/kit.json` |
| `/setup-orca-loop` — 저장소를 읽어야 정하는 부분 | `implement`·`pr`·`worker-rules.md`의 `__PLACEHOLDER__` 채우기, `verify` 명령, `orca.yaml`, CI, `.orca-loop/loop.env`, `docs/agents/ticket-loop.md`, `CLAUDE.md` 포인터 → PR |
| 사람 | Orca 앱 설정(Command Source "orca.yaml only"), PR 병합, `--max 1` 시험 지켜보기 |

키트의 `ticket-loop.sh`는 가이드북 3판 부록 D의 스크립트에 저장소별 기본값 파일 `.orca-loop/loop.env` 읽기와 시작 전 포트 점검을 더한 것이다. `CI_SKIP_REGEX`, `POST_MERGE_CMD`, `POST_MERGE_PORT` 같은 저장소 고정값은 거기에 `VAR="${VAR:-값}"` 꼴로 적어 커밋하고, 실행할 때 준 환경변수가 이긴다.

루프가 남기는 것은 세 가지다. 진행 로그 `.orca-loop/loop-MMDD.log`(사람이 읽는다), 티켓별 기록 `.orca-loop/tickets.jsonl`(기계별, 커밋하지 않는다), 그리고 `--parent <스펙>` 실행이 정상 종료할 때 쓰는 스펙 리포트 `docs/loop-reports/spec-<N>.html`(티켓별 상태·결과 브리프·경과 시간·모델 한 표, 사람이 보고 PR로 커밋한다). `POST_MERGE_PORT`를 정한 저장소에서는 포트가 차 있을 때 점유 프로세스를 적고 30초마다 다시 보며 기다린다. 시작할 때 이미 차 있으면 "주의" 한 줄을 적는다.

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh` | `scripts/ticket-loop.sh` | 매번 덮어씀(키트 소유) |
| `files/scripts/ticket-state.sh` | `scripts/ticket-state.sh` | 매번 덮어씀 |
| `files/scripts/sync-mattpocock-skills.sh` | `scripts/sync-mattpocock-skills.sh` | 매번 덮어씀 |
| `files/.claude/skills/setup-orca-loop/` | 같은 경로 | 매번 덮어씀 |
| `templates/.claude/skills/implement/`, `pr/` | 같은 경로 | 없을 때만(이후 프로젝트 소유) |
| `templates/.orca-loop/worker-rules.md` | 같은 경로 | 없을 때만 |
| `templates/docs/loop-reports/README.md` | 같은 경로 | 없을 때만 |
| — | `.claude/skills/<mattpocock 스킬>` | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`(`/.orca-loop/*.log`, `/.orca-loop/*.jsonl`), `.claude/settings.json` `deny` | 줄·항목 병합 |
| — | GitHub 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.orca-loop/kit.json` | 설치한 키트 커밋 기록 |

프로젝트별 값은 대상 저장소의 `.orca-loop/loop.env`(루프 기본값), `orca.yaml`, `.orca-loop/worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 mattpocock 스킬만 바뀌고, 프로젝트 소유 파일(`loop.env` 포함)은 그대로다. 특정 버전으로 고정하려면 `npx github:iwishash/agent-loop-kit#v0.2.0 init`(bash 경로는 `--ref v0.2.0`). 바뀐 것은 `git diff`로 보고 PR로 올린다. npx는 한 번 받은 저장소를 캐시하므로, 같은 ref로 다시 받으려면 `npx --yes --prefer-online` 또는 `npm cache clean --force`.

옵션: `--yes`, `--backend <orca|cmux>`, `--no-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/agent-loop-kit --help`). bash 경로는 `--ref <ref>`도 받는다(`bash install.sh --help`).

## 키트를 고칠 때

- 루프 스크립트를 고치면 `python3 docs/sync-guide.py && bash docs/build-pdf.sh`로 부록 D와 PDF를 다시 만든다(`tests/smoke.sh`가 부록 D 일치를 검사한다).
- `bash tests/smoke.sh` — 임시 저장소에 설치해 보고(네트워크·GitHub 없이), 두 번 설치해도 결과가 같은지, 스펙 리포트 jq가 고정 자료로 그려지는지 확인한다.
- 바뀐 점은 `CHANGELOG.md`에, 버전은 `VERSION`·`package.json`과 태그로(`tests/smoke.sh`가 둘이 같은지 검사한다).
- `package.json`에 `prepare` 같은 빌드 단계를 두지 않는다. git에서 바로 받을 때 그 스크립트가 사용자 PC에서 돈다. npx 패키지에 들어가는 것은 `files` 목록(`bin`, `install.sh`, `files/`, `templates/`, `VERSION`)뿐이고 `docs/`·`tests/`는 빠진다.

## 검증 상태 (0.2.0, 2026-10-12)

확인한 것:

- `tests/smoke.sh` 통과: 문법, 부록 D 일치, 임시 저장소 설치, 재설치해도 프로젝트 소유 파일·`settings.json`·`.gitignore`가 바뀌지 않음, 스펙 리포트 jq 렌더(병합·중단·기록 없음 세 경우)
- 0.2.0의 스펙 리포트·포트 대기·터미널 재시도 코드는 rsrehab/rental-portal에서 실제 티켓 2건(#67·#68, 스펙 #65)으로 돈 범용 스크립트(가이드북 3판)를 그대로 가져온 것이다. 키트에서 더한 것은 `loop.env` 읽기와 시작 전 포트 점검뿐이다
- 스킬 동기화를 포함한 설치: mattpocock 1.3.1 + 미출시 changeset 16건(`49dd158`) 26개 스킬, `implement`·`pr`은 건너뜀
- 원격 한 줄 설치(`--ref v0.1.0`)로 받아 설치되고 `.orca-loop/kit.json`에 `534653a`가 기록됨
- npx 껍질: 키트 복사본을 `git+file://`로 받아 `--yes` 설치되고 `kit.json`에 커밋·`ref`(`#태그`를 주면 `npx#<태그>`)가 남음. 대화형 경로(백엔드 선택, 항목별 질문, cmux 거절, Ctrl+D)는 pty로 확인. `npx github:iwishash/agent-loop-kit init --yes`와 `#main` 고정형을 빈 npm 캐시에서 실제로 받아(비공개 저장소, SSH 키 없이 HTTPS + 키체인 자격 증명) 임시 저장소에 스킬 동기화까지 설치되고 `kit.json`에 `e707bfe`·`ref: npx`/`npx#main`이 남음

아직 확인하지 않은 것 — 첫 적용 저장소에서 확인하고 여기를 갱신한다:

- `/setup-orca-loop`를 실제 저장소에서 돌려 본 적이 없다. 질문 순서나 빠진 항목이 드러나면 키트에서 고친다
- `install.sh`의 라벨 생성·Orca 등록 단계는 시험에서 껐다. 명령 자체는 rsrehab/rental-portal에서 쓰던 것이다
- 키트판 `ticket-loop.sh`로 실제 티켓을 돌린 적이 없다. 특히 `.orca-loop/loop.env`, `POST_MERGE_CMD`, `CI_SKIP_REGEX` 경로와 시작 전 포트 점검 줄
- 출처 저장소 rsrehab/rental-portal은 아직 저장소 전용판 `scripts/orca-ticket-loop.sh`를 쓴다(키트로 전환하지 않음)
