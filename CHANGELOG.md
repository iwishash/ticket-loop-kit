# Changelog

## 0.8.4 — 2026-10-15

터미널에서 루프를 지켜볼 때 로그가 한 색이라 지금 어느 단계인지(워크트리를 만드는 중인지, CI를 기다리는지, 수리를 돌리는지) 눈으로 찾아야 했다. 단계별로 색을 입혔다.

- `ticket-loop.sh`: `log`가 첫 인자로 단계(`title`·`step`·`ok`·`warn`·`err`)를 받는다 — 티켓 제목은 굵은 자주(앞에 빈 줄), 워크트리·PR 열림·CI 대기·병합 뒤 검증 시작 같은 단계 전환은 청록, CI 통과·병합·요약·완료는 초록, idle 되풀이·수리 요청·건너뜀·포트 대기·삭제 실패는 노랑, `die`의 ERROR는 굵은 빨강. 시각은 흐리게, 워커 화면·검증 로그 꼬리와 대상 목록은 `dim_lines`로 흐리게 들여 쓴다. stderr가 터미널이고 `NO_COLOR`(no-color.org)가 없고 `TERM`이 `dumb`이 아닐 때만 칠한다(설치기와 같은 규칙). 로그 파일로 가는 줄은 `strip_ansi`가 색 코드(SGR)만 지운다 — 다른 이스케이프는 손대지 않고, bash 3.2(macOS 기본)에서도 되는 문자열 처리다. 파이프로 받거나 색을 끄면 전과 같은 맨글자다
- `tests/smoke.sh`: 색을 켠 `log`의 단계별 감싸기와 맨글자 메시지, 색을 끈 `log`의 전과 같은 출력, `strip_ansi`가 SGR만 지우고 다른 이스케이프는 두는 것, 단계 이름만 준 호출은 메시지로 보는 것
- 가이드북: 6장 변수 표 `LOG_FILE` 행에 색 설명, 부록 D 재생성, 부록 E 한 행. PDF 재빌드

## 0.8.3 — 2026-10-15

cmux 백엔드가 일하던 워커를 두고 죽는 오판을 고쳤다. rental-portal v1.9 루프(cmux 0.65, 2026-10-14) 세 번째 티켓 #100에서 워커가 ticket-review 서브에이전트 2개와 Playwright 헤드리스 브라우저를 돌리는 동안 `rpc surface.input_state`의 lifecycle이 빈 값으로 5번(25초) 이어졌고, `cmux_wait_idle`이 그것을 "앱 종료"로 단정해 `die`했다. 앱은 16시부터 켜져 있었고 서피스도 살아 있었으며 워커는 루프가 죽은 뒤 3분 만에 리뷰 반영 커밋과 PR 본문까지 혼자 마쳤다(병합만 사람 몫으로 남았다). Orca가 #72(0.6.x)에서 배운 규칙을 cmux에도 적용했다.

- `ticket-loop.sh`: `cmux_alive`(`read-screen --lines 1`이 성공하면 서피스가 있다). `cmux_wait_idle`은 lifecycle이 빈 값이어도 화면이 읽히면 작업 중으로 보고 계속 기다린다(처음 한 번 "lifecycle 빈 값 — 화면은 읽혀 계속 기다린다"를 로그에 남긴다). `TERMINAL_RETRY`번 연달아 화면도 못 읽을 때만 3(닿지 못함)이고, 그 사이 `TERMINAL_RETRY_SEC`씩 쉰다 — 전에는 빈 값 사이 간격이 `IDLE_POLL_SEC`(5초)뿐이라 25초면 죽었다
- `tests/smoke.sh`: 가짜 cmux로 `cmux_wait_idle` 세 경우 — idle → 0, 빈 값·화면 읽힘 → 1(계속 기다림)과 안내 로그, 빈 값·화면도 못 읽음 → 3

## 0.8.2 — 2026-10-14

- 스펙 리포트 자동 열기. `--parent` 실행이 리포트를 쓰면 기본 브라우저로 연다(macOS `open`, Linux `xdg-open`). 리포트는 사람이 보라고 만든 것이라 경로를 찾아 여는 한 단계를 줄였다. SSH 세션(`SSH_CONNECTION`·`SSH_TTY`)이나 `DISPLAY`·`WAYLAND_DISPLAY`가 없는 Linux에서는 열지 않고, 열기 실패는 루프 결과를 바꾸지 않는다. 새 변수 `REPORT_OPEN`(기본 1, `0`이면 끔). `--dry-run`과 `die`로 멈춘 실행은 리포트를 쓰지 않으니 열지도 않는다. `tests/smoke.sh`가 `open_report`의 세 경우(끔 → 안 연다, SSH → 안 연다, 켬 → 연다)를 가짜 `open`으로 본다. `setup-ticket-loop` 결정 표와 `docs/loop-reports/README.md` 템플릿에 한 줄
- 가이드북: 2.5절 cmux·tmux 백엔드(루프가 백엔드에 시키는 아홉 가지 일의 Orca/cmux/tmux 대응표, 실행 조건과 메인 체크아웃 신뢰, `WORKTREE_SETUP_CMD`, 훅 기반 idle의 성질, 실측), 4장 끝 Windows 절(WSL2 + tmux 백엔드 W1~W5, Windows용 Orca는 선택), 본문의 Orca 전용 표현을 백엔드 기준으로, 3장 상태 표에 cmux lane·tmux 창 이름, 6장 변수 표에 `BACKEND`·`CMUX_CLI`·`TMUX_CLI`·`TMUX_SESSION`·`WORKTREE_DIR`·`WORKTREE_SETUP_CMD`·`REPORT_OPEN`, 10장 복구에 cmux·tmux 경우, FAQ 두 문항, 부록 A에 cmux·tmux 명령, 부록 D 재생성, 부록 E 두 행. PDF 재빌드

## 0.8.1 — 2026-10-14

저장소를 공개로 전환했다(2026-10-14). LICENSE(MIT) 추가, `package.json`의 license를 `UNLICENSED`에서 `MIT`로.

- 설치 명령: bash 한 줄 설치를 `gh api …contents/install.sh`에서 `curl -fsSL https://raw.githubusercontent.com/…/main/install.sh`로. `install.sh`가 키트를 받을 때 `gh repo clone` 대신 HTTPS `git clone`을 먼저 쓰고(자격 증명 불필요), 실패하면 `gh repo clone`으로 넘어간다. `npx github:… init`은 그대로(공개 저장소라 `gh auth setup-git`이 더는 필요 없다)
- README(영·한): 비공개·초대·`gh auth setup-git` 안내 제거, 두 벌을 절반 분량으로(실측 서사는 이 CHANGELOG에), OS 행을 macOS 확인 / Linux·WSL 미검증 / 네이티브 Windows 미지원으로 분리

## 0.8.0 — 2026-10-13

tmux 백엔드(`BACKEND=tmux`). "지원 터미널이 Orca·cmux 둘뿐인데 tmux·Warp·Ghostty도 되지 않나"라는 질문에서 나왔다. 루프가 백엔드에 요구하는 것은 함수 아홉 개뿐이라 자리는 있었고, 난점은 하나 — tmux에는 Orca의 `tui-idle`·cmux의 `lifecycle` 같은 "에이전트가 일을 마쳤다"는 신호가 없다. 화면 안정성 휴리스틱 대신 에이전트 훅으로 풀었다. Warp·Ghostty 같은 에뮬레이터는 밖에서 창을 조종할 CLI가 없어 백엔드가 아니고, 그 안에서 tmux 백엔드를 돌린다.

- `ticket-loop.sh`: `tmux_*` 아홉 함수. 워크트리는 cmux와 같이 `git worktree add` + `WORKTREE_SETUP_CMD`(둘이 쓰던 코드를 `loop_worktree_add`로 합쳤다). 터미널은 `TMUX_SESSION`(기본 `ticket-loop`, tmux 안에서 돌리면 그 세션)의 새 창 — 셸을 띄우고 기동 명령을 친다(Orca처럼, 에이전트가 죽어도 셸이 남아 재기동을 받는다). 시작 점검 때 `~/.cache/ticket-loop/<owner-repo>/tmux/`에 `hook.sh`와 Claude Code 훅 설정 `claude-hooks.json`을 쓰고 기동 명령에 `--settings <그 파일>`(claude) 또는 `-c notify=[…]`(codex)를 붙인다. 훅은 `UserPromptSubmit`→running, `Stop`→idle, `Notification`(permission_prompt·elicitation_dialog)→needsInput, `SessionEnd`→exited를 `state/<워크트리 이름>`에 쓰고 루프가 5초마다 읽는다 — cmux의 lifecycle과 같은 네 값. 프롬프트 수락도 같은 파일로 안다(보내기 전 sent, 15초 안에 running). 상태 표시는 창 이름 뒤 `[working]`·`[review]`·`[done]`·`[needs-attention]`. `AGENT=claude|codex`만 받는다(idle을 훅으로 알기 때문)
- 실측: 함수 아홉 개를 실제 tmux 3.8에서 가짜 에이전트로 한 바퀴(생성·배너·send→running→idle·타임아웃·상태·Ctrl-C·셸 생존·삭제·끊김 3). 실제 Claude Code로 `--settings`의 훅이 적용되는 것, 초기 프롬프트 인자에서 `UserPromptSubmit`, 응답 끝에 `Stop`, `send-keys` + 0.3초 뒤 `Enter`로 보낸 프롬프트가 수락돼 running→idle, `/exit`에 `SessionEnd`가 오는 것을 봤다. `-p` 모드에서도 훅이 돈다. 새(신뢰 전) 디렉터리에서는 폴더 신뢰 대화상자가 먼저 떠 훅이 돌지 않는다 — 저장소의 워크트리에서는 Orca·cmux 실측에서 뜨지 않았다
- `bin/ticket-loop-kit.js`: 백엔드 선택지 `tmux`. `loop.env`의 `WORKTREE_SETUP_CMD` 안내는 Orca가 아닌 백엔드 모두에
- README(영·한)·`setup-ticket-loop`: 제약 표에 tmux 행(실제 티켓 전), 백엔드 표에 tmux 열, 옵션·다른 컴퓨터·미확인 목록
- `tests/smoke.sh`: 백엔드 함수 집합에 tmux, 공통부의 `$TMUX_CLI` 직접 호출 금지, 가짜 tmux로 아홉 함수와 훅 스크립트(Claude Code stdin·Codex 인자·무관한 Notification·깨진 입력)·기동 명령 주입(claude `--settings`, codex `-c notify`)·모르는 에이전트 거절
- 더미 저장소(iwishash/ticket-loop-dummy, 셸 스크립트·bash 테스트 러너·최소 CI) 실측에서 나온 것: Claude Code는 새 워크트리의 폴더 신뢰를 **메인 체크아웃 경로**로 판정한다. 메인 체크아웃이 `~/.claude.json`의 projects에 없던 더미 저장소에서는 워커가 신뢰 대화상자에 멈췄고(훅도 프롬프트도 돌지 않는다), 수락하자 메인 체크아웃 경로가 trust=true로 기록됐다. boiler-webapp cmux 실측에서 안 뜬 이유는 메인 체크아웃을 이미 신뢰했기 때문. 그래서 cmux·tmux의 시작 점검이 `claude_trust_check`로 `~/.claude.json`(`CLAUDE_CONFIG_DIR` 존중)의 `projects[<메인 체크아웃>].hasTrustDialogAccepted`를 보고 아니면 안내와 함께 멈춘다(AGENT=claude일 때만, 파일이 없으면 통과). Orca는 워크스페이스마다 신뢰를 기록해 주므로 보지 않는다
- `install.sh`: Next steps 2단계가 백엔드와 무관하게 Orca 설정이었다 → `--no-orca`(npx 껍질이 Orca 아닌 백엔드에서 넘긴다)면 메인 체크아웃 신뢰와 cmux·tmux 실행 안내로
- tmux 백엔드로 실제 티켓 1건(iwishash/ticket-loop-dummy #1 → PR #2, 2026-10-13, tmux 3.8, Claude Code/Fable 5.1): 아무 터미널에서 `bash scripts/ticket-loop.sh --max 1`이 `git worktree add` → `ticket-loop` 세션에 창 → 셸에 기동 명령 → 훅 상태로 idle 판정 → TDD·ticket-review → PR → CI → 병합 → `kill-window`·워크트리·브랜치 정리 → 기록까지 벽시계 4분, 수리 0회로 끝났다. 신뢰 대화상자(위)는 손으로 수락했다 — 이제는 시작 점검이 막는다. 본 것 둘: `Stop`은 메인 에이전트의 턴이 끝날 때마다 와서 ticket-review의 백그라운드 서브에이전트를 기다리는 동안 한 번 idle로 보였고("워커 idle, PR 없음 (1/3)"), 서브에이전트가 돌아오자 Claude Code가 스스로 턴을 열어 running이 됐다 — 공통부의 연속 횟수 규칙이 설계대로 막았다. 창을 닫을 때 SessionEnd 훅이 뒤늦게 상태 파일을 다시 써 파일이 남는다 — 다음 티켓이 running으로 덮으니 무해하고, 삭제 순서만 뒤로 옮겼다. 남은 것: 수리 경로(충돌·CI 실패)는 이 1건에서 지나가지 않았다 Codex의 `notify`(`-c notify=[…]`가 TOML 배열로 읽히는지, 페이로드에 `cwd`가 있는지)는 0.7의 Codex 실측과 함께

## 0.7.1 — 2026-10-13

0.7.0을 실제 0.3.0 설치본(boiler-webapp, mattpocock 스킬 26개를 `.claude/skills/`에 직접 들인 상태)에 `npx github:iwishash/ticket-loop-kit#v0.7.0 init --yes`로 올려 본 결과. 마이그레이션 본체는 그대로 통과했다 — `.agent-loop/` → `.ticket-loop/`(로그·기록 포함, `git mv`), 키트 스킬 3개 + 벤더링 25개가 `.claude/skills/`에서 `.agents/skills/`로 `git mv`되고 링크 28개가 남았으며, kept 16개(upstream에서 사라진 `git-guardrails-claude-code` 포함)는 유지·동기화, `setup-matt-pocock-skills`와 `setup-agent-loop`는 제거, 매니페스트는 새 자리로, `.codex/rules`·`openai.yaml` 추가, `loop.env`에 `AGENT` 줄, `--dry-run` 정상. 눈에 띈 것 셋을 고쳤다.

- `install.sh`: `.gitignore`의 옛 `/.agent-loop/` 줄을 지울 때 그 위에 0.3 설치기가 썼던 주석 두 줄이 고아로 남고, 4단계가 같은 주석을 새 줄과 함께 또 써서 주석이 두 벌이 됐다. 옛 줄과 함께 키트 주석(정확히 같은 문자열만)도 지운다. 사용자가 쓴 다른 줄은 그대로
- `install.sh`: 4단계가 새 줄을 붙일 때 늘 빈 줄을 하나 앞세워, 이미 빈 줄로 끝나는 `.gitignore`에는 빈 줄이 둘 생겼다. 끝이 빈 줄이면 띄우지 않고, 개행 없이 끝나면 둘을 넣는다
- `install.sh`: 옛 `setup-agent-loop`·`setup-orca-loop` 스킬을 `rm -rf`로 지워 삭제가 스테이징되지 않은 채 남았다(다른 이동은 `git mv`로 스테이징된다). 추적 중이면 `git rm`
- README(영·한)와 `sync-mattpocock-skills.sh` 머리 주석: 매니페스트 자리가 아직 `.claude/skills/.mattpocock.json`으로, `## Agent skills` 블록 자리가 `CLAUDE.md`로 적혀 있었다 → `.agents/skills/.mattpocock.json`, `AGENTS.md`
- `tests/smoke.sh`: 0.3 마이그레이션 픽스처에 키트 주석과 사용자 줄을 넣고, 마이그레이션 뒤 주석이 한 번만 남는지·사용자 줄이 남는지·옛 스킬 삭제가 스테이징되는지 본다
- 설계대로 두고 손으로 고친 것: 설치기가 경고한 "옛 경로를 아직 가리키는 파일" 4개(`docs/agents/ticket-loop.md`, `docs/loop-reports/README.md`, `loop.env` 머리 주석, `implement/SKILL.md` 머리 주석)와 `## Agent skills` 블록의 `AGENTS.md` 이동은 설치 PR에서 직접 했다(`/setup-ticket-loop` 재실행은 이번에 돌리지 않았다)

## 0.7.0 — 2026-10-13

Codex CLI를 워커로 쓸 수 있는 조각을 갖췄다. 질문은 "이 kit을 claude만이 아닌 codex에서도 사용할 수 있게 변경할 수 있어?"였다. 루프 본체(티켓 선택·PR·CI·수리·병합·기록·리포트)는 에이전트와 무관하고, Claude에 묶인 곳은 기동 명령·배너·모델 정규식·`/implement` 접두사·프롬프트의 도구 이름·저장소 배치(`.claude/skills/`)였다. 세 단계 중 1단계(스크립트 프리셋)와 2단계(저장소 배치)를 이 릴리스에 담았다. 3단계(codex 설치 컴퓨터에서 실측)는 코드 변경이 없는 검증이라 뒤에 한다 — 저장소가 아직 비공개여서 내부에서 검증할 여유가 있다(사용자 결정). 그때까지 README·가이드는 Codex를 "지원"이 아니라 "아직 확인하지 않은 것"으로 둔다.

**1단계 — 스크립트 프리셋.**

- `ticket-loop.sh`: `AGENT`가 `claude` | `codex` 프리셋이 되어 `AGENT_RESTART_CMD`(`claude --dangerously-skip-permissions` / `codex --dangerously-bypass-approvals-and-sandbox` — 더 좁은 `--sandbox workspace-write`는 네트워크를 막아 push·`gh pr create`가 안 된다), `AGENT_BANNER_REGEX`(`OpenAI Codex|gpt-[0-9]`), `MODEL_REGEX`(`gpt-5.1-codex` 꼴), 새 변수 `SKILL_PREFIX`(`/` / `$` → `/implement N` / `$implement N`)의 기본값을 정한다. `loop.env`나 환경변수로 준 값이 이긴다. 다른 `AGENT` 값은 프리셋이 없어 두 값이 비어 있으면 시작 때 멈춘다. 워커 프롬프트에서 Claude Code 도구 이름(`AskUserQuestion`)을 빼고 "사람에게 묻거나 확인을 구하지 말고(질문 도구도 쓰지 말고)"로 바꿨다. Orca 워크트리 코멘트와 회고 안내(`/retro`)도 접두사를 따른다. `MODEL_REGEX`가 비면 모델을 뽑지 않는다
- `bin/ticket-loop-kit.js`: 새로 만드는 `loop.env`에 `# AGENT="${AGENT:-claude}"` 안내 주석을 넣는다(값은 바꾸지 않는다)
- 가이드북 3장 표(`AGENT`·`AGENT_RESTART_CMD`·`AGENT_BANNER_REGEX`·`SKILL_PREFIX`·`MODEL_REGEX`), 12장 FAQ "Codex 같은 다른 에이전트", 부록 D·E. README(영·한) "아직 확인하지 않은 것"에 Codex 항목
- `tests/smoke.sh`: 프리셋 블록을 떼어 세 경우(claude·codex·모르는 값)와 `loop.env` 값 우선, 배너 정규식이 기동 화면에는 맞고 셸에 찍힌 기동 명령에는 안 맞는지, 모델 정규식, 워커 프롬프트가 접두사로 시작하고 규칙 파일 유무를 따르는지, 워커·수리 프롬프트에 특정 에이전트의 이름·도구가 없는지를 본다

**2단계 — 저장소 배치.** Codex는 `.claude/skills/`·`CLAUDE.md`·`.claude/settings.json`을 읽지 않고 `.agents/skills/`·`AGENTS.md`·`.codex/rules/`를 읽는다. 사본을 둘로 늘리지 않고 한 사본을 두 경로에서 보이게 한다.

- 스킬 정본은 `.agents/skills/<이름>`, `.claude/skills/<이름>`은 `../../.agents/skills/<이름>` 심볼릭 링크(`npx skills add`와 같은 배치. Codex 문서: 링크된 스킬 폴더를 따라간다). 키트 파일이 `files/.agents/skills/setup-ticket-loop/`, `templates/.agents/skills/implement/`·`pr/`로 옮겨졌고 셋 다 Codex 메타데이터 `agents/openai.yaml`을 갖는다(`setup-ticket-loop`·`implement`는 `policy.allow_implicit_invocation: false` — Claude의 `disable-model-invocation: true`에 해당)
- `install.sh`: 0.6 이하 설치본의 `.claude/skills/{setup-ticket-loop,implement,pr}` 실제 디렉터리를 `.agents/skills/`로 옮기고(추적 중이면 `git mv`) 링크를 남긴다. 관리 스킬은 옮긴 뒤 새 내용으로 덮이고 프로젝트 소유 `implement`·`pr`은 내용을 유지한다. `--agent <claude|codex>`(검사 범위·다음 단계 안내). 템플릿 `.codex/rules/ticket-loop.rules`를 없을 때만 놓고 `__BASE__`에 기본 브랜치를 채운다 — `.claude/settings.json` `deny`와 같은 세 금지(`gh pr merge`, 강제 push, 기본 브랜치 직접 push). 문법은 Codex 문서의 `prefix_rule` 예시를 따랐고 `match`/`not_match` 예시를 넣어 Codex가 로드할 때 스스로 검증하게 했다 — 이 컴퓨터에는 codex 바이너리가 없어(cmux shim만 있다) `codex execpolicy check`는 돌려 보지 못했다
- `sync-mattpocock-skills.sh`: `DEST`가 `.agents/skills/`, 매니페스트는 `.agents/skills/.mattpocock.json`(옛 자리의 것은 읽고 옮긴다). 동기화 전에 이번에 관리할 이름(묶음 + kept)의 옛 자리 디렉터리를 `git mv`로 옮기고 링크를 둔다 — 덮어쓸 것도 먼저 옮겨 git이 이동+수정으로 보게. 제거는 정본·링크·옛 자리 모두. `--agent`: 플러그인·`~/.claude/skills` 검사는 `claude`일 때만, `codex`면 `~/.agents/skills/<이름>`의 같은 이름을 알림(Codex는 합치지 않고 둘 다 선택기에 보인다). 링크 판정이 바뀌었다: `.claude/skills/<이름>` → `../../.agents/skills/<이름>`은 키트 자신의 배치라 정상, 다른 곳을 가리키는 링크와 `.agents/skills/<이름>` 자체가 링크인 경우만 `skills-cli` 차단
- `bin/ticket-loop-kit.js`: `--agent`(대화형이면 질문), `loop.env`에 `AGENT` 줄(`BACKEND`와 같은 규칙 — 없을 때만 덧붙이고 다른 값은 유지·경고). 플러그인 끄기 항목과 `claude plugin disable`은 `claude`일 때만. 매니페스트는 새 자리 → 옛 자리 순으로 읽는다
- `setup-ticket-loop`: `## Agent skills` 블록을 `AGENTS.md`에 쓰고(`CLAUDE.md`에 있으면 옮긴다) `CLAUDE.md`에 `@AGENTS.md` 한 줄을 둔다. 결정 표에 `AGENT` 행, 경로는 `.agents/skills/`, 검증에 링크 확인과 `.codex` 자리표 검사, Codex면 `.codex/` 신뢰 안내
- `implement` 템플릿: "Call the Skill tool with X" → "Use the `X` skill"로 바꾸고 머리에 두 에이전트에서의 뜻을 한 줄로 적었다. `worker-rules.md`·`issue-tracker.md`의 경로 문구. `ticket-loop.sh`의 회고 안내는 `.agents/skills/retro`도 본다
- `tests/smoke.sh`: 첫 설치의 정본·링크·`openai.yaml`·`.codex/rules`(기본 브랜치 채움) 확인, 재설치가 `.codex/rules` 편집을 유지, 0.6 배치의 설치기 마이그레이션(git mv·내용 유지), 동기화의 0.6 배치 마이그레이션(옛 매니페스트로 `--check`가 kept를 읽되 바꾸지 않음, 동기화가 `git mv`·링크·새 매니페스트), kept 스킬의 옛 자리 이동, `--prune`이 정본·링크 모두 제거, `--check`가 키트 링크는 통과시키고 다른 곳 링크는 차단, `--agent codex`의 검사 범위, npx `--agent codex`의 `loop.env`·안내
- 아직 아닌 것(3단계): Codex 설치 컴퓨터에서 Orca·cmux 각 1건 실측 — idle 판정, `$implement`가 스킬을 집는지, 수리 재전송, `.codex/rules/ticket-loop.rules`가 로드되는지(`codex execpolicy check --rules .codex/rules/ticket-loop.rules -- gh pr merge 12`)와 `--dangerously-bypass-approvals-and-sandbox` 아래에서도 유지되는지. 그전에는 "지원"이라 쓰지 않는다
- 이미 설치된 저장소: 설치 명령을 다시 실행하면 `.claude/skills/` 아래 실제 디렉터리(키트 스킬 셋은 설치기가, 벤더링 묶음·kept는 동기화 스크립트가)가 `.agents/skills/`로 `git mv`되고 링크가 남는다. 프로젝트 소유 `implement`·`pr`은 내용이 그대로고 `agents/openai.yaml`만 더해진다. `.codex/rules/ticket-loop.rules`가 새로 놓인다. `AGENTS.md`로 `## Agent skills` 블록을 옮기고 `CLAUDE.md`에 `@AGENTS.md`를 두는 것은 `/setup-ticket-loop`를 다시 돌리거나 손으로 한다(Claude Code만 쓰면 옮기지 않아도 돈다). `loop.env`의 `AGENT` 줄은 npx 설치기가 없을 때만 덧붙인다(기본 claude). 바뀐 것은 `git status`로 보고 PR에 넣는다

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
