---
name: loop-triage
description: "티켓 무인 루프(ticket-loop.sh)가 멈춘 지점을 수습한다 — 멈춤 기록을 읽고 원인을 가려, 고칠 수 있으면 고쳐 루프가 이어 가게 하고, 아니면 사람이 바로 이어받을 진단을 남긴다."
disable-model-invocation: true
---

<!-- ticket-loop-kit 관리 파일: install.sh가 덮어쓴다. 고칠 때는 키트 저장소에서 고친다. .agents/skills/ 에 있고 .claude/skills/loop-triage 는 링크다 — Claude Code(/loop-triage)와 Codex($loop-triage) 둘 다 부른다. -->

루프는 멈출 때 **멈춤 기록**(`.ticket-loop/stops/<id>.json`)을 남긴다. 이 스킬은 그 기록에서 시작해 원인을 가리고, 고칠 수 있으면 고치고, 마지막에 **판정 파일**을 쓴다. 결과물은 판정 하나와 (있으면) 수정 PR 하나다.

## 0. 모드

- **무인**: 프롬프트가 "무인 루프(ticket-loop.sh)가 멈춘 지점에서 띄운 수습 세션"이라고 말하면 루프가 띄운 세션이다. 루프는 잠금을 쥔 채 판정 파일을 기다린다. 사람에게 묻지 않고, PR을 병합하지 않으며(루프가 CI 뒤에 병합한다), 끝에 판정 파일을 반드시 쓴다. 이 세션의 워크트리는 `origin/<기본 브랜치>`에서 만든 `loop-triage-…` 브랜치다 — 새 브랜치를 만들지 말고 이 브랜치에서 일한다.
- **사람**: 사람이 직접 불렀다. 루프는 이미 끝났다. 같은 절차로 진단하고 고치되, 병합과 루프 재실행은 사람에게 확인받는다(8절). 판정 파일은 기록으로 쓴다.

## 1. 멈춤 기록 찾기

- 인자가 파일 경로면 그것, `<id>`(예 `20261016-154317-108`)면 `.ticket-loop/stops/<id>.json`, 숫자 N이면 `ls -t .ticket-loop/stops/*-N.json`의 첫 줄, 없으면 `.ticket-loop/stops/`에서 가장 최근 것. `*.verdict.json`은 기록이 아니다.
- 사람 모드에서 이 세션이 다른 워크트리에 있으면 기록은 메인 체크아웃(`git worktree list`의 첫 줄)의 `.ticket-loop/stops/`에 있다.
- 같은 id의 `.verdict.json`이 있으면 무인 수습이 이미 돌았다. 먼저 읽고 그 판정·요약·`kit_bug_report`에서 이어 간다.

기록의 필드:

| 필드 | 뜻 |
|---|---|
| `kind` | `post_merge_failed` · `ci_failed` · `setup_failed` · `worker_no_pr`(무인 수습 대상), `merge_failed` · `signal` · `unexpected_exit` · `other`(사람 모드에서만) |
| `reason` | 루프가 멈추며 쓴 문구 그대로 |
| `issue`, `title`, `spec`, `pr` | 처리 중이던 티켓, 그 티켓의 PR(있으면) |
| `base_branch`, `repo` | 기본 브랜치, `owner/repo` |
| `main_checkout` | 루프를 돌린 메인 체크아웃. 고치지 않는다 |
| `worker_worktree` | 남아 있는 워커 워크트리(있으면) |
| `logs.loop`, `logs.loop_from_byte` | 루프 로그와 이 실행이 쓰기 시작한 바이트. 이 실행 부분은 `tail -c +$((loop_from_byte + 1)) <loop>` |
| `logs.post_merge`, `logs.post_merge_retry`, `post_merge_worktree` | 병합 뒤 검증 로그(첫 실행·재실행)와 검증 워크트리 |
| `post_merge_window` | 아직 병합 뒤 검증을 통과하지 않은 병합(`POST_MERGE_EVERY`로 묶었을 때). `base`(마지막으로 통과한 커밋), `pending`(병합 순서의 `issue`·`pr`·`commit`), `bisect`(처음 실패하는 병합을 찾은 결과 문장), `first_failing_commit`. 묶지 않았거나 창이 비었으면 null |
| `commands.*` | 이 저장소의 `POST_MERGE_CMD`, `POST_MERGE_RETRY_CMD`, `WORKTREE_SETUP_CMD` |
| `rerun` | 루프를 같은 인자로 다시 실행하는 명령 |
| `verdict_file` | 판정 파일을 쓸 곳 |
| `kit.version`, `kit.repo` | 설치된 키트 버전·저장소 |

## 2. 읽을 것

- 루프 로그의 이 실행 부분. `[시각]`으로 시작하는 줄이 루프의 줄이고, 들여 쓴 줄은 워커 화면·검증 로그의 꼬리다.
- `gh issue view <issue> --comments`, 원인 PR이 있으면 `gh pr view <pr>`와 `gh pr diff <pr>`.
- 이 저장소의 규칙: `.ticket-loop/worker-rules.md`(검증 명령, 무거운 테스트 파일 하나를 돌리는 명령, 금지 사항), `docs/agents/ticket-loop.md`, `.ticket-loop/loop.env`, `AGENTS.md`·`CLAUDE.md`.
- 키트 관리 파일 목록: `.ticket-loop/kit.json`의 `managed`.
- 검증 로그에는 ANSI 색 코드가 섞여 있다. `perl -pe 's/\e\[[0-9;]*m//g'`로 지우고 읽는다(macOS `sed`는 `\x1b`를 모른다).

## 3. 분류

근거를 모은 뒤 하나로 정한다. 원인을 하나로 좁히지 못하면 `needs-human`이다.

| 분류 | 뜻 | 판정 |
|---|---|---|
| `project` | 이 저장소의 코드·테스트·스크립트·설정 문제. 저장소 커밋으로 고칠 수 있다 | 고치고 `resume` |
| `flake` | 같은 코드를 다시 돌리면 통과한다 | 코드 변경 없이 `resume` |
| `environment` | 이 머신이나 외부 서비스의 문제(네트워크, 패키지 레지스트리, 포트, 디스크, 인증, 커밋되지 않는 env 파일) | 지금 해소돼 재현이 통과하면 `resume`, 사람이 손대야 하면 `halt` |
| `loop-bug` | `ticket-loop.sh` 같은 키트 관리 파일의 잘못 | 6절의 키트 버그 보고서를 쓰고 `halt` |
| `needs-human` | 제품 판단, 비밀 값, 운영 인프라, 변경 의도가 불분명 | `halt` |

## 4. 종류별로 할 일

### `post_merge_failed` — 병합 뒤 검증 실패

기본 브랜치가 깨진 상태다. 루프는 다음 티켓을 쌓지 않고 기다린다.

1. 실패를 찾는다. 재실행 로그(`logs.post_merge_retry`)가 있으면 그것이 마지막 상태다. 실패한 테스트 파일과 단정, 또는 테스트가 돌기 전에 실패한 단계(설치·환경 점검)를 적어 둔다.
2. 원인 PR(`pr`)의 diff와 대조한다. `post_merge_window`가 있으면 원인 후보는 `pending`의 PR 전부다. `first_failing_commit`이 있으면 루프가 실패한 테스트만 다시 돌려 찾은 첫 실패 커밋이니 그 PR부터 본다 — 의존성이 바뀐 병합이 끼면 틀릴 수 있어 diff로 확인한다. `bisect`가 "not found"면(창의 시작에서도 실패) 플레이크나 환경을 먼저 의심한다. 수정 PR의 `Refs`에는 원인 티켓의 이슈를 적는다.
   - 원인 PR이 동작을 일부러 바꿨고(이슈의 인수 조건이나 PR 본문이 근거) 테스트가 옛 동작을 기대하면 → 테스트 기대값을 새 동작에 맞춘다.
   - 원인 PR의 코드가 인수 조건과도 어긋나면 → 코드를 고친다.
   - 원인 PR과 무관한 실패(다른 영역, 시간 초과)면 → 그 테스트 파일만 두세 번 다시 돌린다. 매번 통과하면 `flake`.
   - 테스트가 돌기 전 단계에서 실패했으면 → 저장소 스크립트 문제면 `project`, 아니면 `environment`.
3. 고친 뒤 실패했던 테스트 파일만 이 저장소의 방식(`worker-rules.md`의 무거운 테스트 파일 명령)으로 돌려 통과를 확인한다. 전체 스위트는 루프가 병합 뒤 다시 돌린다. 검증 워크트리(`post_merge_worktree`)는 루프의 것이라 쓰지 않는다 — 이 세션의 워크트리에서 돌린다.
4. 수정 PR: 이 브랜치에 커밋하고 push한 뒤 `gh pr create --base <기본 브랜치>`. 제목은 `fix: <요약> — #<issue> 병합 뒤 검증`(닫기 키워드 바로 뒤에 `#<issue>`를 두지 않는다 — 5절). 본문에 멈춘 이유, 원인(원인 PR의 어떤 변경 때문인지), 고친 것, 돌린 검증과 결과를 적고 `Refs #<issue>`를 단다(그 이슈는 이미 닫혔다 — `Closes`를 쓰지 않는다). 라벨은 루프가 붙인다.
5. 판정: `resume`과 `fix_pr`. `flake`면 수정 없이 `resume`(`fix_pr`은 null) — 루프가 검증을 다시 돌린다.

### `ci_failed` — 수리를 다 쓴 CI 실패·충돌

워커가 수리 기회를 다 썼다. 루프는 이 PR의 CI 확인부터 이어 간다.

1. 원인: `gh pr checks <pr>`, 실패한 run의 `gh run view <run-id> --log-failed`. 충돌이면 `gh pr view <pr> --json mergeable,headRefName`.
2. 티켓 PR의 브랜치에서 고친다. 별도 PR을 내지 않는다.
   ```bash
   head=$(gh pr view <pr> --json headRefName -q .headRefName)
   git fetch origin "$head" && git reset --hard "origin/$head"   # 이 세션의 브랜치를 그 PR 끝으로
   # 고치고, worker-rules.md의 검증을 돌린 뒤
   git push origin "HEAD:$head"
   ```
   충돌이면 `git merge origin/<기본 브랜치>`로 풀고 같은 방식으로 push한다. 강제 push는 하지 않는다.
3. CI 인프라의 일시 장애(러너 오류, 네트워크, 같은 커밋의 다른 job은 통과)면 `gh run rerun <run-id> --failed`만 하고 코드 변경 없이 `resume`.
4. 임계값(번들 크기 천장, 커버리지 하한 같은 것)에 걸렸으면 티켓의 변경으로 정당하게 늘어난 것인지 본다(인수 조건에 있는 새 기능·의존성). 정당하면 임계값을 올리는 변경을 같은 PR에 넣고 `gh pr comment <pr>`로 근거(얼마나·왜)를 남긴다. 아니면 크기를 줄이는 쪽으로 고친다. 판단이 서지 않으면 `halt`.
5. 판정: push했으면 `resume`과 `"pushed_to_pr": true`.

### `setup_failed` — 워크트리 준비(`WORKTREE_SETUP_CMD`) 실패

1. 루프 로그에서 `worktree setup —` 줄 뒤의 출력을 읽는다. 이 세션의 워크트리에서 `LOOP_ROOT_PATH=<main_checkout> LOOP_WORKTREE_PATH=<이 워크트리> bash -c "<commands.worktree_setup>"`으로 재현한다(이 세션의 워크트리도 같은 준비가 실패했을 수 있다).
2. 저장소의 준비 스크립트·lockfile 문제면 고쳐 수정 PR을 내고 `resume`과 `fix_pr`. 제목은 `fix: <요약> — #<issue> 워크트리 준비`, 본문에 멈춘 이유·원인·고친 것·재현과 검증을 적고 `Refs #<issue>`를 단다. 이 티켓은 아직 구현 전이다 — 제목·커밋 메시지·본문 어디에도 닫기 키워드 바로 뒤에 `#<issue>`를 두지 않는다(5절). 루프는 병합한 뒤 워커 워크트리를 기본 브랜치로 당기고, 메인 체크아웃이 기본 브랜치에 있으면 fast-forward한 뒤 준비를 다시 돌린다.
3. 일시 장애(레지스트리·네트워크)였고 지금 재현이 통과하면 `environment`, 코드 변경 없이 `resume`.
4. 메인 체크아웃의 커밋되지 않는 파일(env 파일 등)이 없거나 틀려서면 고치지 않는다. `halt`하고 무엇을 해야 하는지 적는다.

### `worker_no_pr` — 워커가 PR 없이 멈춤 (진단만)

1. 이슈 코멘트(워커는 막히면 이유를 코멘트로 남긴다), 루프 로그의 워커 화면 꼬리, 워커 워크트리(`worker_worktree`)의 `git status`, `git log origin/<기본 브랜치>..`, `git diff`.
2. 무엇에 막혔는지 한두 문장으로 요약한다. 워커의 질문에 답하거나 대신 구현하지 않고, 워커 워크트리를 고치지 않는다.
3. 판정은 언제나 `halt`. 환경 문제로 보이면 분류를 `environment`로 하고 무엇을 고쳐야 하는지 적는다.

### 그 밖 (사람 모드에서만 만난다)

- `signal`: 사람이 멈췄거나(Ctrl-C, 창 닫기, kill) 시스템이 끝냈다. 진단할 것이 없으면 그렇게 말하고 8절로 간다.
- `merge_failed`: CI는 통과했는데 병합이 거절됐다. 루프는 GitHub 일시 장애(5xx·네트워크)면 이미 몇 번 다시 해 봤고, 사유의 괄호 안에 마지막 `gh` 오류의 첫 줄이 있다. `gh pr view <pr> --json state,mergeable,mergeStateStatus,reviewDecision`으로 가른다. `MERGED`면 그 사이 병합된 것이고, `CLEAN`이면 일시 장애가 지나간 것이다(`environment`). `BLOCKED`(필수 리뷰·필수 검사 같은 브랜치 보호)는 사람이 승인하거나 규칙을 바꿀 자리이고, `BEHIND`(최신 브랜치 요구)·`DIRTY`(충돌)는 PR 브랜치를 기본 브랜치에 맞춰야 한다. 그다음은 8절이다.
- `unexpected_exit`: `set -e`에 걸린 명령이 사유에 있다. 네트워크·GitHub 일시 장애면 `environment`, 루프 로직이면 `loop-bug`.
- `other`: 사유 문구를 루프 로그와 맞춰 읽는다.

## 5. 하지 않는 것

- 메인 체크아웃(`main_checkout`)을 고치지 않는다. 사람의 미커밋 변경이 있을 수 있다. 일은 이 세션의 워크트리에서 한다.
- 키트 관리 파일(`kit.json`의 `managed`, 예 `scripts/ticket-loop.sh`)을 고치지 않는다. 다음 설치 때 덮이고, 무인 모드에서는 루프가 지금 그 파일을 실행하고 있다. 루프 버그는 6절로.
- 근거 없이 테스트를 약하게 만들지 않는다. 테스트를 지우거나 건너뛰거나(`skip`, `only`), 단정을 느슨하게 하거나, 시간 제한만 늘려 통과시키지 않는다. 기대값을 바꾸면 PR 본문에 원인 PR의 어떤 변경이 의도한 동작인지 인용한다.
- PR을 병합하지 않는다. 기본 브랜치에 직접 push하지 않는다. 강제 push하지 않는다.
- 수정 PR의 제목·본문과 커밋 메시지에서 닫기 키워드(close·closes·closed·fix·fixes·fixed·resolve·resolves·resolved) 바로 뒤에 `#<issue>`를 쓰지 않는다 — `fix: #17 …`처럼 콜론이 끼어도 같다. GitHub는 기본 브랜치에 들어온 커밋 메시지(병합 커밋에는 PR 제목이 들어간다)로 이슈를 닫는다. 준비 실패에서 그 티켓은 아직 구현 전이다(실측: 수정 PR 제목 `fix: #17 워크트리 준비 — …`의 병합 커밋이 #17을 닫았다). 이슈는 `Refs #<issue>`로 가리킨다. 티켓 PR 브랜치에 push하는 CI 실패는 그 PR이 어차피 이슈를 닫으므로 상관없다.
- 운영 환경(운영 DB, 배포)에 연결하지 않는다. 비밀 값을 만들거나 바꾸지 않는다.
- 이 머신의 프로세스를 끄거나 설정을 바꾸지 않는다(포트를 쥔 서버 같은 것). 필요하면 `halt`하고 적는다.
- 키트 저장소(공개일 수 있다)에 이슈를 직접 만들지 않는다. 이 저장소의 로그·코드가 밖으로 나가지 않게 보고서는 로컬에 쓴다(6절).

## 6. 키트 버그 보고서 (`loop-bug`)

멈춤 기록 옆에 `<id>.kit-bug.md`를 쓴다: 키트 버전(`kit.version`), 증상(사유·로그 줄), 재현 조건, 원인으로 보이는 `scripts/ticket-loop.sh`의 줄, 고칠 방향(패치 초안). 이 저장소 고유의 이름·경로·코드는 일반화해 적는다 — 사람이 읽고 키트 저장소(`kit.repo`)에 올린다. 판정은 `halt`, `kit_bug_report`에 그 파일의 절대 경로.

## 7. 판정 파일

`verdict_file`에 맨 마지막에 한 번 쓴다. 루프는 이 파일이 생기면 바로 읽으므로 임시 파일에 쓴 뒤 `mv`한다.

```json
{"verdict": "resume", "category": "project", "summary": "PR #130이 계약 CSV에 동의 열 2개를 더했는데 통합 테스트의 헤더 기대값이 옛 열 목록이었다. 기대값을 맞추고 그 파일만 돌려 통과.", "fix_pr": 131, "pushed_to_pr": false, "kit_bug_report": null}
```

| 필드 | 값 |
|---|---|
| `verdict` | `resume`(루프가 멈춘 자리에서 이어 가도 된다) 또는 `halt`(사람이 봐야 한다) |
| `category` | 3절의 분류 |
| `summary` | 한두 문장: 원인과 한 일. Slack과 이슈 코멘트에 그대로 실린다 — 로컬 경로·비밀 값을 넣지 않는다 |
| `fix_pr` | 기본 브랜치로 낸 수정 PR 번호(`post_merge_failed`, `setup_failed`). 없으면 null |
| `pushed_to_pr` | `ci_failed`에서 티켓 PR 브랜치에 push했으면 true |
| `kit_bug_report` | 6절의 보고서 경로. 없으면 null |

루프가 판정을 받아 하는 일:

- `resume` + `fix_pr`: 수정 PR에 `loop-triage` 라벨을 붙이고 CI 뒤 병합한다. 그다음 `post_merge_failed`면 병합된 기본 브랜치로 검증을 다시 돌리고, `setup_failed`면 워크트리를 당겨 준비를 다시 돌린다. 통과하면 이어 간다. `post_merge_failed`가 아닌데 그 병합이 티켓 이슈를 닫았으면 루프가 다시 연다(5절의 닫기 키워드를 피해도 만일을 위해).
- `resume` + `pushed_to_pr`: 티켓 PR의 CI 확인부터 이어 간다.
- `resume`만(코드 변경 없음): 멈춘 단계를 그대로 다시 한다.
- `halt`: `summary`를 멈춤 사유에 붙여 멈추고 Slack으로 사람을 부른다. 이 세션의 워크트리는 남긴다.
- 루프는 한 실행에 수습을 한 번(`TRIAGE_MAX`)만 띄운다. 이어 간 뒤 같은 곳에서 또 실패하면 그대로 멈춘다. `worker_no_pr`처럼 이어 갈 수 없는 종류는 `resume`을 써도 멈춘다.

## 8. 사람 모드에서 끝내기

- 진단과 (있으면) 수정 PR을 보여 준다.
- 병합할지 묻는다. 이 저장소의 `deny` 규칙이 `gh pr merge`를 막으면 사람이 병합한다.
- 루프를 다시 실행할 명령은 기록의 `rerun`이다. 처리 중이던 티켓의 PR이 열린 채 멈췄으면 자동 선택이 그 티켓을 건너뛴다("PR already open") — PR을 병합하거나, 닫고 `in-review` 라벨과 담당자를 지운 뒤 다시 실행한다. 워커 워크트리가 남아 있으면 같은 이름으로 다시 만들 때 막히므로 `git worktree remove --force <worker_worktree>`로 지운다.
