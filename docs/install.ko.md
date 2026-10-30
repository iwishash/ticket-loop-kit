# 설치와 업데이트

[README](../README.ko.md) · [English](install.md)

## 설치 환경

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

## 누가 무엇을 하나

| 주체 | 하는 일 |
|---|---|
| `npx … init` (`bin/ticket-loop-kit.js`) | 백엔드 선택(`.ticket-loop/loop.env`의 `BACKEND=` 줄, 없을 때만), 설치 단계 켜고 끄기, 도구 점검, `install.sh` 호출 |
| `install.sh` (어느 저장소에서나 같은 부분) | 스킬 충돌 검사, 루프·동기화 스크립트, `setup-ticket-loop` 스킬, mattpocock 스킬 벤더링, 템플릿, `.gitignore`·`deny` 병합, 라벨 6개, git 자격 증명(gh), Orca 등록, `.ticket-loop/kit.json` |
| `/setup-ticket-loop` (저장소를 읽어야 정하는 부분) | `implement`·`pr`·`worker-rules.md`의 `__PLACEHOLDER__` 채우기(검증 명령, 무거운 스위트와 그 파일 하나를 돌리는 명령), `orca.yaml`, CI, `loop.env`, `docs/agents/ticket-loop.md`, `CLAUDE.md` 포인터 → PR |
| 사람 | Orca 설정, PR 병합, `--max 1` 시험 지켜보기 |

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh`, `ticket-state.sh`, `sync-mattpocock-skills.sh` | `scripts/` | 매번 덮어씀(키트 소유) |
| `files/.agents/skills/setup-ticket-loop/`, `loop-triage/` | 같은 경로 + `.claude/skills/` 링크 | 매번 덮어씀 |
| `templates/.agents/skills/implement/`, `pr/` | 같은 경로 + `.claude/skills/` 링크 | 없을 때만(이후 프로젝트 소유) |
| `templates/.codex/rules/ticket-loop.rules` | 같은 경로 | 없을 때만. `deny` 규칙의 Codex 판, 기본 브랜치는 설치기가 채운다 |
| `templates/.ticket-loop/worker-rules.md`, `docs/loop-reports/README.md`, `docs/agents/issue-tracker.md` | 같은 경로 | 없을 때만 |
| — | `.agents/skills/tdd`, `ticket-review`(+ 기획 묶음)와 `.claude/skills/` 링크 | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`(`/.ticket-loop/*.log`, `*.jsonl`, `stops/`), `.claude/settings.json`의 `deny` | 병합 |
| — | GitHub 라벨 6개, git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.ticket-loop/kit.json` | 설치한 키트 커밋 기록 |

스킬은 `.agents/skills/<이름>`에 한 번만 두고 `.claude/skills/<이름>`은 링크다(`npx skills add`와 같은 배치). 0.6 이하 설치본은 `git mv`로 옮겨진다. `## Agent skills` 블록은 `AGENTS.md`에 두고(Codex는 그 파일만 읽는다) `CLAUDE.md`가 `@AGENTS.md`로 가져온다. `/setup-ticket-loop`가 둘 다 쓴다. 프로젝트별 값은 `loop.env`, `orca.yaml`, `worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 벤더링한 스킬만 바뀌고 프로젝트 소유 파일(`loop.env` 포함)은 그대로다. 0.3 이하 설치본은 마이그레이션된다(`.agent-loop/` 또는 `.orca-loop/` → `.ticket-loop/`, 옛 스킬과 `.gitignore` 줄 제거). 옛 경로를 아직 가리키는 파일은 설치기가 목록으로 보여 주니 같은 PR에서 손으로 고친다. `git diff`로 보고 PR로 올린다. npx는 받은 저장소를 캐시하므로 같은 ref를 다시 받으려면 `npx --yes --prefer-online`.

옵션: `--yes`, `--backend <orca|cmux|tmux>`, `--no-skills`, `--workflow-skills`/`--no-workflow-skills`, `--force-skills`, `--prune-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`npx github:iwishash/ticket-loop-kit --help`). bash 경로는 `--ref <ref>`도 받는다. 버전 고정은 `npx github:iwishash/ticket-loop-kit#v0.9.21 init`, `NO_COLOR`로 색을 끈다.

## mattpocock 스킬: 무엇을 들이고, 무엇을 검사하나

**박힌 프롬프트가 아니라 스킬.** 워커는 저장소에 커밋된 스킬을 따르고, 그 스킬은 [mattpocock/skills](https://github.com/mattpocock/skills)(MIT)에서 온다. `tdd`와 `code-review`(→ `ticket-review`)를 `.agents/skills/`에 벤더링해 upstream 커밋에 고정하므로 모든 워커가 같은 버전을 쓴다. 루프가 `/implement N`(Codex는 `$implement N`)으로 보내는 프로젝트 소유 `implement` 스킬이 `tdd` → `ticket-review` → `pr`을 부른다. 기획 스킬(`grill-with-docs`, `to-spec`, `to-tickets`, `retro`)은 선택(`--workflow-skills`)이다. 스킬 사본은 `.agents/skills/<이름>`(Codex가 읽음) 하나이고 `.claude/skills/<이름>`은 그 심볼릭 링크다(Claude Code가 읽음).

플러그인이 아니라 파일로 벤더링하는 이유는 워크트리와 클라우드 세션이 clone만으로 같은 버전을 쓰고, 무인 실행 도중 자동 업데이트로 동작이 바뀌지 않게 하려는 것이다.

| 묶음 | 스킬 | 기본 |
|---|---|---|
| core | `tdd`, `code-review` → `ticket-review`(내장 `/code-review`와 이름이 겹쳐서) | 항상 |
| workflow | `grill-with-docs`, `to-spec`, `to-tickets`, `retro`와 `grilling`, `domain-modeling`, `writing-for-agents` | 새 설치: 켬. 단 `mattpocock-skills` 플러그인이 이 저장소에 켜져 있으면 끔(이 머신에서는 플러그인이 준다). 재설치: 지난 선택. `--workflow-skills` / `--no-workflow-skills`가 우선 |
| kept | 지난 설치(0.5 이하는 26개 전부)가 두 묶음 밖에 놓은 것 | 유지·동기화하고 새 설치에는 들이지 않는다. `--prune-skills`로 지운다 |

세 묶음은 매니페스트 `.agents/skills/.mattpocock.json`에 기록된다. 손으로 지운 스킬은 다시 들이지 않고, upstream에서 사라진 스킬은 그대로 둔다. 매니페스트의 `project_owned`는 저장소가 손으로 고쳐 쓰는 스킬 목록이다(기본 `implement`·`pr`). 들인 스킬의 이름(예: `ticket-review`)을 거기 더하면 동기화가 그 디렉터리를 건드리지 않고 `project-owned (update by hand)`에 함께 보여 준다. 그 밖의 들인 스킬은 덮어쓰되, 지난 동기화의 upstream 사본과 달랐으면(커밋된 수정 포함) 요약에 `overwrote local edits: <이름>`을 내어 git에서 되돌리고 `project_owned`에 적을 수 있게 한다. 나머지 upstream 스킬은 플러그인(`claude plugin install mattpocock-skills@claude-plugins-official`)으로 쓴다.

설치기는 바꾸기 전에 같은 스킬이 다른 경로로 이미 있는지 본다(`bash scripts/sync-mattpocock-skills.sh --check`로 따로 돌릴 수 있다):

| 발견 | 처리 |
|---|---|
| `mattpocock-skills` 플러그인이 이 저장소에 켜져 있음(선택기에 `/tdd`와 `/mattpocock-skills:tdd`가 나란히 보인다. 루프는 벤더링한 쪽을 돈다) | 알림. `tdd`·`ticket-review`는 그래도 들이고, 새 설치의 기획 스킬은 플러그인에 맡긴다. 체크리스트의 `claude plugin disable … --scope project`는 기본 꺼짐(켜면 기획 스킬도 함께 벤더링) |
| `~/.claude/skills/<이름>`에 같은 스킬(커밋한 사본을 가린다) | 경고 + 이름 목록 |
| `npx skills add`의 `skills-lock.json`, 또는 이 저장소의 `.agents/skills/` 밖을 가리키는 `.claude/skills/*` 링크 | **설치 중단**. `npx skills remove`로 걷어낸 뒤 재실행(`--force-skills`로 강행, `--no-skills`로 건너뜀) |
| `code-review` 스킬 디렉터리(내장 `/code-review`를 대체) | 경고 + `rm -rf` 안내 |
| 매니페스트에 없는 같은 이름 디렉터리, `.claude/commands/<이름>.md` | 알림 |

플러그인과 `~/.claude/skills` 검사는 `--agent claude`일 때만 돌고, `--agent codex`면 같은 이름의 `~/.agents/skills/<이름>`을 대신 알린다.

## 여러 컴퓨터에서 같은 저장소를 돌릴 때

클론만 하면 다른 컴퓨터에서도 바로 돈다. 재설치는 키트를 올릴 때만 한 컴퓨터에서 하고 나머지는 `git pull`.

- 루프에 필요한 것은 전부 커밋돼 있다. 기계별인 것은 `.ticket-loop/*.log`와 `tickets.jsonl`(ignore), 그리고 저장소 밖의 `~/.config/ticket-loop/loop.env`(Slack Webhook URL 같은 비밀 값, [알림](stops.ko.md#알림-slack과-github-멈춤-기록))뿐이다.
- 백엔드는 컴퓨터마다 달라도 된다. `BACKEND=cmux bash scripts/ticket-loop.sh N`처럼 환경변수가 `loop.env` 기본값을 이긴다. cmux·tmux는 `loop.env`에 `WORKTREE_SETUP_CMD`가 있어야 하고, 워크트리는 `~/.cache/ticket-loop/<owner-repo>/worktrees`에 두며, 메인 체크아웃을 Claude Code가 신뢰해야 한다(거기서 `claude`를 한 번 연다).
- 동시에 돌릴 때는 티켓 번호를 지정하거나 `--parent`·`--label`로 자동 선택 범위를 가른다. 담당자·열린 PR 검사는 몇 초 간격의 경합까지 막지 못한다. 충돌이 난 PR은 수리 단계가 처리한다.
- 스펙 리포트는 그 컴퓨터의 `tickets.jsonl`로 그리므로 한 스펙은 한 컴퓨터에서 돌린다. 기록이 없는 티켓은 PR 시각으로 대신 채운다.
