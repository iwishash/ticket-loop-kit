# ticket-loop-kit

GitHub 이슈 티켓을 워크트리에서 한 건씩 무인으로 구현·검증·병합하는 **티켓 루프**를 다른 저장소에 설치하고 업데이트하는 키트. 워크트리와 에이전트 터미널은 백엔드(Orca, cmux 또는 tmux)가 맡는다. 원리와 운영은 [「티켓 무인 루프 가이드북」](docs/ticket-loop-guide.pdf)에 있고, 영문 README는 [README.md](README.md)다(이 파일이 한국어 원문).

## 제약과 설치 환경

"확인"은 실제 티켓 1건이 끝까지(워크트리 → 워커 → PR → CI → 병합 → 정리) 지나갔다는 뜻이다.

| | 지원 | 상태 |
|---|---|---|
| 워커 에이전트 | **Claude Code** (`AGENT=claude`, 기본) | 확인됨. `claude --dangerously-skip-permissions`로 띄운다 |
| | **Codex CLI** (`AGENT=codex`) | 배치는 갖춰졌지만 **실제 티켓으로는 미확인**. `codex --dangerously-bypass-approvals-and-sandbox`로 띄운다. Codex CLI가 포함된 ChatGPT 요금제 또는 API 키가 필요하다 |
| 백엔드 | **Orca** (`BACKEND=orca`, 기본) | 확인됨(Orca 1.4.x). Orca 앱 실행 중, 저장소 등록, Command Source "orca.yaml only" |
| | **cmux** (`BACKEND=cmux`) | 확인됨(cmux 0.65). 루프를 cmux 터미널 안에서 돌리고, 에이전트의 cmux 통합이 켜져 있어야 한다 |
| | **tmux** (`BACKEND=tmux`) | 확인됨(tmux 3.8). 어느 터미널 앱에서나, SSH 너머에서도 돈다. idle은 Claude Code 훅이 보고한다. Codex는 `notify`로 잇지만 실측 전이다 |
| 이슈 트래커 | **GitHub Issues**만, `gh`로 | 하위 이슈(스펙 → 티켓), `blocked_by`, 라벨, PR 체크, 병합. 다른 트래커는 대상 선택·PR·병합 함수를 다시 써야 한다 |
| OS | **macOS** | 확인됨 |
| | **Linux / WSL** | 코드 경로(`orca-ide`, `notify-send`, `date -d`)는 두었지만 **아직 돌려 보지 않았다**. WSL 안의 tmux 백엔드가 그대로 돌 가능성이 가장 높다. WSL에서 Orca를 조종하는 건 미시도, cmux는 macOS 전용이다 |
| | 네이티브 Windows(cmd, PowerShell, Git Bash) | **미지원**: 설치기와 루프가 bash이고, `.claude/skills/` 아래가 심볼릭 링크이며, Git Bash에는 tmux가 없다. `npx … init`은 win32에서 거부하고 WSL을 안내한다 |
| 도구 | `git`, `gh`(로그인), `jq`, bash; `npx … init`에는 Node 18 이상 | bash만으로 설치하면 Node는 필요 없다 |

**박힌 프롬프트가 아니라 스킬.** 워커는 저장소에 커밋된 스킬을 따르고, 그 스킬은 [mattpocock/skills](https://github.com/mattpocock/skills)(MIT)에서 온다. `tdd`와 `code-review`(→ `ticket-review`)를 `.agents/skills/`에 벤더링해 upstream 커밋에 고정하므로 모든 워커가 같은 버전을 쓴다. 루프가 `/implement N`(Codex는 `$implement N`)으로 보내는 프로젝트 소유 `implement` 스킬이 `tdd` → `ticket-review` → `pr`을 부른다. 기획 스킬(`grill-with-docs`, `to-spec`, `to-tickets`, `retro`)은 선택(`--workflow-skills`)이다. 스킬 사본은 `.agents/skills/<이름>`(Codex가 읽음) 하나이고 `.claude/skills/<이름>`은 그 심볼릭 링크다(Claude Code가 읽음).

**제약.**

- 워커는 권한 확인을 끄고 돈다. 잘못된 병합이나 강제 push를 막는 진짜 방어선은 GitHub 브랜치 보호다. 키트의 `deny` 규칙(`.claude/settings.json`, `.codex/rules/ticket-loop.rules`)은 둘째 줄이다.
- 저장소당 루프 하나(`.git` 아래 잠금 디렉터리). GitHub(라벨·담당자·PR)만이 상태다.
- 티켓마다 새 워크트리와 빈 컨텍스트에서 시작하므로 스킬·워커 규칙·`AGENTS.md`/`CLAUDE.md` 변경은 병합한 뒤에야 적용된다.
- 무거운 테스트(통합·E2E)는 워커가 돌리지 않는다. 루프가 병합마다 기본 브랜치에서 `POST_MERGE_CMD`를 돌리고 실패하면 멈춘다.
- 키트 저장소는 아직 비공개다. 초대와 `gh auth login`, npx면 `gh auth setup-git` 한 번이 필요하다(키체인이나 SSH 별칭 자격 증명도 된다).

## 설치

대상 저장소 루트에서:

```bash
npx github:iwishash/ticket-loop-kit init
```

백엔드와 설치 단계를 키보드로 고른다(`--yes`면 묻지 않고, `NO_COLOR`로 색을 끈다). 버전 고정은 `npx github:iwishash/ticket-loop-kit#v0.8.0 init`. Node 없이:

```bash
bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

그다음:

1. Claude Code(또는 Codex에서 `$setup-ticket-loop`)에서 `/setup-ticket-loop`를 돌린다. 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`를 이 저장소에 맞춰 채우고 PR을 연다.
2. Orca만: Settings → Projects → <저장소> → Worktree Hooks → Advanced에서 Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기.
3. PR을 병합한 뒤 `bash scripts/ticket-loop.sh --dry-run` → `--max 1`.

## 누가 무엇을 하나

| 주체 | 하는 일 |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) | 백엔드 선택(`.ticket-loop/loop.env`의 `BACKEND=` 줄, 없을 때만), 설치 단계 켜고 끄기, 도구 점검, `install.sh` 호출 |
| `install.sh` (어느 저장소에서나 같은 부분) | 스킬 충돌 검사, 루프·동기화 스크립트, `setup-ticket-loop` 스킬, mattpocock 스킬 벤더링, 템플릿, `.gitignore`·`deny` 병합, 라벨 6개, git 자격 증명(gh), Orca 등록, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` (저장소를 읽어야 정하는 부분) | `implement`·`pr`·`worker-rules.md`의 `__PLACEHOLDER__` 채우기(검증 명령, 무거운 스위트와 그 파일 하나를 돌리는 명령), `orca.yaml`, CI, `loop.env`, `docs/agents/ticket-loop.md`, `CLAUDE.md` 포인터 → PR |
| 사람 | Orca 설정, PR 병합, `--max 1` 시험 지켜보기 |

루프 동작 중 알아둘 것:

- `ticket-loop.sh`는 가이드북 부록 D에 둘을 더한 것이다. `.ticket-loop/loop.env`(`VAR="${VAR:-값}"` 꼴로 커밋한 기본값, 실행할 때 준 환경변수가 이긴다)와 시작 전 포트 점검.
- CI가 경로 필터를 쓰면 GitHub는 걸러진 PR에 체크를 만들지 않아 루프가 "아직 안 떴다"와 "안 뜬다"를 구별할 수 없다. `CI_SKIP_REGEX` 또는 `CI_SKIP_CMD`(파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 스크립트)로 필터를 따라 하고, 필터가 없으면 비워 둔다.
- 병합마다, 그리고 `--parent` 실행이 끝날 때, 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈도 닫는다.
- 산출물: `.ticket-loop/loop-MMDD.log`, `.ticket-loop/tickets.jsonl`(기계별, 커밋하지 않음), `--parent <스펙>` 실행 뒤의 스펙 리포트 `docs/loop-reports/spec-<N>.html`(사람이 보고 PR로 커밋). 스펙이 끝나면 `/retro`를 권하는 한 줄을 남기고, 회고를 직접 돌리지는 않는다.
- `POST_MERGE_PORT`가 있으면 포트가 차 있을 때 점유 프로세스를 적고 30초마다 다시 본다.

## 백엔드

루프가 워크트리·터미널에 하는 일은 아홉 함수뿐이다(만들기·지우기·프롬프트 보내기·셸 입력·Ctrl-C·idle 대기·화면 읽기·상태 표시·시작 점검). 백엔드마다 `orca_*`, `cmux_*`, `tmux_*`로 구현하고 `loop.env`의 `BACKEND=orca|cmux|tmux`로 고른다. 티켓 선택·PR·CI·수리·병합·병합 뒤 검증·기록·스펙 리포트는 한 벌이다.

| | Orca | cmux | tmux |
|---|---|---|---|
| 워크트리 | `orca worktree create`가 `orca.yaml` setup까지 돌린다 | `WORKTREE_DIR`(기본 `~/.cache/ticket-loop/<owner-repo>/worktrees`)에 `git worktree add` 뒤 `WORKTREE_SETUP_CMD` | cmux와 같다 |
| 에이전트 | Orca가 `--agent claude --prompt`로 띄운다 | `cmux workspace create --cwd … --command "claude …"`. 워크스페이스의 claude shim이 Claude Code 훅을 붙인다 | `TMUX_SESSION`(기본 `ticket-loop`, tmux 안이면 그 세션)의 창에서 `claude … --settings <훅 설정>` |
| idle 판정 | `orca terminal wait --for tui-idle` | `cmux rpc surface.input_state`의 `lifecycle`을 5초마다 | 훅이 `~/.cache/ticket-loop/<owner-repo>/tmux/` 아래 `state/<워크트리>`에 쓰고 루프가 5초마다 읽는다 |
| 입력·화면 | `orca terminal send / read` | `cmux paste --submit`, `send --force` + `send-key enter`, `read-screen --lines 25` | `send-keys -l` + `Enter`, `capture-pane -p` 마지막 25줄 |
| 상태 표시 | `orca worktree set --workspace-status` | `cmux workspace status set`, `cmux pr`, `cmux log` | 창 이름 뒤에 `[working]`·`[review]`·`[done]`·`[needs-attention]` |
| 실행 조건 | Orca 앱 실행 중, 저장소 등록 | cmux 터미널 안(소켓 모드 `cmuxOnly`). Claude Code가 메인 체크아웃을 신뢰한 상태 | `tmux` 설치. 메인 체크아웃 신뢰. `AGENT=claude\|codex`만. `tmux attach -t ticket-loop`으로 본다 |

Claude Code는 새 워크트리의 신뢰를 메인 체크아웃 경로로 판정하므로, cmux·tmux의 시작 점검은 `~/.claude.json`을 보고 메인 체크아웃이 신뢰되기 전에는 시작을 거부한다. Warp·Ghostty 같은 터미널 앱은 백엔드가 아니다. 그 안에서 tmux 백엔드를 돌린다. cmux CLI(0.65) 메모: `--json`은 명령 뒤에, lane은 `todo|working|needs-attention|review|done`, 프로세스가 살아 있는 워크스페이스는 `workspace close --force`로만 닫힌다.

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh`, `ticket-state.sh`, `sync-mattpocock-skills.sh` | `scripts/` | 매번 덮어씀(키트 소유) |
| `files/.agents/skills/setup-ticket-loop/` | 같은 경로 + `.claude/skills/` 링크 | 매번 덮어씀 |
| `templates/.agents/skills/implement/`, `pr/` | 같은 경로 + `.claude/skills/` 링크 | 없을 때만(이후 프로젝트 소유) |
| `templates/.codex/rules/ticket-loop.rules` | 같은 경로 | 없을 때만. `deny` 규칙의 Codex 판, 기본 브랜치는 설치기가 채운다 |
| `templates/.ticket-loop/worker-rules.md`, `docs/loop-reports/README.md`, `docs/agents/issue-tracker.md` | 같은 경로 | 없을 때만 |
| — | `.agents/skills/tdd`, `ticket-review`(+ 기획 묶음)와 `.claude/skills/` 링크 | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`(`/.ticket-loop/*.log`, `*.jsonl`), `.claude/settings.json`의 `deny` | 병합 |
| — | GitHub 라벨 6개, git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.ticket-loop/kit.json` | 설치한 키트 커밋 기록 |

스킬은 `.agents/skills/<이름>`에 한 번만 두고 `.claude/skills/<이름>`은 링크다(`npx skills add`와 같은 배치). 0.6 이하 설치본은 `git mv`로 옮겨진다. `## Agent skills` 블록은 `AGENTS.md`에 두고(Codex는 그 파일만 읽는다) `CLAUDE.md`가 `@AGENTS.md`로 가져온다. `/setup-ticket-loop`가 둘 다 쓴다. 프로젝트별 값은 `loop.env`, `orca.yaml`, `worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 벤더링한 스킬만 바뀌고 프로젝트 소유 파일(`loop.env` 포함)은 그대로다. 0.3 이하 설치본은 마이그레이션된다(`.agent-loop/` 또는 `.orca-loop/` → `.ticket-loop/`, 옛 스킬과 `.gitignore` 줄 제거). 옛 경로를 아직 가리키는 파일은 설치기가 목록으로 보여 주니 같은 PR에서 손으로 고친다. `git diff`로 보고 PR로 올린다. npx는 받은 저장소를 캐시하므로 같은 ref를 다시 받으려면 `npx --yes --prefer-online`.

옵션: `--yes`, `--backend <orca|cmux|tmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). bash 경로는 `--ref <ref>`도 받는다.

## mattpocock 스킬: 무엇을 들이고, 무엇을 검사하나

플러그인이 아니라 파일로 벤더링하는 이유는 워크트리와 클라우드 세션이 clone만으로 같은 버전을 쓰고, 무인 실행 도중 자동 업데이트로 동작이 바뀌지 않게 하려는 것이다.

| 묶음 | 스킬 | 기본 |
|---|---|---|
| core | `tdd`, `code-review` → `ticket-review`(내장 `/code-review`와 이름이 겹쳐서) | 항상 |
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`와 `grilling`, `domain-modeling`, `writing-for-agents` | 꺼짐. `--workflow-skills` 또는 체크리스트. 지난 설치가 들였으면 유지 |
| kept | 지난 설치(0.5 이하는 26개 전부)가 두 묶음 밖에 놓은 것 | 유지·동기화하고 새 설치에는 들이지 않는다. `--prune-skills`로 지운다 |

세 묶음은 매니페스트 `.agents/skills/.mattpocock.json`에 기록된다. 손으로 지운 스킬은 다시 들이지 않고, upstream에서 사라진 스킬은 그대로 둔다. 나머지 upstream 스킬은 플러그인(`claude plugin install mattpocock-skills@claude-plugins-official`)으로 쓴다.

설치기는 바꾸기 전에 같은 스킬이 다른 경로로 이미 있는지 본다(`bash scripts/sync-mattpocock-skills.sh --check`로 따로 돌릴 수 있다):

| 발견 | 처리 |
|---|---|
| `mattpocock-skills` 플러그인이 이 저장소에 켜져 있음(`/tdd`와 `/mattpocock-skills:tdd`가 함께 뜬다) | 경고. 체크리스트가 `claude plugin disable … --scope project`를 제안 |
| `~/.claude/skills/<이름>`에 같은 스킬(커밋한 사본을 가린다) | 경고 + 이름 목록 |
| `npx skills add`의 `skills-lock.json`, 또는 이 저장소의 `.agents/skills/` 밖을 가리키는 `.claude/skills/*` 링크 | **설치 중단**. `npx skills remove`로 걷어낸 뒤 재실행(`--force-skills`로 강행, `--no-skills`로 건너뜀) |
| `code-review` 스킬 디렉터리(내장 `/code-review`를 대체) | 경고 + `rm -rf` 안내 |
| 매니페스트에 없는 같은 이름 디렉터리, `.claude/commands/<이름>.md` | 알림 |

플러그인과 `~/.claude/skills` 검사는 `--agent claude`일 때만 돌고, `--agent codex`면 같은 이름의 `~/.agents/skills/<이름>`을 대신 알린다.

## 여러 컴퓨터에서 같은 저장소를 돌릴 때

클론만 하면 다른 컴퓨터에서도 바로 돈다. 재설치는 키트를 올릴 때만 한 컴퓨터에서 하고 나머지는 `git pull`.

- 루프에 필요한 것은 전부 커밋돼 있다. 기계별인 것은 `.ticket-loop/*.log`와 `tickets.jsonl`뿐이다(ignore).
- 백엔드는 컴퓨터마다 달라도 된다. `BACKEND=cmux bash scripts/ticket-loop.sh N`처럼 환경변수가 `loop.env` 기본값을 이긴다. cmux·tmux는 `loop.env`에 `WORKTREE_SETUP_CMD`가 있어야 하고, 워크트리는 `~/.cache/ticket-loop/<owner-repo>/worktrees`에 두며, 메인 체크아웃을 Claude Code가 신뢰해야 한다(거기서 `claude`를 한 번 연다).
- 동시에 돌릴 때는 티켓 번호를 지정하거나 `--parent`·`--label`로 자동 선택 범위를 가른다. 담당자·열린 PR 검사는 몇 초 간격의 경합까지 막지 못한다. 충돌이 난 PR은 수리 단계가 처리한다.
- 스펙 리포트는 그 컴퓨터의 `tickets.jsonl`로 그리므로 한 스펙은 한 컴퓨터에서 돌린다. 기록이 없는 티켓은 PR 시각으로 대신 채운다.

## 키트를 고칠 때

- 루프 스크립트를 고치면 `python3 docs/sync-guide.py && bash docs/build-pdf.sh`로 부록 D와 PDF를 다시 만든다(`tests/smoke.sh`가 부록 D 일치를 검사한다).
- `bash tests/smoke.sh`는 네트워크 없이 임시 저장소에 설치하고, 두 번 설치해도 같은지, 스펙 리포트가 고정 자료로 그려지는지 확인한다.
- 바뀐 점은 `CHANGELOG.md`에, 버전은 `VERSION`·`package.json`과 태그로.
- `package.json`에 `prepare` 같은 빌드 단계를 두지 않는다. git에서 바로 받으면 사용자 PC에서 돈다. npx 패키지에는 `files` 목록만 들어가고 `docs/`·`tests/`는 빠진다.

## 검증 상태

백엔드마다 실제 티켓 1건으로 확인했다(자세한 기록은 `CHANGELOG.md`):

| 백엔드 | 티켓 | 벽시계 | 수리 |
|---|---|---|---|
| Orca 1.4.x | iwishash/boiler-webapp #34 → PR #38 (2026-10-12) | 10분 | 0회 |
| cmux 0.65 | iwishash/boiler-webapp #39 → PR #40 (2026-10-12) | 7분 | 0회 |
| tmux 3.8 | iwishash/ticket-loop-dummy #1 → PR #2 (2026-10-13) | 4분 | 0회 |

그 밖에 확인한 것: `tests/smoke.sh`, 비공개 저장소를 실제로 받는 npx 껍질, 0.2 설치본 마이그레이션(스모크 테스트만).

아직 확인하지 않은 것:

- 실제 티켓에서의 `POST_MERGE_CMD`·`POST_MERGE_PORT`·`CI_SKIP_CMD`·`CI_SKIP_REGEX`와 수리 프롬프트(세 실측 모두 병합 뒤 검증 없음·CI 필터 없음·수리 0회). rental-portal(PR #82)에 설정돼 있다.
- `install.sh`의 라벨 생성·Orca 등록 단계(시험에서 껐다).
- boiler-webapp 1회 이후의 `/setup-ticket-loop`.
- Linux와 WSL. Linux 분기는 한 번도 실행되지 않았다. WSL 안의 tmux 백엔드부터 시도할 것. WSL에서 `orca-ide`로 Orca를 조종하는 건 미해결(Windows 앱이냐 WSLg의 Linux AppImage냐, 경로 대응).
- Codex 워커. 프리셋·프롬프트·스킬 배치·`AGENTS.md`·`.codex/rules/ticket-loop.rules`·`--agent codex`는 갖춰졌지만 Codex가 설치된 컴퓨터에서 돌린 적이 없다: idle 판정, `$implement`가 스킬을 집는지, 수리 프롬프트, 규칙 파일이 `--dangerously-bypass-approvals-and-sandbox` 아래에서도 로드되는지.
- 출처 저장소 rsrehab/rental-portal은 아직 자체 `scripts/orca-ticket-loop.sh`를 쓴다.
