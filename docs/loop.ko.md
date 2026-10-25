# 루프 돌리기

[README](../README.ko.md) · [English](loop.md)

## 설정과 동작 중 알아둘 것

- `ticket-loop.sh`는 [가이드북](ticket-loop-guide.pdf) 부록 D에 둘을 더한 것이다. `.ticket-loop/loop.env`(`VAR="${VAR:-값}"` 꼴로 커밋한 기본값, 실행할 때 준 환경변수가 이긴다)와 시작 전 포트 점검.
- CI가 경로 필터를 쓰면 GitHub는 걸러진 PR에 체크를 만들지 않아 루프가 "아직 안 떴다"와 "안 뜬다"를 구별할 수 없다. `CI_SKIP_REGEX` 또는 `CI_SKIP_CMD`(파일 목록을 stdin으로 받아 `run`/`skip`을 찍는 스크립트)로 필터를 따라 하고, 필터가 없으면 비워 둔다.
- 병합마다, 그리고 `--parent` 실행이 끝날 때, 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈도 닫는다.
- 산출물: `.ticket-loop/loop-MMDD.log`, `.ticket-loop/tickets.jsonl`(기계별, 커밋하지 않음), `--parent <스펙>` 실행 뒤의 스펙 리포트 `docs/loop-reports/spec-<N>.html`(사람이 보고 PR로 커밋). 스펙이 끝나면 `/retro`를 권하는 한 줄을 남기고, 회고를 직접 돌리지는 않는다.
- `POST_MERGE_PORT`가 있으면 포트가 차 있을 때 점유 프로세스를 적고 30초마다 다시 본다.
- idle strike를 세기 전에 워커 화면(끝 25줄)을 분류한다. `USAGE_LIMIT_REGEX`(claude 프리셋 `reached your .* limit|usage limit`)에 맞으면 바로 `usage_limit`로 멈추고 — 사유에 그 줄과 "resets at / try again at" 문구를 싣고, 수습 세션은 띄우지 않는다(같은 한도에 걸린다. 한도가 풀린 뒤 루프를 다시 돌린다). `PERMISSION_PROMPT_REGEX`(claude 프리셋 `Do you want to proceed\?`)의 줄이 화면 끝에 `PROMPT_STALL_SEC`(300초) 동안 글자 그대로 머물면 백엔드가 idle을 돌려주지 않아도 `worker_no_pr`로 멈춘다. 루프는 확인 창에 답하지 않는다. 둘 다 ERE이고 `loop.env`로 덮어쓸 수 있다. 비우면 그 감지를 끈다(codex 프리셋은 실측 전이라 둘 다 비어 있다).
- `POST_MERGE_RETRY_CMD`(기본 비움 = 재실행 없음)가 있으면 병합 뒤 검증이 실패했을 때 딱 한 번 재실행한다. 포트 대기를 다시 지나, 같은 검증 워크트리에서 `POST_MERGE_FAILED_LOG`(첫 실행 로그의 절대 경로)를 넘겨 돌리고, 출력은 같은 디렉터리의 `post-merge-N-retry.log`다. 통과하면 루프는 계속 가고 `passed on retry in Ns (first run failed in Ms)`로 기록하며, 이슈에 "플레이크 의심" 코멘트(머신·로그 파일 이름·소요 시간 — 로그 본문은 올리지 않는다)를 달고 Slack에 멘션 없이 알린다. 재실행도 실패하면 두 로그를 적고 멈춘다. 키트는 테스트 도구를 모르므로 무엇을 다시 돌릴지는 저장소가 정한다. vitest라면 스크립트를 커밋하고(검증 워크트리는 병합된 기본 브랜치다) `POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh}"`로 건다(바뀐 게 없으면 설치는 몇 초다. 묶음 실패의 원인 병합을 찾으려고 지난 커밋에서 스크립트를 다시 돌릴 때 의존성을 맞춘다 — 아래 `POST_MERGE_EVERY`).

  ```bash
  # scripts/post-merge-retry.sh — 첫 실행 로그에서 실패한 테스트 파일만 다시 돌린다
  files=$(perl -pe 's/\e\[[0-9;]*m//g' "$POST_MERGE_FAILED_LOG" \
    | grep -oE 'FAIL +[^ ]+\.test\.ts' | awk '{print $2}' | sort -u)
  [ -n "$files" ] || { echo "no failed test files found — not retrying"; exit 1; }
  pnpm exec vitest run --config vitest.integration.config.ts $files
  ```

  실패한 파일을 못 찾으면(설치·환경 점검 단계에서 실패) 다시 돌리지 않고 실패로 끝내는 것이 요점이다 — 진짜 깨진 기본 브랜치가 묻히지 않게. 로그에 ANSI 색 코드가 섞여 있고 macOS 기본 `sed`는 `\x1b`를 못 알아들어 `perl`을 쓴다.
- `POST_MERGE_EVERY`(기본 4)는 병합 뒤 검증을 묶는다. 병합 네 개마다 한 번 돌리고, 티켓의 스펙이 끝나거나 이번 실행에 남은 티켓이 없으면 그 전에도 돌린다 — 티켓 세 개짜리 스펙은 세 번째 티켓 뒤에 한 번 돈다. `1`이면 병합마다 돈다(스위트가 몇 분이면 이쪽 — 묶어도 아끼는 시간이 없다). `0`이면 스펙·실행이 끝날 때만 돈다. 기본 브랜치 끝에서 도는 검증은 그 전의 병합을 모두 덮으므로 검증을 거치지 않는 병합은 없다. 잃는 것은 "어느 병합이 깨뜨렸나"다. 묶음 검증이 재실행까지 실패하면 루프가 처음 실패하는 병합을 찾는다. 마지막으로 통과한 커밋에서 `POST_MERGE_RETRY_CMD`(실패한 테스트만)를 돌려 본 뒤, 그 뒤의 병합들을 이분 탐색한다. 결과는 멈춤 사유와 멈춤 기록의 `post_merge_window`에 실려 무인 수습에 넘어간다. `POST_MERGE_RETRY_CMD`가 없으면 이분 탐색을 하지 않는다 — 전체 스위트로 탐색하면 묶어서 아낀 시간을 도로 쓴다. 이분 탐색은 같은 검증 워크트리에서 지난 커밋으로 재실행 명령을 돌리므로, 설치된 의존성에 기대는 재실행 명령이면 먼저 설치하게 한다(예: `pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh`). 아직 검증하지 않은 병합은 `.git/ticket-loop-post-merge.json`에 남아 루프가 멈췄다 다시 실행돼도 묶음이 이어진다. 스펙 리포트는 검증 시간을 그 검증을 돌린 티켓에 넣고, 나머지 티켓에는 "post-merge check deferred"를 적는다. 배경: rental-portal의 통합 테스트는 티켓마다 47~52분(스펙 하나의 12티켓에서 9.8시간)이었고, 워커가 PR 전에 관련 통합 테스트를 돌리기 시작한 뒤 34회 동안 잡은 회귀가 없었다.
- `POST_MERGE_CMD`·`POST_MERGE_RETRY_CMD`는 env 둘을 받는다. 평소에는 가벼운 검증을, 스펙이 끝날 때만 무거운 검증을 돌릴 수 있게 하려는 것이다. `TICKET_LOOP_POST_MERGE_WHY`는 왜 도는지다 — `every`(병합 `POST_MERGE_EVERY`개), `spec_end`(티켓의 스펙 끝), `run_end`(이번 실행의 마지막 티켓·남은 티켓 없음·루프 끝 검증). `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`는 이 검증이 덮는 병합 가운데 스펙(`--parent` 또는 티켓의 부모)을 끝낸 것이 있으면 그 스펙 번호, 없으면 빈 값이다(드물게 여럿이면 공백으로 구분). 이유와 따로 본다 — 루프가 창이 찼는지를 먼저 보므로 `POST_MERGE_EVERY=1`이면 스펙의 마지막 병합 뒤 검증도 `every`다. 스펙을 끝낸 병합은 아직 검증하지 않은 병합과 함께 `.git/ticket-loop-post-merge.json`에 남아, 스펙 끝 검증이 실패해 멈춘 뒤 다시 실행한 루프도 그 스펙 번호를 다시 넘긴다. CI가 붙지 않는 문서 PR은 묶음에 넣지 않지만 스펙을 끝낸 문서 PR은 넣는다 — 그래야 그 스펙도 스펙 끝의 검증을 받는다. 루프 끝에서 처음 닫히는 스펙(사람이 마지막 티켓을 닫은 경우 등)은 스펙을 닫은 뒤 남은 묶음을 검증하므로 그 검증이 스펙 번호를 받는다. 재실행·이분 탐색·수습 뒤 재검증은 첫 실행과 같은 값을 받아 같은 조건(같은 DB 등)으로 돈다. 검증 로그마다 첫 줄에 `# ticket-loop: TICKET_LOOP_POST_MERGE_WHY="…" TICKET_LOOP_POST_MERGE_SPEC_COMPLETE="…"`가 찍히고, 티켓 기록에는 `post_merge_why`·`post_merge_spec_complete`가 남으며, 스펙 리포트는 결과 뒤 괄호에 적는다(예: `post-merge check passed, covering #61 #62 (every, spec #60 complete)`). 예: `POST_MERGE_EVERY=1`로 두고, `POST_MERGE_CMD`가 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`가 비어 있지 않을 때만 공유 DB를 고르게 한다.

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
