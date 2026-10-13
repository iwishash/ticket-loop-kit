# ticket-loop-kit

GitHub 이슈 티켓을 워크트리에서 한 건씩 무인으로 구현·검증·병합하는 **티켓 루프**를 다른 저장소에 설치하고 업데이트하는 키트. 워크트리와 에이전트 터미널은 백엔드(Orca, cmux 또는 tmux)가 맡는다.
원리와 운영은 [「티켓 무인 루프 가이드북」](docs/ticket-loop-guide.pdf)에 있다.
영문 README는 [README.md](README.md)다(이 파일이 한국어 원문).

## 제약과 설치 환경

이 키트가 전제하는 것과, 각 부분이 어디까지 확인됐는지. "확인"은 실제 티켓 1건이 끝까지(워크트리 → 워커 → PR → CI → 병합 → 정리) 지나갔다는 뜻이다.

| | 지원 | 상태 |
|---|---|---|
| 워커 에이전트 | **Claude Code** (`AGENT=claude`, 기본) | 확인됨. `claude --dangerously-skip-permissions`로 띄운다 |
| | **Codex CLI** (`AGENT=codex`) | 프리셋과 저장소 배치는 갖춰졌지만 **실제 티켓으로는 아직 확인하지 않았다**(아래 "아직 확인하지 않은 것"). `codex --dangerously-bypass-approvals-and-sandbox`로 띄운다. Codex CLI가 포함된 ChatGPT 요금제(Plus 이상) 또는 API 키가 필요하다 |
| 백엔드(워크트리·에이전트 터미널) | **Orca** (`BACKEND=orca`, 기본) | 확인됨(Orca 1.4.x). Orca 앱 실행 중, 저장소 등록, Command Source "orca.yaml only" |
| | **cmux** (`BACKEND=cmux`) | 확인됨(cmux 0.65). 루프를 cmux 터미널 안에서 돌려야 하고(소켓 모드 기본값 `cmuxOnly`), 에이전트의 cmux 통합이 켜져 있어야 `lifecycle`이 보고된다 |
| | **tmux** (`BACKEND=tmux`) | 확인됨(tmux 3.8, 더미 저장소 티켓 1건). 어느 터미널 앱(Ghostty·Warp·iTerm2…)에서나, SSH 너머에서도 돈다. idle은 Claude Code 훅(`--settings`로 주입)이 보고한다. Claude Code가 메인 체크아웃을 신뢰한 상태여야 한다(시작 때 검사). Codex는 `notify`로 같은 자리를 잇지만 실측 전이다 |
| 이슈 트래커 | **GitHub Issues**만, `gh`로 | 하위 이슈(스펙 → 티켓), 이슈 의존성(`blocked_by`), 라벨, PR 체크, 병합을 쓴다. GitLab 등 다른 트래커는 대상 선택·PR·병합 함수를 다시 써야 한다 |
| OS | **macOS** | 확인됨. Linux용 경로(`orca-ide`, `notify-send`, `date -d`)는 두었지만 돌려 보지 않았다. Windows는 지원하지 않는다(bash, `.claude/skills/`의 심볼릭 링크) |
| 도구 | `git`, `gh`(로그인), `jq`, bash; `npx … init`에는 Node 18 이상 | bash만으로 설치하면 Node는 필요 없다 |

**mattpocock 스킬셋 위에서 동작한다.** 워커는 루프 스크립트에 박힌 지시가 아니라 저장소에 커밋된 스킬을 따르고, 그 스킬은 [mattpocock/skills](https://github.com/mattpocock/skills)(MIT)에서 온다. 설치기는 `tdd`와 `code-review`(→ `ticket-review`)를 `.agents/skills/`에 벤더링해 upstream 커밋에 고정하므로, 그 컴퓨터에 무엇이 설치돼 있든 모든 워커가 같은 버전을 쓴다. 루프가 `/implement N`(Codex는 `$implement N`)으로 보내는 프로젝트 소유 `implement` 스킬은 upstream `implement`에서 가져와 `tdd` → `ticket-review` → `pr`을 부른다. 기획 스킬(`grill-with-docs`, `to-spec`, `to-tickets`, `retro`)은 선택(`--workflow-skills`)이다 — 루프가 소비하는 스펙 이슈와 티켓을 만들고 끝난 뒤 회고를 하지만, 루프 자체는 없어도 돈다. `docs/agents/issue-tracker.md`는 upstream의 GitHub 트래커 템플릿에서 왔다. 이 스킬들을 이미 플러그인이나 `npx skills`로 쓰고 있다면 아래 「mattpocock 스킬: 무엇을 들이고, 무엇을 검사하나」를 본다 — 설치기가 겹침을 찾아낸다. 스킬 사본은 `.agents/skills/<이름>`(Codex가 읽음) 하나이고 `.claude/skills/<이름>`은 그 심볼릭 링크다(Claude Code가 읽음).

**설치 전에 알아둘 제약.**

- 워커는 권한 확인을 끄고 돈다. 잘못된 병합이나 강제 push를 막는 진짜 방어선은 기본 브랜치의 GitHub 브랜치 보호다. 키트가 `.claude/settings.json`에 `deny`를, `.codex/rules/ticket-loop.rules`에 같은 금지를 넣지만 둘째 줄이지 첫째 줄이 아니다.
- 저장소당 루프 하나(`.git` 아래 잠금 디렉터리). 루프는 자기 상태를 두지 않고 GitHub(라벨·담당자·PR)가 상태다.
- 티켓은 한 번에 하나, 매번 새 워크트리와 빈 컨텍스트에서 처리한다. 워커는 기본 브랜치에 커밋된 것만 보므로 스킬·워커 규칙·`AGENTS.md`/`CLAUDE.md` 변경은 병합한 뒤에야 적용된다.
- 무거운 테스트(통합·E2E)는 워커가 돌리지 않는다. 루프가 병합마다 기본 브랜치에서 `POST_MERGE_CMD`를 돌리고 실패하면 멈춘다.
- 키트 저장소는 아직 비공개다. 설치에는 초대와 `gh auth login`(npx면 `gh auth setup-git` 한 번)이 필요하다.

## 설치

대상 저장소 루트에서:

```bash
npx github:iwishash/ticket-loop-kit init
```

백엔드와 설치 단계를 키보드로 고르고(↑↓·숫자·Space·Enter, q로 중단) `install.sh`를 부른 뒤 `.ticket-loop/loop.env`에 `BACKEND=` 줄을 쓴다. 묻지 않으려면 `--yes`(터미널이 아니면 자동). 색은 `NO_COLOR`로 끈다. SSH 별칭 원격이나 키체인 자격 증명을 쓰면 `gh auth setup-git`은 필요 없다. 키트 버전을 고정하려면 `npx github:iwishash/ticket-loop-kit#v0.8.0 init`. 저장소가 비공개인 동안은 이 저장소에 초대받고 `gh auth login` 뒤 `gh auth setup-git`을 한 번 해 두면 npx가 받아 간다(macOS 키체인에 GitHub 자격 증명이 있어도 된다).

npx 없이 bash로만 설치하려면:

```bash
bash <(gh api repos/iwishash/ticket-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

그다음 Claude Code(또는 Codex에서 `$setup-ticket-loop`)에서:

1. `/setup-ticket-loop` — 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`를 이 저장소에 맞춰 채우고 PR을 연다

마지막으로 Orca 앱에서 Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기. PR을 병합한 뒤 `bash scripts/ticket-loop.sh --dry-run` → `--max 1`.

필요한 도구: `git`, `gh`(로그인), `jq`, 백엔드(Orca 앱과 CLI, cmux, 또는 tmux), 워커 에이전트(Claude Code 또는 Codex — 위 표).

## 누가 무엇을 하나

| 주체 | 하는 일 |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) — 질문과 껍질 | 백엔드 선택, `.ticket-loop/loop.env`의 `BACKEND=` 줄(없을 때만), 설치 단계 켜고 끄기, 도구 점검, 설치한 키트 커밋을 `install.sh`에 넘김 |
| `install.sh` — 어느 저장소에서나 같은 부분 | 스킬 충돌 검사(아래), 루프·진단·스킬 동기화 스크립트와 `setup-ticket-loop` 스킬 설치, mattpocock 스킬 벤더링(`tdd`·`ticket-review`, 선택하면 기획 묶음), `docs/agents/issue-tracker.md` 템플릿, `.gitignore`·`deny` 병합, 라벨 6개, git 자격 증명(gh), Orca 등록, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` — 저장소를 읽어야 정하는 부분 | `implement`·`pr`·`worker-rules.md`의 `__PLACEHOLDER__` 채우기(검증 명령, 무거운 스위트와 그 파일 하나를 돌리는 명령 — 워커는 자기가 손댄 파일만 PR 직전 1회, 전체는 루프가 병합 뒤), `verify` 명령, `orca.yaml`, CI, `.ticket-loop/loop.env`, `docs/agents/ticket-loop.md`, `CLAUDE.md` 포인터 → PR |
| 사람 | Orca 앱 설정(Command Source "orca.yaml only"), PR 병합, `--max 1` 시험 지켜보기 |

키트의 `ticket-loop.sh`는 가이드북 3판 부록 D의 스크립트에 저장소별 기본값 파일 `.ticket-loop/loop.env` 읽기와 시작 전 포트 점검을 더한 것이다. `POST_MERGE_CMD`, `POST_MERGE_PORT` 같은 저장소 고정값은 거기에 `VAR="${VAR:-값}"` 꼴로 적어 커밋하고, 실행할 때 준 환경변수가 이긴다.

저장소 CI가 경로 필터(`paths`/`paths-ignore`)로 일부 PR에서 돌지 않는다면 `CI_SKIP_REGEX`(단순 제외 목록) 또는 `CI_SKIP_CMD`(파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 저장소 스크립트)로 같은 판정을 루프에 알려 준다. GitHub는 필터에 걸린 PR에 체크를 아예 만들지 않아 루프가 "아직 안 떴다"와 "안 뜬다"를 구별할 수 없기 때문이다. 이것은 루프가 정하는 규칙이 아니라 저장소 필터를 따라 하는 것이고, 필터가 없으면 비워 둔다(기본: 모든 PR에서 체크를 기다린다).

티켓을 병합해 닫은 뒤와 `--parent` 실행이 끝날 때, 루프는 그 스펙 이슈의 하위 이슈 목록을 세어 모두 닫혔으면 스펙 이슈도 코멘트와 함께 닫는다(요약 값이 아니라 목록을 센다). 하위 이슈가 하나라도 열려 있으면 그대로 둔다.

루프가 남기는 것은 세 가지다. 진행 로그 `.ticket-loop/loop-MMDD.log`(사람이 읽는다), 티켓별 기록 `.ticket-loop/tickets.jsonl`(기계별, 커밋하지 않는다), 그리고 `--parent <스펙>` 실행이 정상 종료할 때 쓰는 스펙 리포트 `docs/loop-reports/spec-<N>.html`(티켓별 상태·결과 브리프·경과 시간·모델 한 표, 사람이 보고 PR로 커밋한다). 이번 실행에서 끝난 스펙이 있으면 마지막에 `/retro`로 돌아보기를 권하는 안내 한 줄과 읽을 자료를 남긴다. 권고일 뿐 회고를 자동으로 돌리지는 않는다. `POST_MERGE_PORT`를 정한 저장소에서는 포트가 차 있을 때 점유 프로세스를 적고 30초마다 다시 보며 기다린다. 시작할 때 이미 차 있으면 "주의" 한 줄을 적는다.

## 백엔드

루프 스크립트에서 워크트리·에이전트 터미널에 하는 일은 아홉 가지뿐이다(만들기·지우기·프롬프트 보내기·셸 입력·Ctrl-C·idle 대기·화면 읽기·상태 표시·시작 점검). 백엔드마다 같은 이름의 함수(`orca_*`, `cmux_*`, `tmux_*`)로 구현하고 `.ticket-loop/loop.env`의 `BACKEND=orca|cmux|tmux`로 고른다. 티켓 선택·PR·CI·수리·병합·병합 뒤 검증·기록·스펙 리포트는 한 벌이다.

| | Orca | cmux | tmux |
|---|---|---|---|
| 워크트리 | `orca worktree create`가 만들고 `orca.yaml` setup을 돌린다 | 루프가 `git worktree add`(`WORKTREE_DIR`, 기본 `~/.cache/ticket-loop/<owner-repo>/worktrees`) 뒤 `WORKTREE_SETUP_CMD`를 돌린다 | cmux와 같다 |
| 에이전트 | Orca가 `--agent claude --prompt`로 띄운다 | `cmux workspace create --cwd … --command "claude … \"$(cat 프롬프트파일)\""` — 워크스페이스 셸의 claude shim이 Claude Code 훅을 붙인다 | `TMUX_SESSION`(기본 `ticket-loop`, tmux 안에서 돌리면 그 세션)에 창을 열고 셸에 `claude … --settings <훅 설정> "$(cat 프롬프트파일)"`을 친다 |
| idle 판정 | `orca terminal wait --for tui-idle`(블로킹) | `cmux rpc surface.input_state`의 `lifecycle`을 5초마다 읽는다(Claude Code 훅이 보고) | 루프가 `~/.cache/ticket-loop/<owner-repo>/tmux/`에 쓴 훅(`UserPromptSubmit`→running, `Stop`→idle, `Notification`의 permission_prompt→needsInput, `SessionEnd`→exited)이 `state/<워크트리 이름>` 파일에 쓰고, 루프가 5초마다 읽는다 |
| 입력·화면 | `orca terminal send / read` | `cmux paste --submit`, `send --force` + `send-key enter`, `read-screen --lines 25`. 보내기 전에 하이버네이션에서 깨운다 | `send-keys -l` + `Enter`(0.3초 뒤), `capture-pane -p`의 빈 줄을 뺀 마지막 25줄. 프롬프트 수락은 15초 안에 상태 파일이 running이 되는지로 안다 |
| 상태 표시 | `orca worktree set --workspace-status` | `cmux workspace status set`, `cmux pr`, `cmux log` | 창 이름 뒤에 `[working]`·`[review]`·`[done]`·`[needs-attention]` |
| 실행 조건 | Orca 앱 실행 중, 저장소 등록 | cmux 터미널 안에서 실행(소켓 모드 기본값 `cmuxOnly`). Claude Code가 메인 체크아웃을 신뢰한 상태(시작 때 검사) | `tmux` 설치. Claude Code가 메인 체크아웃을 신뢰한 상태(시작 때 검사). `AGENT=claude\|codex`만(idle을 에이전트 훅으로 알기 때문). 사람은 `tmux attach -t ticket-loop`으로 본다 |

세 백엔드 모두 실제 티켓 1건씩으로 확인했다(boiler-webapp #34 Orca, #39 cmux, ticket-loop-dummy #1 tmux — 셸 스크립트 저장소에서 워크트리 생성 → 워커 기동 → TDD·ticket-review → PR #2 → CI → 병합 → 창·워크트리·브랜치 정리 → 기록까지 벽시계 4분, 수리 0회). tmux 실측에서 본 것 둘: (1) Claude Code는 새 워크트리의 폴더 신뢰를 메인 체크아웃 경로로 판정한다 — 메인 체크아웃을 신뢰하지 않은 저장소에서는 워커가 신뢰 대화상자에 멈추므로 cmux·tmux의 시작 점검이 `~/.claude.json`을 보고 막는다. (2) `Stop` 훅은 메인 에이전트의 턴이 끝날 때마다 오므로 워커가 백그라운드 서브에이전트(ticket-review)를 기다리는 동안 한 번 idle로 보였다. 서브에이전트가 돌아오면 Claude Code가 스스로 턴을 열어 running이 되고, 공통부는 화면이 바뀌면 연속 횟수를 0부터 세므로 멈추지 않았다(cmux의 lifecycle도 같은 훅에 기댄다). Warp·Ghostty 같은 터미널 에뮬레이터는 밖에서 창을 조종할 CLI가 없어 백엔드가 아니다 — 그 안에서 tmux 백엔드를 돌린다. cmux 0.65 실측: `--json`은 명령 뒤에 둬야 JSON이 나오고(`workspace create --json --id-format uuids` → `workspace_id`·`surface_id`), lane은 `todo|working|needs-attention|review|done`, 프로세스가 살아 있는 워크스페이스는 `workspace close --force`로만 닫힌다. 루프는 cmux 터미널 안에서 띄워야 한다 — 소켓 모드 기본값이 `cmuxOnly`라 밖에서는 `cmux identify`가 거부된다.

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh` | `scripts/ticket-loop.sh` | 매번 덮어씀(키트 소유) |
| `files/scripts/ticket-state.sh` | `scripts/ticket-state.sh` | 매번 덮어씀 |
| `files/scripts/sync-mattpocock-skills.sh` | `scripts/sync-mattpocock-skills.sh` | 매번 덮어씀 |
| `files/.agents/skills/setup-ticket-loop/` | 같은 경로 + `.claude/skills/setup-ticket-loop` 링크 | 매번 덮어씀 |
| `templates/.agents/skills/implement/`, `pr/` | 같은 경로 + `.claude/skills/<이름>` 링크 | 없을 때만(이후 프로젝트 소유). `agents/openai.yaml`은 Codex 메타데이터 |
| `templates/.codex/rules/ticket-loop.rules` | 같은 경로 | 없을 때만 — `deny` 규칙의 Codex 판(병합·강제 push·기본 브랜치 직접 push 금지). 기본 브랜치는 설치기가 채운다 |
| `templates/.ticket-loop/worker-rules.md` | 같은 경로 | 없을 때만 |
| `templates/docs/loop-reports/README.md` | 같은 경로 | 없을 때만 |
| `templates/docs/agents/issue-tracker.md` | 같은 경로 | 없을 때만 — GitHub 트래커 관례. 벤더링된 스킬과 `implement`가 읽는다 |
| — | `.agents/skills/tdd`, `ticket-review` (+ 기획 묶음 7개)와 `.claude/skills/<이름>` 링크 | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`(`/.ticket-loop/*.log`, `/.ticket-loop/*.jsonl`), `.claude/settings.json` `deny` | 줄·항목 병합 |
| — | GitHub 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.ticket-loop/kit.json` | 설치한 키트 커밋 기록 |

스킬은 `.agents/skills/<이름>`(Codex가 읽는 디렉터리)에 한 번만 두고, `.claude/skills/<이름>`은 Claude Code를 위한 심볼릭 링크다 — `npx skills add`와 같은 배치. 0.6 이하로 설치한 저장소는 `.claude/skills/` 아래 실제 디렉터리를 갖고 있는데, 설치기와 동기화 스크립트가 `git mv`로 옮기고 링크를 남긴다. 벤더링된 스킬이 읽는 `## Agent skills` 블록은 `AGENTS.md`에 두고(Codex는 그 파일만 읽는다) `CLAUDE.md`는 `@AGENTS.md`로 가져온다 — `/setup-ticket-loop`가 둘 다 쓴다.

프로젝트별 값은 대상 저장소의 `.ticket-loop/loop.env`(루프 기본값, `BACKEND`·`AGENT` 포함), `orca.yaml`(Orca), `.ticket-loop/worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 mattpocock 스킬만 바뀌고, 프로젝트 소유 파일(`loop.env` 포함)은 그대로다. 0.3 이하가 설치한 저장소는 설치기가 `.agent-loop/`(0.2 이하는 `.orca-loop/`)를 `.ticket-loop/`로 `git mv`하고(로그·기록 포함), 옛 스킬 `setup-agent-loop`·`setup-orca-loop`와 `.gitignore`의 옛 줄을 지운다. 그 뒤 옛 경로를 아직 가리키는 파일(`docs/agents/ticket-loop.md`, `CLAUDE.md`, `loop.env`의 `REPORT_DIR` 등)이 있으면 목록을 보여 주니 손으로 고쳐 같은 PR에 넣는다. 특정 버전으로 고정하려면 `npx github:iwishash/ticket-loop-kit#v0.8.0 init`(bash 경로는 `--ref v0.3.0`). 바뀐 것은 `git diff`로 보고 PR로 올린다. npx는 한 번 받은 저장소를 캐시하므로, 같은 ref로 다시 받으려면 `npx --yes --prefer-online` 또는 `npm cache clean --force`.

옵션: `--yes`, `--backend <orca|cmux|tmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). bash 경로는 `--ref <ref>`도 받는다(`bash install.sh --help`).

## mattpocock 스킬: 무엇을 들이고, 무엇을 검사하나

루프 스크립트 자체는 스킬에 기대지 않는다. 워커에게 `/implement N`을 보낼 뿐이고, 그 `implement`(프로젝트 소유 템플릿)가 Skill 도구로 `tdd`와 `ticket-review`를 부른다. 그래서 키트는 upstream [mattpocock/skills](https://github.com/mattpocock/skills)(MIT) 중 두 묶음만 `.claude/skills/`에 파일로 들인다(벤더링). 플러그인이 아니라 파일인 이유는 워커 워크트리와 클라우드 세션이 clone만으로 같은 버전을 쓰고, 무인 루프 도중 자동 업데이트로 동작이 바뀌지 않게 하려는 것이다.

| 묶음 | 스킬 | 기본 |
|---|---|---|
| core | `tdd`, `code-review` → `ticket-review`(내장 `/code-review`와 이름이 겹쳐서) | 항상 |
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`와 그것들이 부르는 `grilling`, `domain-modeling`, `writing-for-agents` | 꺼짐. `--workflow-skills` 또는 대화형 체크리스트. 지난 설치가 들였으면 유지 |
| kept | 지난 설치(0.5 이하는 26개 전부)가 두 묶음 밖에 놓은 것. 예: `implement-spec`, `grill-me`, `triage` | 유지하고 함께 동기화한다. 새 설치에는 들이지 않는다. `--prune-skills`(또는 체크리스트 항목)로만 지운다 |

나머지 upstream 스킬(`ask-matt`, `wizard`, `teach` …)은 새 설치에는 들이지 않는다. 쓰고 싶으면 플러그인(`claude plugin install mattpocock-skills@claude-plugins-official`)으로 따로 설치한다. 이미 들어 있는 저장소에서는 그대로 둔다 — 키트가 넣은 것이니 사용자가 쓰고 있을 수 있고, 갱신도 키트가 같은 upstream 커밋으로 계속 한다. 매니페스트(`.agents/skills/.mattpocock.json`)의 `kept`에 목록이 남는다. 손으로 지운 스킬은 다시 들이지 않고, upstream에서 사라진 스킬은 그대로 둔다. 예외는 `setup-matt-pocock-skills` 하나로, 이 키트가 그 역할을 대신하므로 지운다. `/setup-matt-pocock-skills`는 더는 필요 없다 — 그 스킬이 만들던 `docs/agents/issue-tracker.md`는 키트 템플릿이 놓고, `AGENTS.md`의 `## Agent skills` 블록(`CLAUDE.md`가 `@AGENTS.md`로 가져온다)은 `/setup-ticket-loop`가 쓴다.

설치기는 바꾸기 전에 같은 스킬이 다른 경로로 이미 있는지 본다(Claude Code는 중복을 경고하지 않는다. `bash scripts/sync-mattpocock-skills.sh --check`로 따로 돌릴 수 있다).

| 발견 | 무슨 일이 생기나 | 처리 |
|---|---|---|
| `mattpocock-skills` 플러그인이 이 저장소에 켜져 있음(`enabledPlugins`, user < project < local) | 둘 다 로드돼 `/tdd`와 `/mattpocock-skills:tdd`가 함께 뜬다 | 경고. 대화형이면 "이 저장소에서 플러그인 끄기"를 체크리스트에 보여 주고, 고르면 `claude plugin disable … --scope project` |
| `~/.claude/skills/<이름>`에 같은 스킬 | 개인 스킬이 프로젝트 스킬을 가려, 커밋한 버전이 아니라 그 PC의 사본이 돈다 | 경고 + 이름 목록. 지우거나 감수 |
| `npx skills add`가 둔 `skills-lock.json`, 또는 이 저장소의 `.agents/skills/<이름>`이 아닌 곳을 가리키는 `.claude/skills/*` 링크(키트 자신의 링크는 정상) | 두 도구가 같은 디렉터리를 번갈아 덮어쓴다 | **설치 중단**. `npx skills remove`로 걷어낸 뒤 재실행(`--force-skills`로 강행, `--no-skills`로 건너뜀) |
| `code-review` 스킬 디렉터리(`.agents/skills/` 또는 `.claude/skills/`) | 프로젝트 스킬이 내장 `/code-review`를 대체한다. 키트는 `ticket-review`를 쓴다 | 경고 + `rm -rf` 안내 |
| 매니페스트에 없는 같은 이름 디렉터리, `.claude/commands/<이름>.md` | 덮어쓴다 / 스킬이 우선하지만 둘이 남는다 | 알림 |
| 지난 설치가 두 묶음 밖에 들인 스킬 | 유지·동기화 | 알림 + 이름 목록. `--prune-skills`로 지운다 |

## 여러 컴퓨터에서 같은 저장소를 돌릴 때

한 번 설치한 저장소는 클론만 하면 다른 컴퓨터에서도 바로 돈다. 재설치는 키트 버전을 올릴 때만 한 컴퓨터에서 하고, 나머지는 `git pull`로 받는다.

- 루프에 필요한 것은 전부 커밋돼 있다 — `scripts/ticket-loop.sh`, `.ticket-loop/loop.env`(`BACKEND`, `WORKTREE_SETUP_CMD` 포함), `worker-rules.md`, `kit.json`, `implement`·`pr` 스킬. 기계별인 것은 `.ticket-loop/*.log`와 `tickets.jsonl`뿐이고 둘 다 `.gitignore`다. 새 컴퓨터에서는 빈 상태로 새로 쌓인다.
- 백엔드는 컴퓨터마다 달라도 된다. `loop.env`의 값은 `${BACKEND:-orca}` 꼴이라 실행할 때 준 환경변수가 이긴다 — A는 Orca로 `bash scripts/ticket-loop.sh N`, B는 cmux 터미널 안에서 `BACKEND=cmux bash scripts/ticket-loop.sh N`, C는 아무 터미널에서 `BACKEND=tmux bash scripts/ticket-loop.sh N`. cmux·tmux를 쓸 저장소는 `loop.env`에 `WORKTREE_SETUP_CMD`가 있어야 한다.
- 워크트리는 백엔드가 각자 자기 자리에 둔다(Orca는 Orca 설정 위치, cmux·tmux는 `~/.cache/ticket-loop/<owner-repo>/worktrees`). 저장소 안에는 흔적이 없어 컴퓨터끼리 충돌하지 않는다.
- 새 컴퓨터의 전제는 평소와 같다: `gh auth login`, `claude`, `jq`, 저장소의 패키지 매니저. cmux·tmux면 메인 체크아웃에서 `claude`를 한 번 열어 폴더를 신뢰해 둔다 — Claude Code는 워크트리의 신뢰를 메인 체크아웃 경로로 판정하므로, 안 해 두면 워커가 새 워크트리마다 신뢰 대화상자에 멈춘다(루프가 시작 때 `~/.claude.json`을 보고 막는다). cmux면 cmux 터미널 안에서 실행하고(소켓 모드 기본값 `cmuxOnly`) Settings의 Claude Code 통합이 켜져 있어야 한다 — 꺼져 있으면 `lifecycle`이 `unknown`만 돌아와 기동 유예 뒤 타임아웃으로 멈춘다.
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
- tmux 백엔드의 수리 경로(충돌·CI 실패 뒤 `repair`가 보내는 프롬프트). 더미 저장소 1건은 수리 0회였다. 함수 단위(`tmux_send`가 상태 파일로 수락을 확인)와 실제 Claude Code에 `send-keys`로 보낸 두 번째 프롬프트까지는 확인했다
- 출처 저장소 rsrehab/rental-portal은 아직 저장소 전용판 `scripts/orca-ticket-loop.sh`를 쓴다(키트로 전환하지 않음)
- Codex를 워커로 쓰는 것. 조각은 갖춰졌다 — `loop.env`의 `AGENT=codex` 프리셋(기동 명령 `codex --dangerously-bypass-approvals-and-sandbox`, 배너·모델 정규식, `$implement N`), 에이전트 중립 워커·수리 프롬프트, `.agents/skills/` 정본과 `.claude/skills/` 링크, `AGENTS.md`의 `## Agent skills`, `.codex/rules/ticket-loop.rules`, 설치기 `--agent codex`. 하지만 어느 것도 Codex가 설치된 컴퓨터에서 돌려 보지 않았다: idle 판정(Orca `tui-idle`, cmux shim의 lifecycle 훅), `$implement`가 스킬을 집는지, 수리 프롬프트, `.codex/rules/ticket-loop.rules`가 로드되는지(`codex execpolicy check --rules .codex/rules/ticket-loop.rules -- gh pr merge 12`)와 `--dangerously-bypass-approvals-and-sandbox` 아래에서도 유지되는지. 백엔드마다 티켓 1건이 지나가기 전에는 "지원"이 아니다
