#!/usr/bin/env bash
set -euo pipefail

# ticket-loop.sh — GitHub 이슈 티켓을 워크트리에서 한 건씩 무인 처리한다. 워크트리와 에이전트 터미널은 백엔드(Orca, cmux 또는 tmux)가 맡는다.
# 가이드: 「티켓 무인 루프 가이드북」 3판 (ticket-loop-kit docs/). 이 파일은 ticket-loop-kit이 관리한다 — 고치면 키트에서 고친다.
#
# 티켓 하나당:
#   1. 기본 브랜치에서 워크트리를 새로 만들고 에이전트(Claude Code 또는 Codex)에 `/implement N`(Codex는 `$implement N`)을 보낸다
#      (티켓마다 새 프로세스라 컨텍스트가 비어 있다)
#   2. 워커가 `<BRANCH_PREFIX>N-<slug>`(또는 워크트리 브랜치 `<BRANCH_PREFIX>N` 그대로) 브랜치로 PR을 열 때까지 기다린다
#   3. CI를 기다리고, 충돌·CI 실패는 같은 워커에 REPAIR_ROUNDS회까지 고치게 한다
#   4. PR을 병합한다 → 본문의 `Closes #N`으로 이슈가 닫힌다. 그 티켓이 속한 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈도 닫는다
#   5. (선택) 병합된 기본 브랜치로 POST_MERGE_CMD를 한 번 돌린다 — 워커가 못 돌리는 무거운 검증. 실패하면 멈춘다
#      (POST_MERGE_RETRY_CMD가 있으면 멈추기 전에 한 번 재실행해 본다 — 통과하면 플레이크 의심으로 기록하고 계속 간다).
#      병합 POST_MERGE_EVERY개마다(기본 4), 그리고 스펙이나 실행이 끝날 때 한 번 돌린다 — 그 사이 병합은 다음 검증이 덮는다.
#      1이면 병합마다, 0이면 스펙·실행이 끝날 때만
#   6. 워크트리·브랜치를 지우고, 티켓 요약 한 줄을 로그에, 기록 한 줄을 RECORDS_FILE에 남기고, 다음 티켓으로 간다
#      (자동 선택이면 대상 재계산)
#   7. `--parent` 실행이 정상 종료하면 하위 이슈가 모두 닫힌 스펙 이슈를 닫고(아직 열려 있으면), 스펙 리포트 HTML(티켓별 결과·구현·CI·
#      병합 뒤 검증 시간·경과 시간·모델 표)을 REPORT_DIR/spec-<N>.html에 쓰고 브라우저로 연다(REPORT_OPEN=0이면 열지 않음)
#   8. 이번 실행에서 끝난 스펙이 있으면 회고를 권하는 안내 한 줄을 남긴다(/retro로 읽을 자료 안내). 권고일 뿐 아무것도 실행하지 않는다 —
#      회고는 사람이 후보를 보고 고르는 단계라 무인으로 돌리지 않는다
# 그 사이 멈출 일이 생기면(병합 뒤 검증 실패, 수리를 다 쓴 CI 실패·충돌, 워크트리 준비 실패, PR 없이 멈춘 워커) 멈추기 전에 수습 세션을
# 띄운다(LOOP_TRIAGE, 아래 "무인 수습" 절). 고쳐지면 멈춘 자리에서 이어 가고, 못 고치면 진단을 실어 멈춘다
#
# 사용법:
#   ticket-loop.sh                     # 준비된 티켓 전부
#   ticket-loop.sh --parent 40         # 스펙 이슈 #40의 하위 이슈만
#   ticket-loop.sh --label bug         # 라벨로 좁히기(SCOPE_LABEL과 같다)
#   ticket-loop.sh 12 15               # 지정한 이슈만, 적은 순서대로(라벨은 보지 않는다)
#   ticket-loop.sh --dry-run           # 대상 목록만 출력
#   ticket-loop.sh --max 1             # 최대 1건
#   ticket-loop.sh --no-merge 12       # CI 통과까지만, 병합은 사람이
#   ticket-loop.sh --skip-post-merge   # POST_MERGE_CMD를 이번 실행에서 끈다
#
# 전제: 백엔드 준비(Orca: 앱 실행·CLI 등록 / cmux: cmux 터미널 안에서 실행하거나 소켓 모드를 열어 둠 / tmux: tmux 설치), `gh auth status` 로그인,
# 저장소 안에서 실행.
# 진행 로그는 기본으로 .ticket-loop/loop-MMDD.log에 덧붙인다(.gitignore에 /.ticket-loop/*.log 권장).
# PR을 기다리는 동안은 워크트리를 PROGRESS_SEC마다 들여다봐 브랜치 생성·첫 파일 수정·새 커밋을 바로, 그 사이 변경 파일 목록이 달라졌으면
# HEARTBEAT_SEC마다 "working" 한 줄을 찍는다. 지난번과 같은 내용이면 찍지 않는다.
# 터미널·로그 파일에 찍는 문구는 영어다(워커 프롬프트·GitHub 코멘트·백엔드 상태 코멘트는 그대로).
# 터미널에는 단계별로 색을 입힌다(티켓 제목·단계·성공·주의·오류). stderr가 터미널이 아니거나 NO_COLOR가 있으면 맨글자고,
# 로그 파일에는 언제나 색 코드 없이 쓴다. 실행 맨 앞에는 키트 이름·버전 머리줄을 한 줄 찍는다(.ticket-loop/kit.json — 설치기가 쓴다).
# 티켓마다 "#N summary: …" 한 줄(벽시계·PR과 그 PR을 알아채기까지·CI 소요·수리·idle 오판·병합 뒤 검증)을 남겨 /retro가 읽는다.
# 같은 내용 + 모델을 RECORDS_FILE(JSONL)에도 남기고, 스펙 리포트가 GitHub의 PR과 합쳐 표로 만든다.
# 저장소별 설정은 .ticket-loop/loop.env에 둔다(있으면 읽는다). 그 파일은 `VAR="${VAR:-값}"` 꼴로 써서
# 실행할 때 준 환경변수가 이기게 한다. 예: CI_SKIP_REGEX="${CI_SKIP_REGEX:-^docs/}" POST_MERGE_PORT="${POST_MERGE_PORT:-3000}"
# 기계별 설정과 비밀 값(SLACK_WEBHOOK_URL)은 커밋하지 않는 ~/.config/ticket-loop/loop.env(XDG_CONFIG_HOME을 따른다)에 같은 꼴로 둔다.
# 저장소 loop.env보다 먼저 읽어 그쪽이 이긴다(실행할 때 준 환경변수는 둘 다 이긴다).
#
# 환경변수(선택):
#   BACKEND             orca | cmux | tmux (기본 orca). 워크트리 생성·에이전트 터미널·idle 판정·상태 표시를 누가 하나. 아래 "백엔드" 절
#   ORCA_CLI            Orca CLI 실행 파일 (기본: ORCA_CLI_COMMAND → Linux면 orca-ide → orca)
#   CMUX_CLI            cmux CLI 실행 파일 (기본: PATH의 cmux → /Applications/cmux.app/Contents/Resources/bin/cmux)
#   TMUX_CLI            tmux 실행 파일 (기본 tmux)
#   TMUX_SESSION        tmux 백엔드가 워커 창을 열 세션 (기본: tmux 안에서 돌리면 그 세션, 밖이면 ticket-loop — 없으면 만든다)
#   WORKTREE_DIR        cmux·tmux 백엔드가 워크트리를 둘 디렉터리 (기본 ~/.cache/ticket-loop/<owner-repo>/worktrees). Orca는 자기 자리에 둔다
#   WORKTREE_SETUP_CMD  cmux·tmux 백엔드가 새 워크트리에서 에이전트를 띄우기 전에 돌릴 명령(의존성 설치·env 복사 — Orca의 orca.yaml setup에
#                       해당). LOOP_ROOT_PATH·LOOP_WORKTREE_PATH를 환경변수로 준다. 예 "pnpm install && cp \"$LOOP_ROOT_PATH/.env.local\" ."
#   SPEC_ISSUE          --parent 기본값
#   SCOPE_LABEL         함께 요구할 라벨(--label 기본값)
#   READY_LABEL         대상 라벨 (기본 ready-for-agent)
#   IN_REVIEW_LABEL     PR이 열린 티켓 라벨 (기본 in-review)
#   BRANCH_PREFIX       이슈 브랜치 접두사 (기본 issue-)
#   BASE_BRANCH         기준 브랜치 (기본: 저장소 기본 브랜치)
#   ORDER_REGEX         제목에서 순번을 뽑는 정규식, 이름 있는 그룹 n (기본 ^T(?<n>[0-9]+))
#   WORKER_RULES_FILE   워커가 추가로 따를 규칙 파일 (기본 .ticket-loop/worker-rules.md)
#   AGENT               claude | codex (기본 claude). Orca가 띄울 에이전트 ID이자 기록의 agent 필드. 기동 명령·배너·스킬 접두사·모델 정규식·
#                       화면 분류 정규식 둘의 기본을 정하는 프리셋이다(아래 "에이전트 프리셋" 절). 다른 값이면 기동 명령·배너는 직접 적어야 한다
#   AGENT_RESTART_CMD   에이전트를 셸에서 띄우는 명령. 프롬프트는 인자로 붙는다 (claude: claude --dangerously-skip-permissions,
#                       codex: codex --dangerously-bypass-approvals-and-sandbox). Orca는 뜨지 않았을 때만, cmux·tmux는 처음부터 이 명령으로 띄운다(tmux는 훅 설정 인자를 뒤에 붙인다)
#   AGENT_BANNER_REGEX  에이전트가 떴는지 확인할 화면 문구(ERE) (claude: Claude Code 배너·모델명, codex: "OpenAI Codex"·gpt- 모델명)
#   SKILL_PREFIX        워커 프롬프트에서 스킬을 부르는 접두사 (claude: / → /implement N, codex: $ → $implement N)
#   TICKET_TIMEOUT_SEC  티켓 한 건 제한 시간 (기본 14400 = 4시간)
#   MERGE_METHOD        merge | squash | rebase (기본 merge)
#   REPAIR_ROUNDS       충돌·CI 수리 횟수 합계 (기본 1)
#   CI_SKIP_REGEX       저장소 CI가 경로 필터(paths / paths-ignore)로 일부 PR에서 돌지 않을 때, 그 필터를 루프에 알려 주는 값.
#                       바뀐 파일이 전부 이 정규식(ERE)에 맞으면 체크가 안 붙는 게 정상인 PR로 보고 체크 없이 병합한다.
#                       루프가 정하는 규칙이 아니라 워크플로의 필터를 따라 하는 것이다 — 필터가 없으면 비워 둔다 (기본 없음 = 모든 PR에서 체크를 기다린다)
#   CI_SKIP_CMD         같은 목적의 명령 — 순서 규칙이 있는 paths 목록처럼 정규식 하나로 못 쓰는 필터용. 바뀐 파일 목록을 stdin으로
#                       (한 줄에 하나) 받아 CI가 돌면 "run", 전부 제외 경로면 "skip"을 출력한다. 저장소 루트에서 실행되고, 있으면
#                       CI_SKIP_REGEX보다 먼저 본다. 실패하거나 다른 출력이면 체크를 기다리는 쪽으로 간다
#   POST_MERGE_CMD      병합 뒤 기본 브랜치에서 돌릴 명령, 예 "npm ci && npm run test:e2e" (기본 없음 = 끔). 검증을 상황에 따라 다르게
#                       돌릴 수 있게 env 둘을 받는다(POST_MERGE_RETRY_CMD도 같다): TICKET_LOOP_POST_MERGE_WHY — 왜 도는지, every(병합
#                       POST_MERGE_EVERY개) · spec_end(스펙 끝) · run_end(이번 실행의 마지막 티켓·남은 티켓 없음·루프 끝).
#                       TICKET_LOOP_POST_MERGE_SPEC_COMPLETE — 이 검증이 덮는 병합 가운데 스펙(--parent 또는 티켓의 부모)을 끝낸 것이
#                       있으면 그 스펙 번호(드물게 여럿이면 공백 구분), 없으면 빈 값. 이유와 따로 본다 — POST_MERGE_EVERY=1이면 스펙 끝의
#                       검증도 every다. 병합이 모두 검증을 거친 뒤에 스펙이 닫혀도(사람이 마지막 티켓을 닫음·하위 이슈 반영 지연)
#                       그 번호를 싣고 통과한 검증이 이번 실행에 없었으면 루프 끝에 기본 브랜치로 한 번 돈다 — spec_end와 그 번호.
#                       재실행·이분 탐색·수습 뒤 재검증은 첫 실행과 같은 값이다. 예: 스펙 끝에만 무거운 DB로
#                       [ -n "$TICKET_LOOP_POST_MERGE_SPEC_COMPLETE" ]. 받은 값은 검증 로그 첫 줄과 RECORDS_FILE에 남는다
#   POST_MERGE_RETRY_CMD POST_MERGE_CMD가 실패했을 때 딱 한 번 돌려 볼 재실행 명령 (기본 없음 = 재실행 없이 멈춤). 같은 검증 워크트리에서
#                       POST_MERGE_FAILED_LOG(첫 실행 로그의 절대 경로)를 받아 돈다 — 그 로그에서 실패한 테스트만 골라 다시 돌리는 식이다.
#                       출력은 post-merge-N-retry.log. 통과하면 계속 가고 이슈 코멘트·Slack에 플레이크 의심을 남긴다. 실패한 테스트를
#                       찾지 못하면(설치·환경 단계에서 실패) 다시 돌리지 말고 비0으로 끝내야 한다 — 진짜 깨진 기본 브랜치를 덮지 않게
#   POST_MERGE_EVERY    POST_MERGE_CMD를 병합 몇 개마다 돌리나 (기본 4 — 네 번째 병합 뒤에 앞의 넷을 한 번에 검증한다. 1이면 병합마다,
#                       0이면 개수로는 돌리지 않는다). 그 전이라도 티켓의 스펙이 끝나거나(스펙 이슈를 닫음) 이번 실행의 마지막 티켓이면
#                       돌린다 — 0이면 그때만 돈다. 검증은 그때까지의 병합을 모두
#                       덮으므로 빠지는 병합은 없고, 잃는 것은 "어느 병합이 깨뜨렸나"다 — 묶음이 실패하고 POST_MERGE_RETRY_CMD가 있으면
#                       그 명령으로 마지막 통과 뒤의 병합 커밋을 이분 탐색해 처음 실패하는 병합을 찾아 멈춤 사유·무인 수습에 넘긴다.
#                       아직 검증하지 않은 병합과 그 번호를 받은 검증을 아직 통과하지 못한 스펙 완료는 .git/ticket-loop-post-merge.json에
#                       남아 멈췄다 다시 실행해도 이어진다
#   POST_MERGE_COPY     POST_MERGE_CMD 전에 메인 체크아웃에서 복사할 파일들(공백 구분), 예 ".env.local"
#   POST_MERGE_PORT     POST_MERGE_CMD가 쓰는 포트. 지정하면 비기를 기다린다(기본 없음)
#   POST_MERGE_WORKTREE POST_MERGE_CMD를 돌릴 워크트리 (기본 ~/.cache/ticket-loop/<owner-repo>/post-merge, 저장소 밖)
#   LOG_FILE            진행 로그 파일 (기본 .ticket-loop/loop-MMDD.log, /dev/null이면 끔). 상대 경로는 저장소 루트 기준이고 시작 때
#                       절대 경로로 굳힌다 — 병합 뒤 검증 로그(post-merge-N.log)도 같은 디렉터리에 둔다
#   PROGRESS_SEC        PR·수리를 기다리는 동안 워크트리(git)를 들여다보는 간격 (기본 60초). 브랜치 생성·첫 파일 수정·새 커밋(제목 그대로)을
#                       그때 바로 한 줄씩 찍는다. 0이면 끄고 전처럼 idle 대기 상한(10분)마다만 돌아온다
#   HEARTBEAT_SEC       커밋은 없지만 변경 파일 목록이 지난 줄과 달라졌을 때 "working — Nm elapsed, N uncommitted files …" 한 줄을 찍는 최소 간격
#                       (기본 300초). 목록이 같으면 아무리 지나도 찍지 않는다 — 같은 내용을 되풀이하지 않는다
#   RECORDS_FILE        티켓별 기록 JSONL (기본 .ticket-loop/tickets.jsonl, 기계별 — 커밋하지 않는다). 상대 경로는 저장소 루트 기준
#   REPORT_DIR          스펙 리포트 HTML 디렉터리 (기본 docs/loop-reports — 리포트는 사람이 PR로 커밋). 상대 경로는 저장소 루트 기준
#   REPORT_OPEN         리포트를 쓴 뒤 브라우저로 여는지 (기본 1). 0이면 안 연다. SSH 세션·화면 없는 Linux에서는 값과 무관하게 안 연다
#   REPORT_DECISIONS_HEADING  PR 본문에서 사람이 봐야 할 절의 마크다운 제목(글자 그대로, 예: "사람 확인 필요"). 지정하면 리포트가 각 티켓 PR 본문에서
#                       그 절을 뽑아 머리의 목록(PR 링크 포함)으로 모으고, 절이 있는 행에 표시를 단다. 절이 없거나 빈 PR은 목록에 없다.
#                       기본 비움 = 모으지 않는다(지금까지와 같다). 저장소마다 절 이름이 다르므로 키트는 이름만 받는다(이슈 #25)
#   REPORT_DECISIONS_NONE  그 절에 "내용 없음"으로 적는 말들(글자 그대로 — 정규식이 아니다, "|" 구분, 대소문자 무시) (기본 "없음|none|N/A").
#                       절 본문에서 목록 기호(-·*)와 끝 마침표를 걷은 것이 이 가운데 하나와 같으면("- 없음", "없음.") 빈 절처럼 목록·건수·표시에서
#                       뺀다. 뒤에 내용이 더 붙으면 남는다(이슈 #39)
#   MODEL_REGEX         워커 터미널에서 모델 이름을 뽑는 정규식(ERE) (claude: 상태줄·배너의 "Opus 5.5" 꼴, codex: "gpt-5.1-codex" 꼴).
#                       못 찾으면 리포트에 not recorded
#   USAGE_LIMIT_REGEX   워커 화면 끝 25줄에서 사용량 한도 문구를 찾는 정규식(ERE) (claude: "reached your .* limit|usage limit", codex·그 외: 없음).
#                       idle인 워커의 화면에 맞으면 strike를 세지 않고 usage_limit로 바로 멈춘다 — 무인 수습은 띄우지 않는다(같은 한도에 걸린다).
#                       비우면 감지하지 않는다. 아래 "화면 분류" 절
#   PERMISSION_PROMPT_REGEX  워커 화면 끝에서 권한 확인 창 문구를 찾는 정규식(ERE) (claude: "Do you want to proceed\?", codex·그 외: 없음). 그 줄이 든
#                       화면이 PROMPT_STALL_SEC(300초) 동안 글자 그대로면 idle 신호가 없어도 worker_no_pr로 멈춘다. 루프는 확인 창에 답하지 않는다.
#                       비우면 감지하지 않는다
#   SLACK_WEBHOOK_URL   Slack Incoming Webhook URL (기본 없음 = Slack 끔). 루프 시작·티켓 완료·멈춤·루프 종료를 그 채널에 올린다.
#                       잠금을 잡은 실행만 보낸다(--dry-run, 이미 도는 루프와 겹친 실행은 안 보낸다). 비밀 값이다 — 커밋하는 저장소
#                       loop.env가 아니라 ~/.config/ticket-loop/loop.env나 환경변수에 둔다
#   SLACK_MENTION       멈춤 알림 앞에 붙일 멘션, 예 "<@U012AB3CD>"(자기 멤버 ID) 또는 "<!channel>" (기본 없음). 채널 알림을 "멘션만"으로
#                       두고도 멈출 때만 폰이 울린다. Ctrl-C로 멈춘 것(사람이 앞에 있다)에는 붙이지 않는다
#   STOPPED_LABEL       루프가 멈춘 티켓에 붙이는 라벨 (기본 loop-stopped, 없으면 만든다). 기록용이다 — 대상 선택은 이 라벨을 보지 않고,
#                       루프가 그 티켓을 병합하면 뗀다
#   LOOP_TRIAGE         멈출 일이 생기면 수습 세션을 띄우는지 (기본 1). 0이면 전처럼 바로 멈춘다. 아래 "무인 수습" 절
#   TRIAGE_MAX          한 실행에서 수습 세션을 띄우는 최대 횟수 (기본 1). 다 쓰면 그 뒤의 멈춤은 수습 없이 멈춘다
#   TRIAGE_TIMEOUT_SEC  수습 세션 한 번의 제한 시간 (기본 3600 = 1시간)
#   TRIAGE_LABEL        수습 세션이 낸 수정 PR에 붙이는 라벨 (기본 loop-triage, 없으면 만든다) — 사람이 나중에 몰아서 본다
#
# 멈추는 조건(루프 종료, 워크트리는 조사용으로 남긴다):
#   - 워커가 PR 없이 멈춤(질문·실패, 확인 창에 PROMPT_STALL_SEC 머묾) / 워커가 사용량 한도에 걸림(usage_limit — 수습 없음) / 티켓 타임아웃 /
#     백엔드 터미널 끊김 / 에이전트 기동 실패
#   - 수리 REPAIR_ROUNDS회 뒤에도 CI 실패 또는 충돌, 수리 뒤 새 커밋이 없고 CI도 그대로 실패(재실행만 한 수리가 통과하면 이어 간다)
#   - 병합 뒤 POST_MERGE_CMD 실패(POST_MERGE_RETRY_CMD가 있으면 재실행까지 실패), 또는 POST_MERGE_PORT가 10분 안에 비지 않음.
#     여러 병합을 묶어 검증했으면(POST_MERGE_EVERY) 사유에 묶음과 이분 탐색으로 찾은 처음 실패하는 병합을 적는다
#     (기다리는 동안은 로그 한 줄 뒤 조용하다 — 멈춤이 아니다)
# 자동 선택은 선행 이슈가 열렸거나, PR이 이미 있거나, 담당자가 있거나, 하위 이슈를 가진(스펙) 이슈를 건너뛴다.
#
# 멈추면 — 위 조건, 그리고 터미널 창 닫힘(HUP·PIPE)·Ctrl-C·kill(TERM)·set -e에 걸린 명령(네트워크가 끊겨 git fetch·gh가 실패하는 등) —
# 어떻게 끝나든 한 번만 보고한다: 진행 중 티켓을 stopped로 기록하고, 그 이슈에 코멘트(사유·머신·PR·워크트리·루프 로그 끝)와
# STOPPED_LABEL을 남기고(GitHub 기록 — 루프는 본인 계정으로 쓰므로 GitHub는 본인에게 알리지 않는다. 알림이 아니라 기록이다),
# 데스크톱과 Slack(SLACK_WEBHOOK_URL)에 알린다. Slack에는 루프 시작·티켓 완료·루프 종료도 간다.
# kill -9·전원 꺼짐·잠자기처럼 스크립트가 아무것도 보내지 못하는 경우는 잡지 못한다.
# 멈출 때마다 멈춤 기록(.ticket-loop/stops/<id>.json — 사유·이슈·PR·로그 경로·워크트리·다시 실행할 명령, 기계별)을 남긴다.
# 사람은 그 저장소의 에이전트 세션에서 /loop-triage <id>(Codex는 $loop-triage)로 그 기록부터 이어받는다.
#
# 무인 수습(LOOP_TRIAGE=1, 기본): 아래 네 경우에는 멈추기 전에 멈춤 기록을 쓰고, 워커처럼 새 워크트리에 에이전트를 띄워
# `/loop-triage <기록>`을 시킨 뒤 판정 파일(<id>.verdict.json — resume | halt)을 기다린다. Slack에는 "수습 시작"과 결과가 간다.
#   - 병합 뒤 검증 실패(재실행까지 실패) → 수습 세션이 수정 PR을 내면 루프가 CI 뒤 병합하고, 병합된 기본 브랜치로 검증을 다시 돌려
#     통과하면 이어 간다(플레이크로 판정하면 수정 없이 검증만 다시 돌린다)
#   - 수리를 다 쓴 CI 실패·충돌, 새 커밋 없이 끝난 수리 뒤에도 CI 실패 → 수습 세션이 티켓 PR 브랜치에 고쳐 push하면(또는 CI 플레이크면 실패한 job을 다시 돌리면)
#     CI 대기부터 이어 간다
#   - WORKTREE_SETUP_CMD 실패(cmux·tmux) → 수정 PR을 병합하면 워크트리를 기본 브랜치로 당기고(메인 체크아웃도 기본 브랜치면 fast-forward)
#     준비를 다시 돌린다
#   - 워커가 PR 없이 멈춤 → 진단만 한다. 판단이 필요한 질문이 많아 답하지 않고, 요약을 실어 멈춘다
# 판정이 halt이거나, 판정 없이 끝나거나(제한 시간·idle), 수정 PR의 CI가 실패하거나, 이어 간 뒤 같은 곳에서 또 실패하면 진단을 사유에 붙여
# 멈춘다(수습 세션의 워크트리는 남긴다). 한 실행에 TRIAGE_MAX번까지, 같은 멈춤에는 한 번만. 수습 세션은 기본 브랜치에 커밋된
# loop-triage 스킬을 쓰므로 키트 설치 PR이 병합되기 전에는 띄우지 않는다. 그 밖의 멈춤(사용량 한도, 타임아웃, 터미널 끊김, 에이전트 기동 실패,
# 병합 실패, 신호, set -e)은 수습 없이 멈춘다 — 어디서든 안전하게 이어 갈 수 있는 자리가 아니다. GitHub 일시 장애(5xx·연결 오류)는
# 읽기 호출과 병합 모두 멈추기 전에 GH_TRIES번까지 다시 해 본다. 필수 리뷰 같은 브랜치 보호의 거절은 사람에게 넘기는 자리다.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"   # 저장소 루트. 도구 검사 뒤 git으로 다시 확정한다
LOOP_ENV="$ROOT/.ticket-loop/loop.env"
# 기계별 설정·비밀 값은 커밋하지 않는 사용자 파일에 둔다. 저장소 loop.env보다 먼저 읽어 이긴다(둘 다 VAR="${VAR:-값}" 꼴)
USER_LOOP_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/ticket-loop/loop.env"
# shellcheck source=/dev/null
[[ ! -f "$USER_LOOP_ENV" ]] || source "$USER_LOOP_ENV"
# shellcheck source=/dev/null
[[ ! -f "$LOOP_ENV" ]] || source "$LOOP_ENV"

BACKEND="${BACKEND:-orca}"
if [[ -n "${ORCA_CLI:-}" ]]; then :
elif [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then ORCA_CLI="$ORCA_CLI_COMMAND"
elif [[ "$(uname -s)" == "Linux" ]]; then ORCA_CLI="orca-ide"   # Linux의 orca는 GNOME 스크린리더다
else ORCA_CLI="orca"
fi
if [[ -z "${CMUX_CLI:-}" ]]; then
  if command -v cmux >/dev/null 2>&1; then CMUX_CLI="cmux"; else CMUX_CLI="/Applications/cmux.app/Contents/Resources/bin/cmux"; fi
fi
TMUX_CLI="${TMUX_CLI:-tmux}"
TMUX_SESSION="${TMUX_SESSION:-}"
WORKTREE_DIR="${WORKTREE_DIR:-}"
WORKTREE_SETUP_CMD="${WORKTREE_SETUP_CMD:-}"
PARENT="${SPEC_ISSUE:-}"
CLOSED_SPECS=""   # 이번 실행에서 닫은 스펙 이슈 번호들(끝날 때 회고 안내에 쓴다)
SCOPE_LABEL="${SCOPE_LABEL:-}"
READY_LABEL="${READY_LABEL:-ready-for-agent}"
IN_REVIEW_LABEL="${IN_REVIEW_LABEL:-in-review}"
BRANCH_PREFIX="${BRANCH_PREFIX:-issue-}"
BASE_BRANCH="${BASE_BRANCH:-}"
ORDER_REGEX="${ORDER_REGEX:-^T(?<n>[0-9]+)}"
WORKER_RULES_FILE="${WORKER_RULES_FILE:-.ticket-loop/worker-rules.md}"
AGENT="${AGENT:-claude}"
TICKET_TIMEOUT_SEC="${TICKET_TIMEOUT_SEC:-14400}"
MERGE_METHOD="${MERGE_METHOD:-merge}"
REPAIR_ROUNDS="${REPAIR_ROUNDS:-1}"
CI_SKIP_REGEX="${CI_SKIP_REGEX:-}"
CI_SKIP_CMD="${CI_SKIP_CMD:-}"
POST_MERGE_CMD="${POST_MERGE_CMD:-}"
POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-}"
POST_MERGE_EVERY="${POST_MERGE_EVERY:-4}"
POST_MERGE_COPY="${POST_MERGE_COPY:-}"
POST_MERGE_PORT="${POST_MERGE_PORT:-}"
POST_MERGE_WORKTREE="${POST_MERGE_WORKTREE:-}"
LOG_FILE="${LOG_FILE:-.ticket-loop/loop-$(date +%m%d).log}"
RECORDS_FILE="${RECORDS_FILE:-.ticket-loop/tickets.jsonl}"
REPORT_DIR="${REPORT_DIR:-docs/loop-reports}"
REPORT_OPEN="${REPORT_OPEN:-1}"
REPORT_DECISIONS_HEADING="${REPORT_DECISIONS_HEADING:-}"
REPORT_DECISIONS_NONE="${REPORT_DECISIONS_NONE:-없음|none|N/A}"
PROGRESS_SEC="${PROGRESS_SEC:-60}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-300}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_MENTION="${SLACK_MENTION:-}"
STOPPED_LABEL="${STOPPED_LABEL:-loop-stopped}"
LOOP_TRIAGE="${LOOP_TRIAGE:-1}"
TRIAGE_MAX="${TRIAGE_MAX:-1}"
TRIAGE_TIMEOUT_SEC="${TRIAGE_TIMEOUT_SEC:-3600}"
TRIAGE_LABEL="${TRIAGE_LABEL:-loop-triage}"
# 파일 경로는 시작 때 한 번 저장소 루트 기준 절대 경로로 굳힌다(loop.env나 환경변수로 상대 경로를 줘도 같다). 루프는 저장소
# 루트에서 돌지만, 병합 뒤 검증처럼 다른 디렉터리로 cd 한 서브셸에서 여는 파일은 그 디렉터리 기준이 된다 — 실측(0.8.3,
# rental-portal #101)에서 post-merge-N.log가 검증 워크트리 안에 생기고 루프는 저장소 루트에서 꼬리를 찾지 못했다.
# /dev/null(로그 끔)은 절대 경로라 그대로다
abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT" "$1" ;; esac; }
LOG_FILE="$(abs_path "$LOG_FILE")"
RECORDS_FILE="$(abs_path "$RECORDS_FILE")"
REPORT_DIR="$(abs_path "$REPORT_DIR")"
# ----- 에이전트 프리셋 -----
# AGENT가 기동 명령·배너·모델 정규식·스킬 접두사·화면 분류 정규식(사용량 한도·권한 확인 창)의 기본값을 정한다. loop.env나 환경변수로 준 값이 이긴다.
#   claude  Claude Code. 스킬은 /이름. 모델명은 상태줄·배너의 "Opus 5.5" 꼴. 사용량 한도는 "You've reached your … limit"·"usage limit", 권한 확인 창은
#           "Do you want to proceed?"(screen_kind — idle strike 앞에서 본다)
#   codex   Codex CLI. 스킬은 $이름 — Codex는 .claude/skills/ 를 읽지 않고 .agents/skills/ 를 읽는다(배치는 키트 다음 단계). 배너 "OpenAI Codex",
#           모델명 "gpt-5.1-codex" 꼴(상태줄 설정에 따라 안 보일 수 있다 → not recorded). --dangerously-bypass-approvals-and-sandbox(=--yolo)는
#           Claude의 --dangerously-skip-permissions에 해당한다 — 더 좁은 --sandbox workspace-write는 네트워크를 막아 push·gh pr create가 안 된다.
#           .claude/settings.json의 deny(gh pr merge)는 Codex에 안 걸린다 — 병합 금지는 프롬프트와 GitHub 브랜치 보호에 기댄다
#           사용량 한도·확인 창 문구는 실측 전이라 비워 둔다(감지하지 않음) — 실측 뒤 loop.env의 USAGE_LIMIT_REGEX·PERMISSION_PROMPT_REGEX로 켠다
#   그 외   프리셋 없음. AGENT_RESTART_CMD·AGENT_BANNER_REGEX(·MODEL_REGEX·SKILL_PREFIX·USAGE_LIMIT_REGEX·PERMISSION_PROMPT_REGEX)를 loop.env에 적는다.
#           기동 명령·배너가 비어 있으면 시작 때 멈춘다
case "$AGENT" in
  claude)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-claude --dangerously-skip-permissions}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-Claude Code|Opus|Sonnet|Fable|Haiku}"
    MODEL_REGEX="${MODEL_REGEX:-(Opus|Sonnet|Haiku|Fable|Mythos)[[:space:]]+[0-9]+(\.[0-9]+)?}"
    SKILL_PREFIX="${SKILL_PREFIX:-/}"
    USAGE_LIMIT_REGEX="${USAGE_LIMIT_REGEX:-reached your .* limit|usage limit}"
    PERMISSION_PROMPT_REGEX="${PERMISSION_PROMPT_REGEX:-Do you want to proceed\?}" ;;
  codex)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-codex --dangerously-bypass-approvals-and-sandbox}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-OpenAI Codex|gpt-[0-9]}"
    MODEL_REGEX="${MODEL_REGEX:-gpt-[0-9]+(\.[0-9]+)?(-[[:alnum:]]+)*}"
    SKILL_PREFIX="${SKILL_PREFIX:-\$}"
    USAGE_LIMIT_REGEX="${USAGE_LIMIT_REGEX:-}"
    PERMISSION_PROMPT_REGEX="${PERMISSION_PROMPT_REGEX:-}" ;;
  *)
    AGENT_RESTART_CMD="${AGENT_RESTART_CMD:-}"
    AGENT_BANNER_REGEX="${AGENT_BANNER_REGEX:-}"
    MODEL_REGEX="${MODEL_REGEX:-}"
    SKILL_PREFIX="${SKILL_PREFIX:-/}"
    USAGE_LIMIT_REGEX="${USAGE_LIMIT_REGEX:-}"
    PERMISSION_PROMPT_REGEX="${PERMISSION_PROMPT_REGEX:-}" ;;
esac
# ----- 에이전트 프리셋 끝 -----
IDLE_WAIT_MS=600000       # idle 1회 대기 상한(Orca: terminal wait 한 번, cmux: 폴링 한 바퀴). PR·수리 대기는 PROGRESS_SEC(진행 로그)마다 돌아온다
IDLE_POLL_SEC=5           # cmux·tmux 백엔드가 에이전트 상태(lifecycle / 훅 파일)를 다시 읽는 간격
SEND_ACCEPT_SEC=15        # cmux·tmux 백엔드: 프롬프트를 보낸 뒤 에이전트가 새 턴을 시작하는지(running) 0.5초마다 보는 상한
TERMINAL_RETRY=5          # wait가 이상하게 끝났을 때 터미널 읽기를 다시 해 보는 횟수
TERMINAL_RETRY_SEC=10
IDLE_STRIKES=3            # PR 없이 연속 idle이면 멈춤으로 본다
IDLE_RECHECK_SEC=30
SESSION_LOG_FRESH_SEC=30  # idle로 보여도 Claude Code 세션 기록(*.jsonl)이 이 안에 갱신됐으면 아직 일하는 중 — strike를 세지 않는다(session_active_recently)
PROMPT_STALL_SEC=300      # 권한 확인 창 문구(PERMISSION_PROMPT_REGEX)가 든 화면이 이만큼 글자 그대로면 idle 신호가 없어도 확인 창에 멈춘 워커로 보고
                          # worker_no_pr로 멈춘다(screen_check). 화면이 바뀌면 다시 센다. 2026-10 실측(#3, tmux): idle 신호가 비어 27분을 조용히 기다렸다
STARTUP_GRACE_SEC=120     # 기동 직후에는 프롬프트 처리 전에도 idle로 잡힌다
AGENT_START_WAIT_SEC=90   # 에이전트 배너가 보이기까지 기다리는 상한(1회), 넘기면 한 번 다시 띄운다
CI_APPEAR_TIMEOUT_SEC=900
GH_TRIES=3                # GitHub 일시 장애(5xx·연결 오류)에 걸린 gh 읽기 호출(gh 함수)과 병합(merge_pr)을 다시 해 보는 횟수(첫 시도 포함).
GH_RETRY_SEC=15           # 그 사이 GH_RETRY_SEC×회차씩 쉰다(15초·30초)
PICK_RETRY_SEC=300        # 티켓 사이의 다음 대상 조회(pick_targets)가 gh 재시도까지 실패할 때 다시 해 보는 총 시간. 넘기면 멈춘다(could not list tickets)
PICK_RETRY_EVERY_SEC=60   # 그 사이 다시 해 보는 간격
PICK_RECHECK_SEC=30       # 티켓 사이의 다음 대상 조회가 성공하면서 후보를 하나도 돌려주지 않으면(0행) 이만큼 쉬고 한 번 더 조회한다 — GitHub가 성공한
                          # 빈 응답을 준 것을 "남은 티켓 없음"으로 읽지 않게(#22). 두 번째도 0행이면 그때 확정한다(--parent면 스펙의 열린 하위 이슈 수와 맞춰 본다)
PORT_WAIT_SEC=600         # POST_MERGE_PORT가 비기를 기다리는 상한. 기다리는 동안은 30초마다 다시 본다(멈춤이 아니다)
REOPEN_WATCH_SEC=2        # 수습 수정 PR을 병합한 뒤 티켓 이슈가 닫히는지 다시 보는 간격(5번 — triage_keep_issue_open)
PR_SETTLE_SEC=120         # PR을 찾은 뒤 워커의 이슈 정리(체크박스·IN_REVIEW_LABEL)를 기다리는 상한. 라벨이 붙거나 idle이면 바로 넘어간다(pr_settle)
REPAIR_SETTLE_SEC=300     # 수리 중 idle이 끝내 안 잡힐 때: 새 커밋이 push된 뒤 head가 이만큼 그대로이고 워크트리가 깨끗하면 수리가 끝난 것으로 본다

DRY_RUN=0
NO_MERGE=0
POST_MERGE=1
MAX=0
TICKETS=()
ORIG_ARGS=("$@")   # 멈춤 기록의 "다시 실행할 명령"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-merge) NO_MERGE=1 ;;
    --skip-post-merge) POST_MERGE=0 ;;
    --max) MAX="$2"; shift ;;
    --parent) PARENT="${2#\#}"; shift ;;
    --label) SCOPE_LABEL="$2"; shift ;;
    --help|-h) awk 'NR > 2 && /^#/ { on = 1; sub(/^# ?/, ""); print; next } on { exit }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TICKETS+=("${1#\#}") ;;
  esac
  shift
done
[[ -n "$POST_MERGE_CMD" ]] || POST_MERGE=0
[[ "$POST_MERGE_EVERY" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "POST_MERGE_EVERY must be 0 or a positive integer (got '${POST_MERGE_EVERY}')" >&2; exit 2; }

# 터미널 색 — 단계가 한눈에 갈리도록. 터미널일 때만 칠하고, NO_COLOR(https://no-color.org)나 TERM=dumb이면 끈다.
# 아래 exec가 stderr를 tee로 바꾸기 전에 판정해야 한다. 파이프로 받는 쪽과 로그 파일은 맨글자만 본다.
# C_BANNER(시작 머리줄)는 256색 주황(208) — 16색에는 주황이 없고, 나머지 단계 색(보라·청록·초록·노랑·빨강) 어느 것과도 겹치지 않는다.
# 테마 팔레트가 아니라 고정 색이라 터미널 테마가 바뀌어도 같은 주황이다(macOS Terminal·iTerm2·Ghostty/cmux·tmux·Orca 모두 256색)
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_TITLE=$'\e[1;35m'; C_STEP=$'\e[36m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[1;31m'
  C_BANNER=$'\e[1;38;5;208m'
else
  C_RESET=""; C_DIM=""; C_TITLE=""; C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_BANNER=""
fi
# 로그 파일로 가는 줄에서 색 코드(SGR, ESC[…m)만 지운다. 그 밖의 이스케이프는 손대지 않는다 — bash 3.2(macOS)도 되는 문자열 처리
strip_ansi() {
  local l pre rest code
  while IFS= read -r l || [[ -n "$l" ]]; do
    pre=""; rest="$l"
    while [[ "$rest" == *$'\e['* ]]; do
      pre+="${rest%%$'\e['*}"; rest="${rest#*$'\e['}"; code="${rest%%m*}"
      if [[ "$rest" == *m* && "$code" != *[!0-9';']* ]]; then rest="${rest#*m}"; else pre+=$'\e['; fi
    done
    printf '%s\n' "$pre$rest"
  done
}

# --dry-run은 로그를 남기지 않는다(목록 확인만). 실행 로그는 다음 /retro가 읽는 1차 자료다.
# LOG_START_BYTES: 이 실행이 시작할 때의 로그 파일 크기. 로그는 날짜별 한 파일에 이어 쓰므로 멈춤 보고에 싣는 "로그 끝"을 이 실행의
# 줄로 한정한다(run_log) — 0.8.8 실측에서 같은 날 앞 실행의 ERROR 줄이 다음 실행의 Slack 멈춤 알림에 섞여 나왔다
LOG_START_BYTES=0
if [[ $DRY_RUN -eq 0 && "$LOG_FILE" != "/dev/null" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  [[ ! -f "$LOG_FILE" ]] || LOG_START_BYTES=$(( $(wc -c < "$LOG_FILE") ))
  if [[ -n "$C_RESET" ]]; then exec 2> >(tee >(strip_ansi >> "$LOG_FILE") >&2)
  else exec 2> >(tee -a "$LOG_FILE" >&2); fi
fi

# log [title|step|ok|warn|err] 메시지 — 첫 인자가 단계 이름이면 그 색으로(터미널), 없으면 맨글자. 시각은 흐리게.
#   title 티켓 시작(앞에 빈 줄) / step 단계 전환(워크트리·PR·CI) / ok 성공·요약 / warn 되풀이·수리·건너뜀 / err 중단
log() {
  local lvl="" c=""
  case "${1:-}" in title|step|ok|warn|err) [[ $# -lt 2 ]] || { lvl="$1"; shift; } ;; esac   # 메시지가 따로 있을 때만 단계로 본다
  case "$lvl" in title) c="$C_TITLE"; printf '\n' >&2 ;; step) c="$C_STEP" ;; ok) c="$C_OK" ;; warn) c="$C_WARN" ;; err) c="$C_ERR" ;; esac
  printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET" "$c" "$*" "${c:+$C_RESET}" >&2
}
# 설치된 키트 버전 — "0.9.6 (435e70e)". .ticket-loop/kit.json은 설치기가 쓴다. 없으면(키트 저장소에서 돌리거나 손으로 복사) unknown
kit_version() {
  local kitjson="${ROOT}/.ticket-loop/kit.json" v c
  v="$(jq -r '.version // empty' "$kitjson" 2>/dev/null || true)"; c="$(jq -r '.commit // empty' "$kitjson" 2>/dev/null || true)"
  printf '%s%s' "${v:-unknown}" "${c:+ (${c:0:7})}"
}
# 시작 머리줄 "━━ ticket-loop-kit 0.9.6 (435e70e) ━━━…" — 실행 맨 앞에 한 줄(앞에 빈 줄). 로그는 날짜별 한 파일에 이어 쓰므로 실행의
# 경계가 되고, /retro·멈춤 진단에서 어느 키트 버전이 낸 줄인지 가른다. 폭은 BANNER_COLS로 고정 — 좁은 워커 창에서도 접히지 않게 짧게 둔다
BANNER_COLS=56
kit_banner() {
  local fill n=$(( BANNER_COLS - ${#1} - 4 ))
  [[ $n -ge 3 ]] || n=3
  printf -v fill '%*s' "$n" ''
  printf '\n%s━━ %s %s%s\n' "$C_BANNER" "$1" "${fill// /━}" "${C_BANNER:+$C_RESET}" >&2
}
# 워커 화면·검증 로그 꼬리처럼 통째로 보여 주는 출력은 흐리게, 들여 써서 루프 로그와 가른다. $1은 줄 앞에 붙일 글자(선택)
dim_lines() { local l; while IFS= read -r l || [[ -n "$l" ]]; do printf '%s%s%s%s\n' "$C_DIM" "${1:-  }" "$l" "$C_RESET" >&2; done; }
# ----- 알림 · 멈춤 보고 -----
# 알림은 데스크톱(자리에 있을 때)과 Slack(SLACK_WEBHOOK_URL — 자리를 비웠을 때) 두 곳으로 간다. 어느 쪽이 실패해도 루프 결과는 바뀌지 않는다.
# STOP_ISSUE: 멈추면 GitHub 기록을 남길 티켓. CUR_N(티켓 기록)은 병합 기록을 쓰면 비지만, 그 뒤 병합 뒤 검증이 실패해도 그 티켓의 멈춤이다
REPO_URL=""; STOP_ISSUE=""; STOP_REPORTED=0; LOCK_HELD=0; BG_PID=""
# STOP_KIND: 멈춤 기록의 종류(post_merge_failed·ci_failed·setup_failed·worker_no_pr·usage_limit·merge_failed·signal·unexpected_exit, 그 밖은 비워 other).
# STOP_RECORD: 이번 멈춤에 이미 쓴 멈춤 기록(무인 수습이 쓴 것) — stop_report가 같은 멈춤을 두 번 기록하지 않게
STOP_KIND=""; STOP_RECORD=""
fmt_epoch() { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S'; }   # macOS / Linux

# notify 제목 본문 [종류 [꼬리]] — 종류 start | done | flaky | triage | resumed | stop | interrupt | finish(Slack 아이콘·멘션),
# 꼬리는 Slack에만 코드 블록으로 붙는다
notify() {
  if command -v osascript >/dev/null 2>&1; then
    # 문구를 AppleScript 소스에 끼우지 않고 인자로 넘긴다 — 티켓 제목·멈춤 사유의 따옴표가 스크립트를 깨지 않게
    osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1 || true
  fi
  slack_post "$@"
}

# Slack Incoming Webhook. 본문의 #N은 이슈·PR 링크가 된다(GitHub의 /issues/N은 PR이면 /pull/N으로 넘긴다). &·<·>는 Slack 규칙대로 이스케이프한다.
# 멈춤(stop)에만 SLACK_MENTION을 앞에 붙인다. 잠금을 잡은 실행만 보낸다 — --dry-run과, 이미 도는 루프와 겹쳐 시작하자마자 멈춘 실행이
# "루프가 멈췄다"고 알려 도는 루프를 의심하게 하지 않도록
slack_post() {
  [[ -n "$SLACK_WEBHOOK_URL" && $LOCK_HELD -eq 1 ]] || return 0
  local payload
  payload="$(jq -cn --arg title "$1" --arg body "${2:-}" --arg kind "${3:-}" --arg tail "${4:-}" --arg mention "$SLACK_MENTION" \
      --arg repo "${OWNER_REPO:-${ROOT##*/}}" --arg url "$REPO_URL" --arg host "$(hostname -s 2>/dev/null || hostname)" '
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    def link: if $url == "" then . else gsub("#(?<n>[0-9]+)"; "<\($url)/issues/\(.n)|#\(.n)>") end;
    ({start: ":arrow_forward:", done: ":white_check_mark:", flaky: ":warning:", triage: ":hammer_and_wrench:", resumed: ":recycle:",
      stop: ":octagonal_sign:", interrupt: ":octagonal_sign:"}[$kind] // ":checkered_flag:") as $icon
    | {text: ("\($icon) *\($title | esc)* · \($repo | esc) · \($host | esc)\n"
        + (if $kind == "stop" and $mention != "" then "\($mention) " else "" end)
        + ($body | esc | link)
        + (if $tail != "" then "\n```\n\($tail | esc)\n```" else "" end))}')" || return 0
  curl -fsS -m 15 -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" </dev/null >/dev/null 2>&1 \
    || log warn "Slack notification failed — check SLACK_WEBHOOK_URL"
}

die() { log err "ERROR: $*"; stop_report "$*"; exit 1; }

# 이 실행이 로그 파일에 쓴 부분(LOG_START_BYTES 뒤). 같은 날 앞 실행의 줄은 빠진다
run_log() { tail -c "+$(( ${LOG_START_BYTES:-0} + 1 ))" "$LOG_FILE" 2>/dev/null || true; }

# 멈춤 기록 — /loop-triage가 읽는 JSON 한 파일(ROOT/.ticket-loop/stops/<id>.json, 기계별 — 커밋하지 않는다). 무인 수습을 띄울 때 한 번,
# 수습 없이 멈출 때는 stop_report가 한 번 쓴다 — 사람이 나중에 /loop-triage로 이어받을 자리다. 경로를 stdout에 쓴다.
# 로그는 경로와 이 실행이 쓰기 시작한 바이트(loop_from_byte)만 적는다 — 내용은 수습 세션이 그 머신에서 직접 읽는다.
# $1 종류(STOP_KIND), $2 사유, $3 unattended(루프가 수습 세션을 띄운다) | manual(아무도 수습하지 않았다)
write_stop_record() {
  local kind="$1" reason="$2" mode="$3" dir="${ROOT}/.ticket-loop/stops" id file a
  local kitjson="${ROOT}/.ticket-loop/kit.json" rerun="bash scripts/ticket-loop.sh" wt="" log="" pm_window=null
  id="$(date '+%Y%m%d-%H%M%S')-${STOP_ISSUE:-0}"
  file="${dir}/${id}.json"
  for a in ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; do rerun+=" $(printf '%q' "$a")"; done
  [[ -z "${WT_PATH:-}" || ! -d "${WT_PATH:-}" ]] || wt="$WT_PATH"
  [[ "${LOG_FILE:-/dev/null}" == /dev/null ]] || log="$LOG_FILE"
  ! declare -F pm_window_json >/dev/null || pm_window="$(pm_window_json 2>/dev/null || echo null)"
  mkdir -p "$dir" || return 1
  jq -n --arg id "$id" --arg kind "${kind:-other}" --arg mode "$mode" --arg reason "$reason" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg repo "${OWNER_REPO:-}" --arg base "${BASE_BRANCH:-}" --arg issue "${STOP_ISSUE:-}" --arg title "${CUR_TITLE:-}" \
    --arg spec "${PARENT:-}" --arg pr "${CUR_PR:-}" --arg wt "$wt" --arg main "${MAIN_WT:-$ROOT}" \
    --arg log "$log" --argjson from "${LOG_START_BYTES:-0}" --arg pm_log "${POST_MERGE_LOG:-}" --arg pm_retry_log "${POST_MERGE_RETRY_LOG:-}" \
    --arg pm_wt "${POST_MERGE_WT:-}" --arg pm_cmd "${POST_MERGE_CMD:-}" --arg pm_retry_cmd "${POST_MERGE_RETRY_CMD:-}" \
    --arg setup_cmd "${WORKTREE_SETUP_CMD:-}" --arg rerun "$rerun" --arg verdict "${dir}/${id}.verdict.json" \
    --arg agent "${AGENT:-}" --arg backend "${BACKEND:-}" --argjson pm_window "${pm_window:-null}" \
    --arg kit_version "$(jq -r '.version // empty' "$kitjson" 2>/dev/null || true)" --arg kit_repo "$(jq -r '.kit // empty' "$kitjson" 2>/dev/null || true)" '
    def num: if . == "" then null else tonumber end;
    def str: if . == "" then null else . end;
    {id: $id, kind: $kind, mode: $mode, created_at: $created, reason: $reason,
     repo: ($repo | str), base_branch: ($base | str), issue: ($issue | num), title: ($title | str), spec: ($spec | num), pr: ($pr | num),
     worker_worktree: ($wt | str), main_checkout: $main,
     logs: {loop: ($log | str), loop_from_byte: $from, post_merge: ($pm_log | str), post_merge_retry: ($pm_retry_log | str)},
     post_merge_worktree: ($pm_wt | str), post_merge_window: $pm_window,
     commands: {post_merge: ($pm_cmd | str), post_merge_retry: ($pm_retry_cmd | str), worktree_setup: ($setup_cmd | str)},
     rerun: $rerun, verdict_file: $verdict, agent: ($agent | str), backend: ($backend | str),
     kit: {version: ($kit_version | str), repo: ($kit_repo | str)}}' > "$file" || return 1
  printf '%s' "$file"
}

# 멈춤 보고는 한 번만 — die, 신호, 예기치 않은 종료가 모두 여기로 온다. 진행 중 티켓을 stopped로 기록하고(스펙 리포트), 멈춤 기록을
# 남기고(무인 수습이 이미 남겼으면 그것), 그 이슈에 GitHub 기록을 남기고, 알린다. Slack에는 로그 끝 12줄을 붙인다 — 워커 화면 꼬리가
# 들어 있어 "왜 멈췄나"가 폰에서 보인다. $1 사유, $2 stop | interrupt(Ctrl-C — 사람이 앞에 있으니 멘션하지 않는다)
stop_report() {
  [[ $STOP_REPORTED -eq 0 ]] || return 0
  STOP_REPORTED=1
  local reason="$1" kind="${2:-stop}" tail=""
  [[ -z "${CUR_N:-}" ]] || record_ticket "stopped" "$reason"
  if [[ $LOCK_HELD -eq 1 && -z "$STOP_RECORD" ]]; then
    STOP_RECORD="$(write_stop_record "$STOP_KIND" "$reason" manual 2>/dev/null)" || STOP_RECORD=""
  fi
  if [[ $LOCK_HELD -eq 1 && "$LOG_FILE" != "/dev/null" && -f "$LOG_FILE" ]]; then
    sleep 1   # 로그 파일은 tee가 비동기로 쓴다 — 방금 찍은 ERROR 줄·워커 화면이 파일에 들어오게
    tail="$(run_log | tail -n 12)"
  fi
  [[ -z "$STOP_ISSUE" ]] || github_stop_record "$STOP_ISSUE" "$reason"
  local title="Ticket loop stopped"
  [[ "$STOP_KIND" != usage_limit ]] || title="Ticket loop stopped — worker hit the usage limit"   # 수습 없이 멈춘 한도 — 제목에서 바로 보이게
  notify "$title" "$reason" "$kind" "$tail"
}

# 멈춘 티켓의 GitHub 기록 — 이슈에 코멘트(사유·머신·PR·워크트리·루프 로그 끝)를 달고 STOPPED_LABEL을 붙인다. 알림이 아니라 기록이다:
# 루프는 사용자 계정(gh auth)으로 쓰므로 GitHub는 본인에게 알리지 않는다(알림은 Slack). 대상 선택은 이 라벨을 보지 않고, 루프가 그 티켓을
# 병합하면 뗀다. 코멘트에 싣는 로그는 루프 자신의 줄([시각]으로 시작)뿐이다 — 들여 쓴 워커 화면·검증 로그는 공개 저장소에 올리지 않는다
github_stop_record() {
  local n="$1" reason="$2" lines="" now body tilde='~'
  now="$(date +%s)"
  [[ "$LOG_FILE" == "/dev/null" || ! -f "$LOG_FILE" ]] || lines="$(run_log | grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} ' | tail -n 30 || true)"
  body="**ticket-loop 중단** — ${reason}"$'\n\n'
  body+="- 머신 \`$(hostname -s 2>/dev/null || hostname)\` · 백엔드 ${BACKEND_NAME:-$BACKEND} · 에이전트 ${AGENT}${CUR_MODEL:+ (${CUR_MODEL})}"$'\n'
  [[ -z "${CUR_STARTED:-}" ]] || body+="- 티켓 시작 $(fmt_epoch "$CUR_STARTED") → 중단 $(fmt_epoch "$now") ($(( (now - CUR_STARTED) / 60 ))분)"$'\n'
  [[ -z "${CUR_PR:-}" ]] || body+="- PR #${CUR_PR}"$'\n'
  [[ -z "${WT_PATH:-}" || ! -d "${WT_PATH:-}" ]] || body+="- 워크트리 \`${WT_PATH/#"$HOME"/$tilde}\` — 조사용으로 남겨 둠"$'\n'
  [[ "$LOG_FILE" == "/dev/null" ]] || body+="- 루프 로그 \`${LOG_FILE#"$ROOT"/}\` (그 머신에만 있다)"$'\n'
  [[ -z "${PM_PENDING:-}" ]] || ! declare -F pm_list >/dev/null \
    || body+="- 아직 병합 뒤 검증을 통과하지 않은 병합: $(pm_list) — 다음 실행의 검증이 함께 덮는다"$'\n'
  [[ -z "$STOP_RECORD" ]] || body+="- 멈춤 기록 \`${STOP_RECORD#"$ROOT"/}\` (그 머신에만 있다) — 이어받으려면 그 저장소의 에이전트 세션에서 \`${SKILL_PREFIX:-/}loop-triage $(basename "$STOP_RECORD" .json)\`"$'\n'
  [[ -z "$lines" ]] || body+=$'\n'"<details><summary>루프 로그 마지막 $(grep -c . <<<"$lines")줄</summary>"$'\n\n```text\n'"${lines}"$'\n```\n\n</details>\n'
  gh label create "$STOPPED_LABEL" --color B60205 --description "ticket-loop가 이 티켓에서 멈춤(기록용)" </dev/null >/dev/null 2>&1 || true
  gh issue comment "$n" --body "$body" </dev/null >/dev/null 2>&1 || log warn "#${n}: failed to post the stop record to GitHub"
  gh issue edit "$n" --add-label "$STOPPED_LABEL" </dev/null >/dev/null 2>&1 || log warn "#${n}: failed to add the ${STOPPED_LABEL} label"
}

# 병합 뒤 검증이 재실행에서 통과했을 때의 기록. 루프는 계속 가지만 같은 플레이크가 되풀이되는지 나중에 볼 수 있게 이슈에 코멘트를 달고
# 알린다(멘션 없이 — 사람을 부를 일은 아니다). 멈춤이 아니라 STOPPED_LABEL은 붙이지 않는다. github_stop_record처럼 검증 로그 본문은
# 공개 저장소에 올리지 않고 파일 이름만 적는다. $1 이슈, $2 첫 실행 로그, $3 재실행 로그, $4 첫 실행 초, $5 재실행 초
post_merge_flaky_record() {
  local n="$1" first_log="$2" retry_log="$3" first_sec="$4" retry_sec="$5" body
  body="**ticket-loop 병합 뒤 검증 재시도 통과** — 플레이크 의심"$'\n\n'
  body+="- 첫 실행 ${first_sec}초 만에 실패 → 재실행(\`POST_MERGE_RETRY_CMD\`) ${retry_sec}초 만에 통과. 루프는 멈추지 않고 계속 갔다"$'\n'
  [[ -z "${CUR_PR:-}" ]] || body+="- PR #${CUR_PR} 병합 뒤"$'\n'
  body+="- 머신 \`$(hostname -s 2>/dev/null || hostname)\` · 검증 로그 \`${first_log##*/}\`(첫 실행), \`${retry_log##*/}\`(재실행) — 그 머신에만 있다"$'\n'
  gh issue comment "$n" --body "$body" </dev/null >/dev/null 2>&1 || log warn "#${n}: failed to post the post-merge retry record to GitHub"
  notify "Post-merge check passed on retry" "#${n}: first run failed in ${first_sec}s, retry passed in ${retry_sec}s — likely flaky (logs ${first_log##*/}, ${retry_log##*/})" flaky
}

# 무인 수습이 고쳐 이어 갈 때의 기록 — 그 이슈에 코멘트(멈춘 이유·분류·요약·조치)를 달고 멘션 없이 알린다. 멈춤이 아니라 STOPPED_LABEL은
# 붙이지 않는다. 멈춘 이유는 루프 자신의 문구라 로컬 경로가 섞일 수 있어 홈을 ~로 줄인다.
# $1 이슈(0이면 코멘트 없음) $2 멈춘 이유 $3 분류 $4 요약 $5 조치(영어 — 알림) $6 조치(한국어 — 코멘트)
triage_resume_record() {
  local n="$1" body tilde='~' prefix=""
  if [[ "$n" != 0 ]]; then
    prefix="#${n}: "
    body="**ticket-loop 무인 수습 — 이어 감**"$'\n\n'
    body+="- 멈춘 이유: ${2//"$HOME"/$tilde}"$'\n'
    body+="- 분류 \`$3\` — $4"$'\n'
    body+="- 조치: $6. 루프는 멈춘 자리에서 이어 갔다"$'\n'
    body+="- 머신 \`$(hostname -s 2>/dev/null || hostname)\`${STOP_RECORD:+ · 멈춤 기록 \`${STOP_RECORD#"$ROOT"/}\` (그 머신에만 있다)}"$'\n'
    gh issue comment "$n" --body "$body" </dev/null >/dev/null 2>&1 || log warn "#${n}: failed to post the triage record to GitHub"
  fi
  notify "Triage fixed it — loop continues" "${prefix}$4 ($5)" resumed
}

# 모든 종료가 지나는 길(EXIT). die와 정상 종료는 따로 처리했고, 그 밖의 비정상 종료 — set -e에 걸린 명령(네트워크가 끊겨 git fetch·gh가
# 실패하는 등) — 는 걸린 명령을 사유로 보고한다(trap 안의 BASH_COMMAND는 trap이 걸린 때의 명령이다). 잠금은 이 실행이 잡았을 때만 푼다
on_exit() {
  local rc=$? cmd="${BASH_COMMAND//$'\n'/ }"
  set +e
  if [[ $rc -ne 0 && $STOP_REPORTED -eq 0 ]]; then
    trap '' PIPE
    [[ ${#cmd} -le 200 ]] || cmd="${cmd:0:200}…"
    log err "ERROR: unexpected exit (status ${rc}) at: ${cmd}"
    STOP_KIND=unexpected_exit
    stop_report "${STOP_ISSUE:+#${STOP_ISSUE}: }unexpected exit (status ${rc}) at: ${cmd}"
  fi
  [[ $LOCK_HELD -eq 0 ]] || rmdir "$LOCK_DIR" 2>/dev/null
  [[ -z "${WAIT_STOP_FILE:-}" ]] || rm -f "$WAIT_STOP_FILE"
}

# 신호로 끝날 때 — 터미널 창을 닫음(HUP), Ctrl-C(INT), kill(TERM), 로그를 받던 tee가 죽은 뒤 stderr 쓰기(PIPE). bash는 신호에도 EXIT trap을
# 돌리지만 그 안의 $?가 0이라 정상 종료와 구별되지 않아 따로 잡는다. PIPE를 잡지 않으면 tee가 먼저 죽은 상태에서 log 한 줄에 루프가
# 141로 죽고 EXIT trap도 돌지 않아 보고 없이 잠금까지 남는다(실험으로 확인). 보고하는 동안은 PIPE를 무시한다 — 이 줄은 로그 파일에
# 못 남을 수 있지만 티켓 기록·GitHub·Slack에는 남는다. trap은 자식 프로세스에 이어지지 않아 파이프의 SIGPIPE 동작은 그대로다.
# kill -9·전원·잠자기는 잡을 수 없다
on_signal() {
  local sig="$1" why kind=stop
  trap '' PIPE; trap - HUP INT TERM
  set +e
  [[ -z "$BG_PID" ]] || kill_tree "$BG_PID"   # bg_wait로 기다리던 것(PR·CI 대기, 검증 명령)이 루프 없이 남지 않게
  case "$sig" in
    HUP)  why="terminal closed (SIGHUP)" ;;
    INT)  why="interrupted (Ctrl-C)"; kind=interrupt ;;
    PIPE) why="log output closed (SIGPIPE — terminal gone?)" ;;
    *)    why="terminated (SIG${sig})" ;;
  esac
  log err "ERROR: ${why}"
  STOP_KIND=signal
  stop_report "${STOP_ISSUE:+#${STOP_ISSUE}: }${why}" "$kind"
  case "$sig" in HUP) exit 129 ;; INT) exit 130 ;; PIPE) exit 141 ;; *) exit 143 ;; esac
}

# 오래 기다리는 일(PR 대기, CI 대기, 병합 뒤 검증·워크트리 준비 명령, 수리 중 idle 대기)은 백그라운드로 돌리고 wait로 기다린다.
# bash는 포그라운드 자식이 끝날 때까지 trap을 미룬다 — 0.8.8 실측(더미 저장소, cmux)에서 루프 pid에만 보낸 SIGHUP이 PR 대기
# 서브셸이 끝난 2분 뒤에야 처리됐다. wait는 신호를 받으면 바로 돌아와 on_signal이 돈다(터미널 창 닫힘·Ctrl-C는 프로세스 그룹
# 전체에 가서 원래도 됐지만, 다른 터미널의 `kill <루프 pid>`는 PR이 열릴 때까지 먹히지 않았다). 자식은 set +e로 돈다 —
# 전에 커맨드 치환으로 돌던 wait_for_pr와 같다(bash는 커맨드 치환에서 -e를 끈다). 종료 코드는 그대로 돌려준다
bg_wait() {
  local rc=0
  { set +e; "$@"; } &
  BG_PID=$!
  wait "$BG_PID" || rc=$?
  BG_PID=""
  return $rc
}
# 프로세스와 그 자손을 끝낸다(TERM). 자식 목록을 먼저 읽고 부모를 끝내 새 자식이 생기지 않게 한 뒤 자식으로 내려간다
kill_tree() {
  local kids k
  kids="$(pgrep -P "$1" 2>/dev/null || true)"
  kill "$1" 2>/dev/null || true
  for k in $kids; do kill_tree "$k"; done
}
# ----- 알림 · 멈춤 보고 끝 -----

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || die "${tool} is not installed."
done

# ---------- GitHub 일시 장애 ----------
# GitHub는 공지 없이 짧게 5xx·연결 오류를 낸다(이슈 #7: CI 통과 직후 병합 한 번이 502). 루프의 gh 읽기가 그 한 번을 그대로 받으면 멈추거나
# (set -e — 병합 뒤 브랜치 조회, 수리 전 head) 틀린 값으로 읽는다(빈 대상 목록 → "No more tickets"로 끝남). 호출마다 막는 대신 gh를 함수로
# 감싸 읽기 호출만 GH_TRIES번까지 다시 해 본다. 쓰기(병합·코멘트·라벨·이슈 닫기)는 다시 하지 않는다 — 응답만 실패하고 서버는 처리했을 수
# 있어 두 번 들어간다(병합은 merge_pr가 상태를 확인하며 따로 다시 한다). 오래 도는 --watch도 감싸지 않는다(ci_passed가 결과를 다시 읽는다).
# 도구 검사(command -v) 뒤에 둔다 — 함수가 먼저 있으면 gh가 없어도 검사를 통과한다
GH_TRANSIENT_RE='status code: 5[0-9]{2}|HTTP 5[0-9]{2}|bad gateway|service unavailable|gateway time-?out|timeout|timed out|something went wrong while executing your query|error connecting to|dial tcp|connection (reset|refused)|tls handshake|unexpected eof|no such host'
# 다시 해도 되는 gh 호출인가 — 조회 하위 명령, 메서드·필드 없는 REST api(필드가 있으면 POST다), mutation이 아닌 GraphQL
gh_read_only() {
  local a
  case "$1 ${2:-}" in
    "pr view"|"pr list"|"pr diff"|"issue view"|"issue list"|"repo view") ;;
    "pr checks") [[ " $* " != *" --watch "* ]] || return 1 ;;
    "api graphql") [[ "$*" != *mutation* ]] || return 1 ;;
    "api "*) for a in "$@"; do case "$a" in -X|--method|--method=*|-f|-F|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*) return 1 ;; esac; done ;;
    *) return 1 ;;
  esac
}
gh() {
  local out rc try errf pause
  gh_read_only "$@" || { command gh "$@"; return; }
  errf="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-gh.XXXXXX")"
  for (( try = 1; ; try++ )); do
    rc=0; out="$(command gh "$@" 2>"$errf")" || rc=$?
    if [[ $rc -eq 0 || $try -ge $GH_TRIES ]] || ! grep -Eqi "$GH_TRANSIENT_RE" "$errf"; then
      [[ -z "$out" ]] || printf '%s\n' "$out"
      cat "$errf" >&2; rm -f "$errf"
      return "$rc"
    fi
    pause=$(( try * GH_RETRY_SEC ))
    log warn "gh $1 ${2:-}: transient GitHub error (${try}/${GH_TRIES}) — retrying in ${pause}s ($(grep -m1 . "$errf"))"
    sleep "$pause"
  done
}
[[ -n "$AGENT_RESTART_CMD" && -n "$AGENT_BANNER_REGEX" ]] \
  || die "AGENT=${AGENT} has no preset (claude | codex). Set AGENT_RESTART_CMD and AGENT_BANNER_REGEX in .ticket-loop/loop.env."

ROOT="$(git rev-parse --show-toplevel)"
MAIN_WT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
# 루프는 저장소당 하나만 — 두 루프가 같은 티켓을 집지 않게 한다
LOCK_DIR="$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)/ticket-loop.lock"
# 아직 병합 뒤 검증을 거치지 않은 병합(POST_MERGE_EVERY) — 잠금처럼 .git 안이라 커밋되지 않고, 루프가 멈췄다 다시 실행돼도 이어진다
PM_STATE_FILE="${LOCK_DIR%/*}/ticket-loop-post-merge.json"
if [[ $DRY_RUN -eq 0 ]]; then
  # 멈춤은 어떻게 끝나든 한 번 보고한다(on_exit·on_signal). 잠금을 못 잡고 멈추면 on_exit는 잠금을 지우지 않는다(다른 루프의 것)
  trap on_exit EXIT; trap 'on_signal HUP' HUP; trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal PIPE' PIPE
  mkdir "$LOCK_DIR" 2>/dev/null || die "Another loop is running (${LOCK_DIR}). If no loop is running (pgrep -fl ticket-loop), remove that directory."
  LOCK_HELD=1
fi

OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
REPO_URL="$(gh repo view --json url -q .url 2>/dev/null || true)"   # Slack 본문의 #N 링크(GitHub Enterprise도 맞게)
[[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"

# ---------- GitHub 조회 ----------

# 조회 넷(blocked_by·sub_issue_count·open_pr_for·candidates)은 gh가 실패하면(GH_TRIES번 재시도 뒤에도) 출력 없이 비0으로 끝난다 — 실패를
# "선행 이슈 0개"·"PR 없음"·"빈 목록"으로 읽어 막힌 티켓을 시작하거나 "No more tickets"로 끝나지 않게(이슈 #8). 출력을 변수에 먼저 받는다 —
# 파이프 뒤의 awk·jq가 종료 코드를 덮지 않게
# 열린 선행 이슈 수. issue_dependencies_summary.blocked_by는 선행 이슈가 닫힌 뒤에도
# 최대 ~20분 옛 값을 돌려준 실측이 있어, 목록에서 열린 것만 센다.
# 예외 하나: 일시 장애가 아닌 404(Not Found)는 이슈 의존성 API가 없는 환경(옛 GHES)이다 — 조회 실패가 아니라 "막힘 없음"(0)으로 보고 실행당
# 한 번만 경고한다. 그 밖(재시도 뒤의 5xx·연결 오류·401·403)은 비0. 경고 여부는 변수가 아니라 표시 파일이다 — blocked_by는 명령 치환(서브셸)
# 안에서 불리므로 변수는 후보 사이에 남지 않는다. 파일이 비어 있으면 아직 경고하지 않은 것
BLOCKED_BY_UNAVAILABLE_WARNED="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-blocked-by-404.XXXXXX")"
blocked_by() {
  local counts errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-blocked.XXXXXX")"
  counts="$(gh api "repos/${OWNER_REPO}/issues/$1/dependencies/blocked_by" --paginate \
    --jq '[.[] | select(.state == "open")] | length' 2>"$errf")" || rc=$?
  if [[ $rc -ne 0 ]] && grep -Eqi 'HTTP 404|Not Found' "$errf"; then
    rm -f "$errf"
    [[ -s "$BLOCKED_BY_UNAVAILABLE_WARNED" ]] || { log warn "dependencies API not available (HTTP 404) — treating tickets as not blocked"; echo 1 > "$BLOCKED_BY_UNAVAILABLE_WARNED"; }
    echo 0; return 0
  fi
  cat "$errf" >&2; rm -f "$errf"   # gh 래퍼의 재시도 경고·마지막 오류는 그대로 보인다
  [[ $rc -eq 0 ]] || return 1
  awk '{s += $1} END {print s + 0}' <<<"$counts"
}

# 하위 이슈 수 — 스펙 이슈(/to-spec이 ready-for-agent를 붙인다)를 티켓처럼 집지 않게 한다
sub_issue_count() {
  local total
  total="$(gh api "repos/${OWNER_REPO}/issues/$1" --jq '.sub_issues_summary.total // 0')" || return 1
  printf '%s\n' "$total"
}

# 스펙 $1의 하위 이슈 — 모든 상태, 페이지를 합친 JSON 배열 [{number, state, labels: [이름]}]. 조회 실패면 출력 없이 비0
spec_sub_issues() {
  local pages
  pages="$(gh api "repos/${OWNER_REPO}/issues/$1/sub_issues" --paginate --jq '[.[] | {number, state, labels: [.labels[].name]}]')" || return 1
  jq -sc 'add // []' <<<"$pages"
}

# 티켓 사이의 대상 조회가 재확인까지 빈 목록(후보 0행)일 때 스펙 $1과 맞춰 본다(pick_next_targets, #22). 빈 목록이 맞으면 출력 없이 0, 믿을 수
# 없으면 그 이유 한 줄을 내고 0, 조회 실패면 출력 없이 비0. 스펙 요약(sub_issues_summary — 목록과 다른 끝점 issues/N)에 열린 하위 이슈가 남아
# 있을 때만 의심하고, 그때 (a) sub_issues 끝점이 요약의 total보다 적게 돌려줬거나(빈·부분 응답), (b) 돌려준 것 가운데 열려 있고
# READY_LABEL(+SCOPE_LABEL)이 붙고 IN_REVIEW_LABEL이 없는 것이 있으면(그것은 issue list에 있었어야 한다 — 막혔거나 담당자·PR이 있어도 skip 줄로
# 남지 0행이 되지 않는다) 믿지 않는다. 열린 하위 이슈가 전부 ready 라벨이 없거나(needs-info·ready-for-human …) in-review면 빈 목록이
# 맞다 — 요약의 열린 수만 보면 그런 스펙은 끝에 늘 멈춤으로 끝나고 루프 끝 검증도 건너뛴다
spec_empty_list_check() {
  local summary kids total completed
  summary="$(gh api "repos/${OWNER_REPO}/issues/$1" --jq '"\(.sub_issues_summary.total // 0) \(.sub_issues_summary.completed // 0)"')" || return 1
  read -r total completed <<<"$summary"
  [[ "${total:-}" =~ ^[0-9]+$ && "${completed:-}" =~ ^[0-9]+$ ]] || return 1
  [[ $(( total - completed )) -gt 0 ]] || return 0
  kids="$(spec_sub_issues "$1")" || return 1
  jq -r --argjson total "$total" --argjson open "$(( total - completed ))" --arg spec "$1" --arg ready "$READY_LABEL" --arg scope "$SCOPE_LABEL" --arg rv "$IN_REVIEW_LABEL" '
      if length < $total then "the sub_issues lookup returned \(length) of \($total) sub-issues of spec #\($spec) (\($open) open)"
      else (map(select(.state == "open" and (.labels | index($ready)) != null and ($scope == "" or (.labels | index($scope)) != null)
                       and (.labels | index($rv)) == null)) | length) as $n
        | if $n > 0 then "spec #\($spec) has \($n) open \($ready) sub-issue\(if $n == 1 then "" else "s" end) the lookup did not return" else empty end
      end' <<<"$kids"
}

# 티켓 N의 열린 PR — head 브랜치가 `<BRANCH_PREFIX>N`과 같거나 `<BRANCH_PREFIX>N-`로 시작하는 것.
# 워커는 implement 스킬대로 issue-N-<slug>를 만들지만, 루프가 만든 워크트리 브랜치 issue-N에 그대로 커밋해 PR을 연 실측이 있다
# (rental-portal #102 → PR #120, 0.8.5). 접두 `N-`만 보면 그 PR을 못 찾아 "PR 없이 멈춤"으로 죽었다.
# `N`만 접두로 보면 issue-1020이 #102에 걸리므로 정확히 같거나 `N-`로 시작할 때만이다
open_pr_for() {
  local prs
  prs="$(gh pr list --state open --json number,headRefName)" || return 1
  jq -r --arg b "${BRANCH_PREFIX}$1" 'map(select(.headRefName == $b or (.headRefName | startswith($b + "-")))) | .[0].number // empty' <<<"$prs"
}

issue_title() { gh issue view "$1" --json title -q .title; }
issue_has_label() { gh issue view "$1" --json labels -q '.labels[].name' 2>/dev/null | grep -Fxq -- "$2"; }
# GitHub 시각(ISO 8601, UTC) → epoch. macOS·Linux의 date 차이를 피해 jq로. 못 읽으면 빈 값
iso_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdate' 2>/dev/null || true; }
pr_created_epoch() { iso_epoch "$(gh pr view "$1" --json createdAt -q .createdAt 2>/dev/null || true)"; }

candidates() {
  # READY_LABEL(+SCOPE_LABEL)(+PARENT의 하위 이슈), IN_REVIEW_LABEL 없음, 제목 순번 → 이슈 번호 순
  local list kids
  local args=(--label "$READY_LABEL" --state open --limit 200 --json number,title,labels,assignees)
  [[ -z "$SCOPE_LABEL" ]] || args+=(--label "$SCOPE_LABEL")
  list="$(gh issue list "${args[@]}")" || return 1
  if [[ -n "$PARENT" ]]; then
    kids="$(spec_sub_issues "$PARENT")" || return 1
    list="$(jq --argjson kids "$(jq -c 'map(.number)' <<<"$kids")" 'map(select(.number as $n | $kids | index($n)))' <<<"$list")"
  fi
  jq -r --arg re "$ORDER_REGEX" --arg rv "$IN_REVIEW_LABEL" '
      map(select((.labels | map(.name) | index($rv)) == null))
      | map(. + {o: ([.title | capture($re) | .n] | first)})
      | sort_by([(if .o then 0 else 1 end), ((.o // .number) | tonumber)])
      | .[] | "\(.number)\t\(.assignees | length)\t\(.title)"' <<<"$list"
}

# 대상 목록("번호<TAB>제목" 줄들). 목록 조회(candidates)가 실패하면 1 — 부르는 쪽이 정한다(시작 전이면 die, 티켓 사이면 PICK_RETRY_SEC 동안
# 다시, pm_due는 검증을 미룬다). 조회가 성공했는데 후보가 0행이면 2(목록은 비어 있다) — 후보가 있었지만 모두 걸러진 빈 목록(0, skip 줄이 남는다)과
# 구분한다. 성공한 빈 응답이 "남은 티켓 없음"으로 읽힌 실측이 있어(#22) 티켓 사이에는 pick_next_targets가 한 번 더 확인한다.
# 후보 하나의 검사(sub_issue_count·blocked_by·open_pr_for)가 실패하면 그 티켓만 고르지 않는다 — 막혔거나
# PR이 열렸을 수 있으니 안전한 쪽으로. 명령 치환 안에서 돌므로(set -e 없음) 실패는 종료 코드로만 알 수 있다
pick_targets() {
  if [[ ${#TICKETS[@]} -gt 0 ]]; then
    for n in "${TICKETS[@]}"; do printf '%s\t%s\n' "${n}" "$(issue_title "${n}")"; done
    return
  fi
  local n assignees title list subs blocked pr
  list="$(candidates)" || return 1
  [[ -n "$list" ]] || { log "ticket lookup returned 0 candidates"; return 2; }
  while IFS=$'\t' read -r n assignees title; do
    [[ -n "${n}" ]] || continue
    if [[ "${assignees}" != "0" ]]; then log "skip #${n} (${title}): has an assignee (in progress or taken by a person)"; continue; fi
    subs="$(sub_issue_count "${n}")" || { log "skip #${n} (${title}): could not check (GitHub)"; continue; }
    if [[ "$subs" != "0" ]]; then log "skip #${n} (${title}): spec issue with sub-issues"; continue; fi
    blocked="$(blocked_by "${n}")" || { log "skip #${n} (${title}): could not check (GitHub)"; continue; }
    if [[ "$blocked" != "0" ]]; then log "skip #${n} (${title}): blocked by an open issue"; continue; fi
    pr="$(open_pr_for "${n}")" || { log "skip #${n} (${title}): could not check (GitHub)"; continue; }
    if [[ -n "$pr" ]]; then log "skip #${n} (${title}): PR already open"; continue; fi
    printf '%s\t%s\n' "${n}" "${title}"
  done <<<"$list"
}

# 티켓 사이의 다음 대상 — pick_targets에 빈 목록 재확인을 더한 것(이슈 #22). 조회가 성공하면서 후보 0행이면(skip 줄 하나 없이 빈 목록) GitHub가
# 성공한 빈 응답을 돌려준 것일 수 있다 — 실측(0.9.12, --parent 313): 열린 하위 이슈 12건을 두고 issue list나 sub_issues가 빈 값을 줘 pm_due가
# "no more tickets"로 병합 뒤 검증을 앞당겼다. 같은 경로가 메인 고리에서 나면 티켓을 남기고 정상 종료한다. 그래서 0행이면 PICK_RECHECK_SEC
# 쉬고 한 번 더 조회하고, 두 번째도 0행이면 그때 빈 목록으로 확정한다. --parent면 스펙과 맞춰 봐서(spec_empty_list_check — 다른 끝점의 요약과
# 하위 이슈의 상태·라벨) 빈 목록이 말이 안 되면 믿지 않는다. 후보가 있었지만 모두 걸러진(막힘·담당자·PR) 빈 목록은 재확인 없이 그대로다 — 스펙
# 끝의 정상 경로. 시작 전 첫 계산은 사람이 앞에 있으니 pick_targets 그대로다.
# 반환 0 목록(비어 있을 수 있다), 1 조회 실패(어느 조회든), 2 두 번 다 0행인데 스펙 #PARENT에 열린 하위 이슈가 남음 — 부르는 쪽(pm_due는 미룸,
# 메인 고리는 PICK_RETRY_SEC 동안 다시 해 본 뒤 멈춤)이 정한다. 명령 치환 안에서 돌므로 로그는 남기되 변수는 돌려주지 못한다
pick_next_targets() {
  local list rc=0 why
  list="$(pick_targets)" || rc=$?
  [[ $rc -eq 2 ]] || { printf '%s' "$list"; return $rc; }   # 목록(0)이나 조회 실패(1, 출력 없음)는 그대로
  log "empty ticket list — re-checking in ${PICK_RECHECK_SEC}s"
  sleep "$PICK_RECHECK_SEC"
  rc=0; list="$(pick_targets)" || rc=$?
  [[ $rc -eq 2 ]] || { printf '%s' "$list"; return $rc; }
  [[ -n "$PARENT" ]] || return 0
  why="$(spec_empty_list_check "$PARENT")" || return 1
  [[ -n "$why" ]] || return 0
  log warn "ticket list empty but ${why} — not trusting it"
  return 2
}

# ---------- 백엔드 ----------
# 루프가 워크트리·에이전트 터미널에 대해 하는 일은 아래 아홉 가지뿐이다. 백엔드마다 같은 이름의 함수(<backend>_*)를 구현하고
# BACKEND로 고른다. 티켓 선택·PR·CI·수리·병합·병합 뒤 검증·기록·리포트는 백엔드와 무관하게 한 벌이다.
#   _check                       시작 때 한 번: CLI가 있고 앱에 닿는지, 저장소가 등록돼 있는지
#   _worktree_create N PROMPT [NAME]  기본 브랜치에서 워크트리를 만들고 에이전트를 띄운다. 전역 WT(백엔드의 워크트리/워크스페이스 id),
#                                WT_PATH, WT_BRANCH(백엔드가 만든 브랜치 — 워커가 바꾸기 전 이름), HANDLE(에이전트 터미널)을 채운다.
#                                NAME(워크트리·브랜치 이름)은 기본 <BRANCH_PREFIX>N — 무인 수습 세션은 loop-triage-N-<시각>을 준다
#   _worktree_remove WT WT_PATH  워크트리를 지운다(브랜치 정리는 공통부가 한다)
#   _send HANDLE TEXT            프롬프트 한 줄을 에이전트 입력에 넣고 제출한다. 수락되지 않으면 비0
#   _type HANDLE TEXT            셸 명령 한 줄을 입력하고 Enter(에이전트 재기동용 — 에이전트 입력 검사 없이)
#   _interrupt HANDLE            Ctrl-C
#   _wait_idle HANDLE MS         반환 0: idle 확인, 1: 타임아웃(아직 작업 중), 3: 터미널에 닿지 못함(앱 종료 등)
#   _tail HANDLE                 화면 마지막 25줄
#   _set_status WT STATUS [PR] [COMMENT]   STATUS: in-progress | in-review | todo(확인 필요) | completed. 실패해도 루프는 간다
backend_check()           { "${BACKEND}_check" "$@"; }
backend_worktree_create() { "${BACKEND}_worktree_create" "$@"; }
backend_worktree_remove() { "${BACKEND}_worktree_remove" "$@"; }
backend_send()            { "${BACKEND}_send" "$@"; }
backend_type()            { "${BACKEND}_type" "$@"; }
backend_interrupt()       { "${BACKEND}_interrupt" "$@"; }
backend_wait_idle()       { "${BACKEND}_wait_idle" "$@"; }
backend_tail()            { "${BACKEND}_tail" "$@"; }
backend_set_status()      { "${BACKEND}_set_status" "$@"; }
case "$BACKEND" in orca) BACKEND_NAME=Orca ;; cmux|tmux) BACKEND_NAME="$BACKEND" ;; *) die "Unknown BACKEND=${BACKEND} (orca | cmux | tmux)." ;; esac

# 프롬프트를 셸 명령 인자로 넘길 때는 파일을 거친다(따옴표·백틱이 섞여도 안전). 파일은 티켓이 끝나도 지우지 않는다(디버그용, tmp)
prompt_file() { local f; f="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-prompt-$1.XXXXXX")"; printf '%s' "$2" > "$f"; printf '%s' "$f"; }
agent_launch_cmd() { printf '%s "$(cat %q)"' "$AGENT_RESTART_CMD" "$1"; }   # 셸이 해석할 한 줄: claude|codex … "$(cat /tmp/…)"

# ----- Orca: 워크트리·터미널·idle 대기를 모두 Orca CLI가 한다 -----

orca_json() { "$ORCA_CLI" "$@" --json; }

orca_check() {
  command -v "$ORCA_CLI" >/dev/null 2>&1 || die "Orca CLI (${ORCA_CLI}) not found (Orca Settings → General → Orca CLI)."
  # canonicalKey는 보통 github.com/<owner>/<repo>지만, SSH 별칭 호스트(~/.ssh/config의 github.com-<계정>)를 쓰면
  # github.com-<계정>/<owner>/<repo>가 된다(2026-10-12 실측). 호스트는 보지 않고 /<owner>/<repo>로 끝나는지만 본다
  REPO_ID="$("$ORCA_CLI" repo list --json \
    | jq -r --arg suffix "/${OWNER_REPO}" \
        '.result.repos[] | select((.gitRemoteIdentity.canonicalKey // "") | endswith($suffix)) | .id' | head -n1)"
  [[ -n "$REPO_ID" ]] || die "Repository ${OWNER_REPO} is not registered in Orca. Register it with '${ORCA_CLI} repo add --path ${ROOT} --json'."
  # --surface가 없으면 에이전트가 Orca 앱의 Chat UI 설정을 따라 채팅으로 뜰 수 있다 — 루프는 터미널로만 몬다(#41).
  # CLI가 그 플래그를 알고(도움말) 실행 중인 앱(호스트)도 받을 때만 넘긴다. 자동 업데이트로 번들 CLI만 새것이고 앱은 재시작 전이면
  # 호스트가 --surface를 incompatible_runtime으로 거절한다. 못 넘긴 채 채팅으로 뜨면 orca_worktree_create의 outcome.kind 검사가 멈춘다
  ORCA_SURFACE_ARGS=()
  if "$ORCA_CLI" worktree create --help 2>/dev/null | grep -q -- '--surface' \
    && orca_json status 2>/dev/null | jq -e '.result.runtime.capabilities // [] | index("agent.launch.surface.v1")' >/dev/null 2>&1; then
    ORCA_SURFACE_ARGS=(--surface terminal)
  fi
}

orca_worktree_create() {
  local n="$1" prompt="$2" name="${3:-${BRANCH_PREFIX}${1}}" comment created kind delivered
  comment="티켓 루프: ${SKILL_PREFIX}implement ${n} 진행 중"
  [[ "$name" == "${BRANCH_PREFIX}${n}" ]] || comment="티켓 루프: 무인 수습 (#${n})"
  created="$(orca_json worktree create --repo "id:$REPO_ID" --name "$name" --no-parent \
    --base-branch "origin/${BASE_BRANCH}" --issue "${n}" --agent "$AGENT" ${ORCA_SURFACE_ARGS[@]+"${ORCA_SURFACE_ARGS[@]}"} \
    --prompt "$prompt" --comment "$comment")"
  jq -e '.ok == true' <<<"$created" >/dev/null || die "Worktree creation failed: $(jq -c '.error' <<<"$created")"
  # Orca 1.4.244부터 호스트가 agent.launch.v2를 알리면 CLI가 agent.launch로 띄우고 결과를 result.launch에 싣는다(#41) —
  # 핸들은 launch.outcome.handle, 워크트리 id는 launch.worktreeId에도 있다. result.worktree는 시작 뒤 worktree.show로 채우는데
  # 그게 실패하면 결과에서 빠진다. result.agentTerminalHandle은 그보다 낡은 호스트의 모양이다(2026-10-30 rsrehab/detection-tslite 실측)
  WT="$(jq -r '.result.worktree.id // .result.launch.worktreeId // empty' <<<"$created")"
  [[ -n "$WT" ]] || die "Worktree creation returned no worktree id: $(jq -c '.result | keys' <<<"$created")"
  WT_PATH="${WT#*::}"
  kind="$(jq -r '.result.launch.outcome.kind // empty' <<<"$created")"
  [[ "$kind" != structured ]] || die "The agent started as a chat, not a terminal (${WT}) — turn off Chat UI in Orca settings, or update Orca so the loop can pass --surface terminal"
  HANDLE="$(jq -r '.result.launch.outcome.handle // .result.agentTerminalHandle // .result.startupTerminal.handle // empty' <<<"$created")"
  [[ -n "${HANDLE}" ]] || die "No agent terminal handle returned (${WT})"
  # 프롬프트가 도착하지 않았어도 멈추지 않는다 — 워커가 PR 없이 idle이 되면 그 경로(무인 수습)가 잡는다. 사유는 여기 남긴다
  delivered="$(jq -r '.result.launch.prompt.outcome // empty' <<<"$created")"
  case "$delivered" in ""|journaled|handed-to-terminal) ;; *) log warn "#${n}: Orca reports the prompt as '${delivered}' — the agent may not have received it" ;; esac
  # Orca가 워크트리용으로 만든 브랜치(설정에 따라 `issue-N` 또는 `<git 사용자>/issue-N`) — 워커가 브랜치를 바꾸기 전에 기록한다
  WT_BRANCH="$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
}

orca_worktree_remove() { orca_json worktree rm --worktree "id:$1" --force >/dev/null; }

orca_send() {
  orca_json terminal send --terminal "$1" --text "$2" --enter --wait-submit 15 \
    | jq -e '.result.send.accepted == true' >/dev/null
}
orca_type()      { orca_json terminal send --terminal "$1" --text "$2" --enter >/dev/null; }
orca_interrupt() { orca_json terminal send --terminal "$1" --text $'\x03' >/dev/null; }

orca_wait_idle() {
  # `orca terminal wait`는 타임아웃이면 {ok:false, error.code:"timeout"}과 함께 exit 1을 돌려준다(Orca 1.4.223 실측).
  # exit 코드만 보면 "닿지 못함"으로 오판해 일하는 워커를 두고 루프가 죽는다 — JSON으로 가른다.
  # 그 밖의 응답(빈 출력·다른 error.code)은 한 번으로 "닿지 못함"이라 판정하지 않는다. 사람이 Orca 앱에서 워커
  # 워크트리를 열면 세션이 다시 붙으며(데몬 로그 session-attached) 기다리던 wait가 그렇게 끝난다 — 2026-10-12 #72
  # (Orca 1.4.224)에서 일하던 워커를 두고 루프가 죽었다. 터미널을 읽을 수 있으면 아직 작업 중(1)으로 보고,
  # TERMINAL_RETRY번 연달아 읽지도 못할 때만 3이다. 터미널이 사라지면 read가 ok:false(terminal_handle_stale)다.
  local out code i
  out="$(orca_json terminal wait --terminal "$1" --for tui-idle --timeout-ms "$2" 2>/dev/null)" || true
  jq -e '.result.wait.satisfied == true' <<<"$out" >/dev/null 2>&1 && return 0
  code="$(jq -r '.error.code // empty' <<<"$out" 2>/dev/null)"
  [[ "$code" == "timeout" ]] && return 1
  for i in $(seq 1 "$TERMINAL_RETRY"); do
    sleep "$TERMINAL_RETRY_SEC"
    if orca_json terminal read --terminal "$1" 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then
      log warn "terminal $1: unexpected wait response (${code:-empty output}) — terminal is alive, keep waiting"
      return 1
    fi
  done
  return 3
}

orca_tail() { orca_json terminal read --terminal "$1" | jq -r '.result.terminal.tail[]?' | tail -n 25; }

orca_set_status() {
  # local 한 문장 안에서 선언한 변수를 같은 문장에서 쓰면 set -u 에 걸린다(2026-10-12 boiler-webapp #34 실측) — 줄을 나눈다
  local wt="$1" status="$2" pr="${3:-}" comment="${4:-}"
  local args=(--worktree "id:${wt}" --workspace-status "$status")
  [[ -z "$pr" ]] || args+=(--pr "$pr")
  [[ -z "$comment" ]] || args+=(--comment "$comment")
  [[ "$status" != "todo" ]] || args+=(--unread)
  orca_json worktree set "${args[@]}" >/dev/null
}

# ----- cmux·tmux 공통 -----
# Claude Code는 새 워크트리에서 "이 폴더를 신뢰하나" 대화상자를 띄우는데, 그 판정은 메인 체크아웃 경로로 한다(2026-10-13 실측:
# 메인 체크아웃이 ~/.claude.json projects에 없던 더미 저장소에서 대화상자가 떴고, 수락하면 메인 체크아웃 경로가 trust=true로 기록됐다.
# boiler-webapp cmux 실측에서 안 뜬 것은 메인 체크아웃을 이미 신뢰했기 때문). 대화상자가 떠 있으면 훅도 프롬프트도 돌지 않으니
# 시작 때 막는다. Orca는 워크스페이스마다 신뢰를 기록해 주므로 여기서 보지 않는다
claude_trust_check() {
  [[ "$AGENT" == claude ]] || return 0
  local cfg="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}" trusted
  cfg="${cfg:-$HOME/.claude.json}"
  [[ -f "$cfg" ]] || return 0
  trusted="$(jq -r --arg p "$MAIN_WT" '.projects[$p].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" || return 0
  [[ "$trusted" == true ]] \
    || die "Claude Code does not trust ${MAIN_WT} yet — workers would stall at the trust dialog in a new worktree. Open claude once in the main checkout and choose 'Yes, I trust this folder'."
}

# 워크트리는 루프가 git으로 만든다 (Orca는 orca worktree create가 한다)
# WT_PATH·WT_BRANCH를 채운다. 백엔드는 그 위에 에이전트 터미널을 연다. $2 이름(기본 <BRANCH_PREFIX>N)
# 워커 워크트리의 준비(WORKTREE_SETUP_CMD)가 실패하면 수습 세션을 띄워 본다 — 고쳐지면 워크트리를 기본 브랜치로 당겨 준비를 다시 돌리고,
# 아니면 멈춘다. 수습 세션 자신의 워크트리는 준비가 실패해도 띄운다(그 실패를 수습 세션이 직접 본다)
loop_worktree_add() {
  local n="$1" name="${2:-${BRANCH_PREFIX}${1}}" path reason
  path="${WORKTREE_DIR}/${name}"
  [[ ! -e "$path" ]] || die "Worktree path already exists: ${path} (if left over from a previous run, 'git worktree remove --force' it and retry)"
  mkdir -p "$WORKTREE_DIR"
  git -C "$ROOT" branch -D "$name" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree add -q -b "$name" "$path" "origin/${BASE_BRANCH}" || die "git worktree add failed (${path})"
  if [[ -n "$WORKTREE_SETUP_CMD" ]]; then
    log step "#${n}: worktree setup — ${WORKTREE_SETUP_CMD}"
    while ! bg_wait env LOOP_ROOT_PATH="$MAIN_WT" LOOP_WORKTREE_PATH="$path" bash -c 'cd "$1" && exec bash -c "$2"' _ "$path" "$WORKTREE_SETUP_CMD"; do
      reason="#${n}: WORKTREE_SETUP_CMD failed (${path})"
      if [[ "$name" != "${BRANCH_PREFIX}${n}" ]]; then log warn "${reason} — starting the session anyway"; break; fi
      STOP_KIND=setup_failed
      triage setup_failed "$reason" || die "${reason}${TRIAGE_NOTE}"
      git -C "$path" merge --ff-only -q "origin/${BASE_BRANCH}" \
        || die "#${n}: could not fast-forward the worktree to origin/${BASE_BRANCH} after the triage fix (${path})"
      log step "#${n}: worktree setup again after triage — ${WORKTREE_SETUP_CMD}"
    done
  fi
  WT_PATH="$path"
  WT_BRANCH="$name"
}

# ----- cmux: 워크트리는 루프가 git으로 만들고, 터미널은 cmux 워크스페이스다 (cmux 0.65 실측) -----
# cmux에는 워크트리 생성 명령도, idle까지 블로킹하는 명령도 없다. 그래서
#   - `git worktree add` 뒤 WORKTREE_SETUP_CMD(orca.yaml setup에 해당)를 돌리고 `cmux workspace create --cwd … --command "<AGENT_RESTART_CMD> …"`
#     --command는 워크스페이스의 로그인 셸(zsh)이 실행하고, 그 셸의 PATH 앞에 cmux의 에이전트 shim(claude·codex)이 있어 lifecycle 훅이 자동으로 붙는다
#   - idle은 `cmux rpc surface.input_state`가 돌려주는 lifecycle(running | idle | needsInput | unknown — 에이전트 훅이 보고. Claude Code 실측,
#     Codex는 shim이 같은 훅을 주입하지만 아직 실측 전)을
#     IDLE_POLL_SEC마다 읽어 판정한다. 이벤트 스트림(`cmux events`)의 이름에 기대지 않는다
#   - 소켓 모드가 cmuxOnly(기본)면 cmux 터미널 밖에서는 "액세스 거부"다. 루프를 cmux 터미널 안에서 돌린다
#   - 백그라운드 idle 에이전트를 하이버네이션할 수 있어, 프롬프트를 보내기 전에 깨운다
# 실측한 것: `--json`은 명령 뒤에 둬야 JSON이 나온다(앞에 두면 "OK workspace:N" 한 줄). `workspace create --json --id-format uuids`는
# {workspace_id, surface_id, window_id, group_id}. `workspace status set`의 lane은 todo|working|needs-attention|review|done|auto.
# `workspace close`는 프로세스가 살아 있으면 --force 없이 거부한다. 옛 이름(new-workspace 등)은 deprecation 한 줄을 찍으니 쓰지 않는다.

cmux_j() { CMUX_QUIET=1 "$CMUX_CLI" "$@" --json; }

cmux_check() {
  [[ -x "$CMUX_CLI" ]] || command -v "$CMUX_CLI" >/dev/null 2>&1 || die "cmux CLI (${CMUX_CLI}) not found (set CMUX_CLI=<path>)."
  "$CMUX_CLI" identify --json >/dev/null 2>&1 \
    || die "Cannot reach the cmux socket. Run inside a cmux terminal or change the socket mode ('${CMUX_CLI} socket-status --json')."
  [[ -n "$WORKTREE_DIR" ]] || WORKTREE_DIR="$HOME/.cache/ticket-loop/${OWNER_REPO//\//-}/worktrees"
  claude_trust_check
}

cmux_worktree_create() {
  local n="$1" prompt="$2" name="${3:-${BRANCH_PREFIX}${1}}" out pf
  loop_worktree_add "$n" "$name"
  pf="$(prompt_file "$n" "$prompt")"
  out="$(cmux_j workspace create --name "$name" --cwd "$WT_PATH" --focus false --id-format uuids \
           --command "$(agent_launch_cmd "$pf")" 2>/dev/null)" || die "cmux workspace create failed"
  WT="$(jq -r '.workspace_id // empty' <<<"$out" 2>/dev/null || true)"
  HANDLE="$(jq -r '.surface_id // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$WT" && -n "$HANDLE" ]] || die "workspace_id/surface_id missing from cmux workspace create response: ${out}"
}

cmux_worktree_remove() {
  # 에이전트 프로세스가 살아 있는 워크스페이스라 --force가 필요하다(없으면 confirmation_required로 거부)
  CMUX_QUIET=1 "$CMUX_CLI" workspace close "$1" --force >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$2"
}

# 붙여 넣은 뒤 lifecycle이 직전 턴의 idle에서 벗어나는지 SEND_ACCEPT_SEC 동안 본다(tmux의 sent→running 확인과 같은 뜻). 붙여 넣은
# 직후에는 cmux가 아직 새 턴을 몰라 직전 턴의 idle을 그대로 돌려준다 — 0.9.2까지는 확인 없이 돌아와, 수리 프롬프트 직후의 묵은 idle을
# 수리 끝으로 읽었다(2026-10-20 rental-portal #251: 수리 요청 5초 뒤 "no new commit"으로 멈췄고, 워커는 2분 뒤 수리 커밋을 push했다).
# running이면 수락이다. 빈 값·unknown은 판정할 수 없지만 cmux_wait_idle이 그 값을 idle로 읽지 않으니 넘어간다. 끝까지 idle이면 화면으로
# 가른다 — 붙여 넣은 프롬프트가 화면에 찍혔으면 들어간 것으로 보고(훅 보고가 늦은 경우, 남은 묵은 idle은 repair가 거른다), 화면도
# 그대로면 비0이다
cmux_send() {
  local handle="$1" i before
  "$CMUX_CLI" agent-hibernation wake "$handle" >/dev/null 2>&1 || true
  before="$(cmux_tail "$handle" 2>/dev/null | cksum)" || before=""
  # paste --submit: 한 줄을 붙여 넣고 제출. 에이전트 입력에 초안이나 대화상자가 있으면 거부(비0)한다 — 사람이 끼어든 것이니 보내지 않는다
  "$CMUX_CLI" paste --surface "$handle" --submit "$2" >/dev/null || return 1
  for (( i = 0; i < SEND_ACCEPT_SEC * 2; i++ )); do
    case "$(cmux_lifecycle "$handle")" in idle|needsInput) ;; *) return 0 ;; esac
    sleep 0.5
  done
  [[ -z "$before" || "$(cmux_tail "$handle" 2>/dev/null | cksum)" != "$before" ]]
}
cmux_type()      { "$CMUX_CLI" send --surface "$1" --force "$2" >/dev/null && "$CMUX_CLI" send-key --surface "$1" enter >/dev/null; }
cmux_interrupt() { "$CMUX_CLI" send-key --surface "$1" ctrl+c >/dev/null; }

cmux_lifecycle() {   # running | idle | needsInput | unknown, 소켓에 닿지 못하면 빈 값
  "$CMUX_CLI" rpc surface.input_state "{\"surface_id\":\"$1\"}" 2>/dev/null | jq -r '.lifecycle // empty' 2>/dev/null || true
}

cmux_alive() { "$CMUX_CLI" read-screen --surface "$1" --lines 1 >/dev/null 2>&1; }   # 서피스가 없으면 not_found(비0), 소켓이 죽어도 비0

cmux_wait_idle() {
  # lifecycle이 빈 값으로 오는 것(rpc 실패·훅 보고 공백)을 연달아 몇 번 봤다고 "닿지 못함"이라 판정하지 않는다 — 2026-10-14
  # rental-portal #100(cmux 0.65)에서 워커가 ticket-review 서브에이전트 2개와 헤드리스 브라우저를 돌리는 동안 빈 값이 5번(25초)
  # 이어져 일하던 워커를 두고 루프가 죽었다. 앱은 켜져 있었고 서피스도 살아 있었으며 워커는 혼자 PR까지 마쳤다. Orca의 #72와
  # 같은 규칙: 화면을 읽을 수 있으면 아직 작업 중으로 보고, TERMINAL_RETRY번 연달아 화면도 못 읽을 때만 3이다(그 사이 TERMINAL_RETRY_SEC씩 쉰다).
  local handle="$1" deadline_ms=$(( $(date +%s) * 1000 + $2 )) lc fails=0 warned=0
  while :; do
    lc="$(cmux_lifecycle "$handle")"
    case "$lc" in
      idle|needsInput) return 0 ;;    # needsInput: 질문·권한 대화상자 — 공통부가 PR 유무와 화면으로 "멈춤"을 가른다
      running|unknown) fails=0; warned=0 ;;
      *)
        if cmux_alive "$handle"; then
          fails=0
          [[ $warned -eq 1 ]] || { log warn "terminal ${handle}: empty lifecycle — screen is readable, keep waiting"; warned=1; }
        else
          fails=$((fails + 1)); [[ $fails -lt $TERMINAL_RETRY ]] || return 3
          sleep "$TERMINAL_RETRY_SEC"
        fi ;;
    esac
    [[ $(( $(date +%s) * 1000 )) -lt $deadline_ms ]] || return 1
    sleep "$IDLE_POLL_SEC"
  done
}

cmux_tail() { "$CMUX_CLI" read-screen --surface "$1" --lines 25; }

cmux_set_status() {
  local wt="$1" status="$2" pr="${3:-}" comment="${4:-}" lane
  case "$status" in in-progress) lane=working ;; in-review) lane=review ;; completed) lane=done ;; *) lane=todo ;; esac
  "$CMUX_CLI" workspace status set "$lane" --workspace "$wt" >/dev/null 2>&1 || true
  [[ -z "$pr" ]] || "$CMUX_CLI" pr "$pr" --workspace "$wt" >/dev/null 2>&1 || true
  [[ -z "$comment" ]] || "$CMUX_CLI" log --workspace "$wt" "$comment" >/dev/null 2>&1 || true
}

# ----- tmux: 워크트리는 루프가 git으로 만들고, 터미널은 tmux 창이다. idle은 에이전트 훅이 파일에 쓴다 -----
# tmux는 에이전트를 모른다(Orca의 tui-idle, cmux의 lifecycle 같은 신호가 없다). 그래서
#   - 워크트리는 cmux와 같이 `git worktree add` + WORKTREE_SETUP_CMD. 터미널은 TMUX_SESSION의 새 창 — 셸을 띄우고 거기에 기동 명령을 친다
#     (Orca와 같은 방식이라 에이전트가 죽어도 셸이 남아 재기동 명령을 받을 수 있다)
#   - idle은 에이전트의 훅이 보고한다. 시작 점검 때 ~/.cache/ticket-loop/<owner-repo>/tmux/ 에 hook.sh와 Claude Code 훅 설정
#     claude-hooks.json을 쓰고, 기동 명령에 `--settings <그 파일>`(claude) 또는 `-c notify=[…]`(codex)를 붙인다. 훅은
#     UserPromptSubmit → running, Stop → idle, Notification(permission_prompt·elicitation_dialog) → needsInput, SessionEnd → exited 를
#     state/<워크트리 디렉터리 이름> 파일에 한 단어로 쓰고, 루프가 IDLE_POLL_SEC마다 읽는다(cmux의 lifecycle과 같은 뜻)
#   - 프롬프트가 수락됐는지도 그 파일로 안다: 보내기 전에 sent를 쓰고 SEND_ACCEPT_SEC(15초) 안에 running(UserPromptSubmit)이 되는지 본다.
#     Codex의 notify는 턴 종료(agent-turn-complete)만 알리므로 보낸 것으로 치고 루프가 직접 running을 쓴다
#   - Stop은 메인 에이전트의 턴이 끝날 때마다 온다 — 백그라운드 서브에이전트(ticket-review)를 기다리는 동안도 idle로 보인다(실측 1회).
#     서브에이전트가 돌아오면 Claude Code가 스스로 턴을 열어 UserPromptSubmit이 running을 다시 쓰고, 공통부는 화면이 바뀌면 연속
#     횟수를 0부터 세므로 멈추지 않는다. cmux의 lifecycle도 같은 훅에 기대므로 같은 성질이다
#   - 상태 표시는 창 이름 뒤에 붙인다(issue-12 [review]). 사람은 `tmux attach -t <세션>`으로 어느 터미널 앱에서나(또는 SSH로) 본다
#   - 루프를 tmux 안에서 돌리면 그 세션에 창을 열고, 밖에서 돌리면 ticket-loop 세션을 만든다(TMUX_SESSION으로 바꾼다)

tmux_check() {
  command -v "$TMUX_CLI" >/dev/null 2>&1 || die "tmux (${TMUX_CLI}) not found (brew install tmux, or set TMUX_CLI=<path>)."
  case "$AGENT" in claude|codex) ;; *) die "The tmux backend supports only AGENT=claude|codex (idle is reported by agent hooks)." ;; esac
  [[ -n "$WORKTREE_DIR" ]] || WORKTREE_DIR="$HOME/.cache/ticket-loop/${OWNER_REPO//\//-}/worktrees"
  claude_trust_check
  if [[ -z "$TMUX_SESSION" ]]; then
    if [[ -n "${TMUX:-}" ]]; then TMUX_SESSION="$("$TMUX_CLI" display -p '#S')"; else TMUX_SESSION="ticket-loop"; fi
  fi
  TMUX_DIR="$HOME/.cache/ticket-loop/${OWNER_REPO//\//-}/tmux"
  TMUX_STATE_FILE=""
  mkdir -p "$TMUX_DIR/state"
  tmux_write_hook
  case "$AGENT" in
    claude) AGENT_RESTART_CMD="$AGENT_RESTART_CMD --settings $(printf %q "$TMUX_DIR/claude-hooks.json")" ;;
    codex)  AGENT_RESTART_CMD="$AGENT_RESTART_CMD -c $(printf %q "notify=[\"bash\",\"$TMUX_DIR/hook.sh\",\"$TMUX_DIR/state\"]")" ;;
  esac
  log "tmux session ${TMUX_SESSION} — view worker windows with '${TMUX_CLI} attach -t ${TMUX_SESSION}'"
}

# 훅 스크립트와 Claude Code 훅 설정. 루프가 시작할 때마다 다시 쓴다(키트 버전을 따라간다)
tmux_write_hook() {
  cat > "$TMUX_DIR/hook.sh" <<'SH'
#!/usr/bin/env bash
# ticket-loop.sh tmux 백엔드의 에이전트 훅 — 루프가 시작할 때마다 다시 쓴다. 손으로 고치지 않는다.
# 에이전트가 보고한 상태를 <state 디렉터리>/<워크트리 디렉터리 이름> 에 한 단어로 쓴다: running | idle | needsInput | exited
# Claude Code: 훅 입력 JSON을 stdin으로 준다(hook_event_name, notification_type, cwd). Codex: notify가 JSON을 둘째 인자로 준다(type, cwd)
dir="$1"; payload="${2:-}"
[[ -n "$payload" ]] || payload="$(cat)"
{ read -r ev; read -r nt; read -r cwd; } < <(jq -r '(.hook_event_name // .type // "-"), (.notification_type // "-"), (.cwd // "-")' <<<"$payload" 2>/dev/null)
case "${ev:-}" in
  UserPromptSubmit) s=running ;;
  Stop|agent-turn-complete) s=idle ;;
  Notification) case "${nt:-}" in permission_prompt|elicitation_dialog) s=needsInput ;; idle_prompt) s=idle ;; *) exit 0 ;; esac ;;
  SessionEnd) s=exited ;;
  *) exit 0 ;;
esac
[[ -n "${cwd:-}" && "$cwd" != "-" ]] || exit 0
printf '%s\n' "$s" > "$dir/$(basename "$cwd")"
exit 0
SH
  chmod +x "$TMUX_DIR/hook.sh"
  jq -n --arg cmd "bash $(printf %q "$TMUX_DIR/hook.sh") $(printf %q "$TMUX_DIR/state")" '
    def h: [{hooks: [{type: "command", command: $cmd}]}];
    {hooks: {UserPromptSubmit: h, Stop: h, Notification: h, SessionEnd: h}}' > "$TMUX_DIR/claude-hooks.json"
}

tmux_state() { cat "$TMUX_STATE_FILE" 2>/dev/null || true; }
tmux_alive() { "$TMUX_CLI" display -p -t "$1" '#{pane_id}' >/dev/null 2>&1; }

tmux_worktree_create() {
  local n="$1" prompt="$2" name="${3:-${BRANCH_PREFIX}${1}}" out pf
  loop_worktree_add "$n" "$name"
  TMUX_STATE_FILE="$TMUX_DIR/state/$(basename "$WT_PATH")"
  printf 'running\n' > "$TMUX_STATE_FILE"   # 지난 실행의 idle이 남아 있으면 기동 직후를 idle로 오판한다
  if "$TMUX_CLI" has-session -t "=${TMUX_SESSION}" 2>/dev/null; then
    out="$("$TMUX_CLI" new-window -d -t "=${TMUX_SESSION}:" -n "$name" -c "$WT_PATH" -P -F '#{window_id} #{pane_id}')" \
      || die "tmux new-window failed"
  else
    out="$("$TMUX_CLI" new-session -d -s "$TMUX_SESSION" -n "$name" -c "$WT_PATH" -x 200 -y 50 -P -F '#{window_id} #{pane_id}')" \
      || die "tmux new-session failed"
  fi
  WT="${out%% *}"; HANDLE="${out##* }"
  [[ "$WT" == @* && "$HANDLE" == %* ]] || die "No tmux window id returned: ${out}"
  pf="$(prompt_file "$n" "$prompt")"
  sleep 1   # 셸이 뜨기를 잠깐 기다린다
  tmux_type "$HANDLE" "$(agent_launch_cmd "$pf")" || die "tmux send-keys failed"
}

tmux_worktree_remove() {
  "$TMUX_CLI" kill-window -t "$1" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$2"
  # 창을 닫으면 에이전트의 SessionEnd 훅이 뒤늦게 exited를 쓸 수 있어(실측) 파일이 남기도 한다. 다음 티켓은 만들 때 running으로 덮으니 무해하다
  rm -f "$TMUX_DIR/state/$(basename "$2")"
}

tmux_type()      { "$TMUX_CLI" send-keys -t "$1" -l -- "$2" && sleep 0.3 && "$TMUX_CLI" send-keys -t "$1" Enter; }
tmux_interrupt() { "$TMUX_CLI" send-keys -t "$1" C-c; }

tmux_send() {
  local handle="$1" i
  [[ -n "$TMUX_STATE_FILE" ]] || return 1
  printf 'sent\n' > "$TMUX_STATE_FILE"
  tmux_type "$handle" "$2" || return 1
  if [[ "$AGENT" != claude ]]; then printf 'running\n' > "$TMUX_STATE_FILE"; return 0; fi   # 제출 훅이 없는 에이전트
  for (( i = 0; i < SEND_ACCEPT_SEC * 2; i++ )); do   # UserPromptSubmit 훅이 running을 쓰면 수락된 것
    [[ "$(tmux_state)" != running ]] || return 0
    sleep 0.5
  done
  return 1
}

tmux_wait_idle() {
  local handle="$1" deadline_ms=$(( $(date +%s) * 1000 + $2 )) fails=0
  while :; do
    if tmux_alive "$handle"; then
      fails=0
      case "$(tmux_state)" in idle|needsInput|exited) return 0 ;; esac   # 그 밖(running·sent·없음)은 작업 중
    else
      fails=$((fails + 1)); [[ $fails -lt $TERMINAL_RETRY ]] || return 3
    fi
    [[ $(( $(date +%s) * 1000 )) -lt $deadline_ms ]] || return 1
    sleep "$IDLE_POLL_SEC"
  done
}

# 화면의 빈 줄을 빼고 마지막 25줄 — TUI는 창 높이를 다 쓰므로 빈 줄이 많다
tmux_tail() { "$TMUX_CLI" capture-pane -p -t "$1" | sed -e 's/[[:space:]]*$//' | awk 'NF' | tail -n 25; }

tmux_set_status() {
  local wt="$1" status="$2" name lane
  case "$status" in in-progress) lane=working ;; in-review) lane=review ;; completed) lane=done ;; *) lane=needs-attention ;; esac
  name="$("$TMUX_CLI" display -p -t "$wt" '#{window_name}' 2>/dev/null)" || return 0
  "$TMUX_CLI" rename-window -t "$wt" "${name%% *} [${lane}]" >/dev/null 2>&1 || true
}

# ----- 공통 -----

terminal_idle() { backend_wait_idle "$@"; }
terminal_tail() { backend_tail "$@"; }
send_prompt() { backend_send "$1" "$2" || die "Prompt was not accepted (terminal $1)"; }

worker_prompt() {
  # 한 줄로 보낸다 — TUI에서는 줄바꿈이 곧 제출이다.
  # 절차(선행 확인·브랜치·seam·리뷰·PR 본문·라벨·병합 금지)는 저장소의 implement 스킬이 단일 진실이다.
  # 여기에는 무인 실행에서만 참인 것만 둔다 — 질문 금지, 막히면 코멘트 후 멈춤, 규칙 파일. 특정 에이전트의 도구·명령 이름은 쓰지 않는다(SKILL_PREFIX만 다르다).
  local n="$1" rules=""
  [[ ! -f "$ROOT/$WORKER_RULES_FILE" ]] || rules=" 저장소의 ${WORKER_RULES_FILE} 규칙도 따라라."
  printf '%s' "${SKILL_PREFIX}implement ${n} — 무인 루프(ticket-loop.sh)에서 실행 중이다. 사람이 답할 수 없으니 사람에게 묻거나 확인을 구하지 말고(질문 도구도 쓰지 말고) 스스로 결정해 끝까지 진행해라. PR은 병합하지 마라 — 루프가 CI 뒤에 병합한다. 진행이 불가능하면(열린 선행 이슈 포함) 이슈 #${n}에 이유를 코멘트로 남기고 PR 없이 멈춰라.${rules}"
}

# 에이전트가 실제로 떴는지 확인한다. Orca가 셸에 기동 명령을 넣을 때 앞 글자가 빠져
# (`laude …`) 셸 프롬프트에 멈춘 실측이 있다(4연속). 배너가 안 보이면 입력 줄을 지우고 한 번 다시 띄운다.
agent_banner_seen() { terminal_tail "$1" 2>/dev/null | grep -Eq "$AGENT_BANNER_REGEX"; }

# $3 다시 띄울 때 줄 프롬프트(기본 워커 프롬프트 — 무인 수습 세션은 자기 프롬프트를 준다)
ensure_agent_started() {
  local n="$1" handle="$2" prompt="${3:-}" i attempt promptfile
  [[ -n "$prompt" ]] || prompt="$(worker_prompt "${n}")"
  for attempt in 1 2; do
    for i in $(seq 1 $(( AGENT_START_WAIT_SEC / 3 ))); do
      agent_banner_seen "${handle}" && return 0
      sleep 3
    done
    [[ $attempt -eq 1 ]] || break
    log warn "#${n}: agent did not start — relaunching in the terminal"
    promptfile="$(prompt_file "${n}" "$prompt")"
    backend_interrupt "${handle}" || true   # Ctrl-C로 입력 줄 비움
    sleep 1
    backend_type "${handle}" "$(agent_launch_cmd "${promptfile}")" || die "#${n}: failed to send the relaunch command"
  done
  die "#${n}: agent did not start in terminal ${handle}"
}

# ----- 진행 로그 -----
# 워크트리를 만든 뒤 PR이 열리기까지(보통 수십 분) 루프 터미널에는 아무 줄도 없어 멈춘 것처럼 보였다 — 워커는 다른 창에서 일한다.
# 그 사이 PROGRESS_SEC마다 워크트리를 git으로만 들여다본다(백엔드·에이전트와 무관하고 네트워크도 안 쓴다):
#   브랜치가 바뀌면(워커가 issue-N → issue-N-<slug>로 옮김. 옮기지 않고 issue-N에 그대로 커밋해도 PR은 open_pr_for가 잡는다), 처음 파일이 수정되면, 새 커밋이 들어오면(제목 그대로, 오래된 것부터) 바로 한 줄.
#   커밋 줄은 워커가 만든 것만 — origin/<BASE_BRANCH>에서 닿는 커밋은 뺀다. 워커가 더 새로운 기본 브랜치에서 브랜치를 따 HEAD가 기본 브랜치 안에서만
#   옮겨 갔으면 "base moved to <sha>" 한 줄(그 사이 병합된 남의 커밋이 워커 커밋처럼 보이지 않게). 원격 추적 ref가 없으면 전처럼 범위의 커밋을 다 찍는다
#   그 밖에는 커밋 안 된 변경 파일 목록이 지난 줄과 달라졌을 때만, HEARTBEAT_SEC에 한 번까지 "작업 중" 한 줄에 경과 시간과 파일(이름 셋까지)을
#   적는다 — 이슈를 읽고 TDD로 도는 첫 수십 분은 커밋이 없어도 무엇을 만지는지 보인다. 같은 내용은 되풀이하지 않는다(변화가 없으면 조용하다).
#   화면을 읽어 도구 호출을 뽑는 쪽은 에이전트마다 형식이 달라 쓰지 않는다
# wait_for_pr는 백그라운드 서브셸(bg_wait)로 불려 그 안에서 바뀐 PROG_*가 부모에 남지 않는다 — run_ticket이 전에 progress_reset을,
# PR이 열린 뒤 progress_sync를 불러 수리 단계의 progress_check가 이미 찍은 커밋을 되풀이하지 않게 한다
progress_reset() {   # $1 워크트리 경로. 티켓마다 한 번
  PROG_WT="$1"; PROG_START="$(date +%s)"; PROG_LAST_LOG="$PROG_START"; PROG_DIRTY_SEEN=0
  progress_sync
}

progress_sync() {   # 지금 HEAD·브랜치를 기준점으로(경과 시간은 그대로)
  PROG_HEAD="$(git -C "$PROG_WT" rev-parse HEAD 2>/dev/null || true)"
  PROG_BRANCH="$(git -C "$PROG_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  PROG_LAST_LOG="$(date +%s)"; PROG_LAST_FILES="$(progress_dirty)"
  [[ -z "$PROG_LAST_FILES" ]] || PROG_DIRTY_SEEN=1
}

progress_dirty() {   # 커밋 안 된 변경 파일 경로(한 줄에 하나, 이름 바꿈은 새 이름). 무시 파일은 빠진다
  git -C "$PROG_WT" status --porcelain --untracked-files=all 2>/dev/null | sed -e 's/^...//' -e 's/.* -> //'
}

progress_check() {   # $1 티켓 번호. 바뀐 것이 있으면 한 줄씩, 없으면 HEARTBEAT_SEC마다 한 줄
  local n="$1" now head base branch commits line files cnt names noted=0
  [[ -n "${PROG_WT:-}" && -d "$PROG_WT" ]] || return 0
  now="$(date +%s)"
  branch="$(git -C "$PROG_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$branch" && "$branch" != "$PROG_BRANCH" ]]; then
    log step "#${n}: branch ${branch}"; PROG_BRANCH="$branch"; noted=1
  fi
  head="$(git -C "$PROG_WT" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$head" && "$head" != "$PROG_HEAD" ]]; then
    # 기본 브랜치의 원격 추적 ref. 워크트리는 메인 체크아웃과 ref를 공유하므로 워커의 git fetch가 갱신한 값을 그대로 쓴다(루프는 fetch하지 않는다).
    # 없으면(로컬 전용 저장소 등) 빈 값 — 아래는 전과 같이 동작한다
    base=""; [[ -z "${BASE_BRANCH:-}" ]] || base="$(git -C "$PROG_WT" rev-parse --verify -q "refs/remotes/origin/${BASE_BRANCH}" 2>/dev/null || true)"
    if [[ -n "$base" ]] && git -C "$PROG_WT" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
      # HEAD가 기본 브랜치 안에서만 옮겨 갔다(워커가 더 새로운 origin/<base>에서 브랜치를 땄다) — 그 사이 병합된 남의 커밋을 워커 커밋처럼 찍지 않는다
      log step "#${n}: base moved to $(git -C "$PROG_WT" rev-parse --short "$head" 2>/dev/null || echo "${head:0:7}")"
    else
      # 지난 HEAD 이후의 커밋들 — 기본 브랜치에서 닿는 커밋은 뺀다. HEAD가 뒤로 갔거나(amend·reset) 지난 값이 없으면 지금 커밋 하나만
      commits="$(git -C "$PROG_WT" log --reverse --format='%h %s' "${PROG_HEAD:-$head}..${head}" ${base:+--not "$base"} 2>/dev/null || true)"
      [[ -n "$commits" ]] || commits="$(git -C "$PROG_WT" log -1 --format='%h %s' "$head" 2>/dev/null || true)"
      while IFS= read -r line; do [[ -z "$line" ]] || log step "#${n}: commit ${line}"; done <<<"$commits"
    fi
    PROG_HEAD="$head"; noted=1
  fi
  files="$(progress_dirty)"
  cnt=0; [[ -z "$files" ]] || cnt="$(printf '%s\n' "$files" | grep -c .)"
  names="$(printf '%s\n' "$files" | head -n 3 | paste -sd ',' - | sed 's/,/, /g')"
  [[ $cnt -le 3 ]] || names="${names} +$((cnt - 3)) more"
  if [[ $PROG_DIRTY_SEEN -eq 0 && $cnt -gt 0 ]]; then
    log step "#${n}: first file changes — ${names}"; PROG_DIRTY_SEEN=1; noted=1
  fi
  # 심장박동: 변경 파일 목록이 지난 줄과 다를 때만. 같은 목록(또는 빈 목록)이면 시간이 아무리 지나도 되풀이하지 않는다
  if [[ $noted -eq 0 && $cnt -gt 0 && "$files" != "$PROG_LAST_FILES" && $(( now - PROG_LAST_LOG )) -ge $HEARTBEAT_SEC ]]; then
    log "#${n}: working — $(( (now - PROG_START) / 60 ))m elapsed, ${cnt} uncommitted file$([[ $cnt -eq 1 ]] || echo s): ${names}"; noted=1
  fi
  [[ $noted -eq 0 ]] || { PROG_LAST_LOG="$now"; PROG_LAST_FILES="$files"; }
}

# idle을 한 번 기다리는 길이. 진행 로그를 켜 두면 PROGRESS_SEC마다 돌아와 워크트리를 본다
idle_wait_ms() { if [[ "$PROGRESS_SEC" -gt 0 ]]; then echo $(( PROGRESS_SEC * 1000 )); else echo "$IDLE_WAIT_MS"; fi; }
# ----- 진행 로그 끝 -----

# idle 오판 $1번을 센다(idle_fp_count). 오판은 일하던 워커를 idle로 본 것이다 — 그 뒤 워커가 다시 일했거나(화면이 바뀜·idle이 풀림)
# PR을 열었다
idle_fp_add() { local i; for (( i = 0; i < $1; i++ )); do echo >> "${IDLE_FP_FILE:-/dev/null}"; done; }

# idle로 보이는 워커가 실제로는 일하는 중인지를 Claude Code 세션 기록으로 본다 — $1 작업 폴더(워커의 WT_PATH, 수습 세션의 워크트리)의
# 세션 기록 폴더(claude_project_dir — 토큰 집계와 같은 변환이라 Orca처럼 WORKTREE_DIR 밖의 워크트리도 맞는다) 아래 *.jsonl(하위
# subagents/ 포함) 중 가장 최근 것이 SESSION_LOG_FRESH_SEC 안에 갱신됐으면 0. AGENT가 claude가 아니거나 폴더·파일이 없으면 1 — 호출부는
# idle 판정을 그대로 쓴다. 갱신 뒤 지난 초를 SESSION_LOG_AGE에 남긴다(로그용). 세 대기(wait_for_pr·repair·wait_for_verdict)가 strike를
# 세기 직전에 부른다. cmux에서 백그라운드 작업 알림으로 시작되는 턴 전후에 lifecycle이 잠깐 idle로 보이는 것으로 추정된다 — 2026-10-22
# rental-portal #266에서 strike 3회 중 앞의 2회는 워커가 도구를 7번 호출하던 중이었다. 진짜 idle(백그라운드 verify를 기다리며 턴이 끝난
# 상태 등)은 기록이 갱신되지 않아 전처럼 센다 — 이 가드는 strike를 줄이기만 하고 늘리지 않는다. mtime은 stat으로 읽는다(macOS -f %m,
# Linux -c %Y). Codex는 세션 기록 형식이 달라 아직 보지 않는다
session_active_recently() {
  local dir newest fmt
  SESSION_LOG_AGE=""
  [[ "${AGENT:-}" == claude && -n "${1:-}" ]] || return 1
  dir="$(claude_project_dir "$1")"
  [[ -d "$dir" ]] || return 1
  if stat -f %m "$dir" >/dev/null 2>&1; then fmt=(-f %m); else fmt=(-c %Y); fi
  newest="$(find "$dir" -type f -name '*.jsonl' -exec stat "${fmt[@]}" {} + 2>/dev/null | sort -n | tail -n 1)"
  [[ -n "$newest" ]] || return 1
  SESSION_LOG_AGE=$(( $(date +%s) - newest ))
  [[ "$SESSION_LOG_AGE" -le "$SESSION_LOG_FRESH_SEC" ]]
}

# ----- 화면 분류 -----
# 세 대기(wait_for_pr·repair·wait_for_verdict)가 strike를 세기 직전 — session_active_recently 가드 뒤(일하는 중이면 분류할 필요가 없다) — 와
# 백엔드 idle 대기가 타임아웃으로 돌아온 바퀴마다 워커 화면 끝 25줄(terminal_tail)을 본다. 두 가지를 가른다:
#   usage_limit        사용량 한도 문구(USAGE_LIMIT_REGEX). idle이면 strike 없이 바로 멈춘다. 무인 수습은 띄우지 않는다 — 수습 세션도 같은 한도에
#                      걸린다(2026-10 실측 rental-portal #262: 한도 문구를 일반 idle로 보고 strike 셋 뒤 worker_no_pr로 멈춰 수습 세션까지 헛돌았다).
#                      사람이 터미널에서 잇거나, 한도가 풀린 뒤 루프를 다시 돌려 새 워커로 시작한다
#   permission_prompt  권한 확인 창 문구(PERMISSION_PROMPT_REGEX). 그 문구가 든 화면이 PROMPT_STALL_SEC 동안 글자 그대로(체크섬)면 idle 신호와 무관하게
#                      확인 창에 멈춘 워커로 보고 worker_no_pr(진단만 하는 수습)로 멈춘다. idle 신호가 살아 있어 strike가 먼저 차면 전과 같은 경로다.
#                      idle 신호가 빈 값으로 이어지는 백엔드 상태(#2)에서도 닿는 경로다 — 2026-10 실측(#3, tmux)에서 bypass 모드의 워커(서브에이전트의
#                      Bash)가 "Do you want to proceed?"에 27분 멈춰 있는 동안 루프 로그는 한 줄도 없었다. 루프는 확인 창에 답하지 않는다(승인·거부
#                      둘 다) — bypass 모드에서도 물었다는 것은 deny 규칙 때문일 수 있다
# 빈 정규식은 그 종류를 감지하지 않는다(codex 프리셋 — 실측 전). 분류 결과는 멈춤 기록의 kind와 사유에만 남는다(새 필드 없음).
#
# 대기 함수가 "멈춤"의 종류·사유를 호출부에 넘기는 길: wait_for_pr·wait_for_verdict는 bg_wait 서브셸에서 돌아 변수가 부모에 남지 않으므로
# WAIT_STOP_FILE("종류<탭>사유" 한 줄)을 거친다. 호출부는 대기 전에 wait_stop_reset(파일은 부모가 만든다), 대기 뒤 wait_stop_read로
# WAIT_STOP_KIND·WAIT_STOP_REASON을 채운다. 비어 있으면 전처럼 idle strike로 멈춘 것이다
WAIT_STOP_KIND=""; WAIT_STOP_REASON=""; WAIT_STOP_FILE=""
wait_stop_reset() {
  WAIT_STOP_KIND=""; WAIT_STOP_REASON=""
  [[ -n "$WAIT_STOP_FILE" ]] || WAIT_STOP_FILE="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-stop.XXXXXX")"
  : > "$WAIT_STOP_FILE"
}
wait_stop() { WAIT_STOP_KIND="$1"; WAIT_STOP_REASON="$2"; [[ -z "$WAIT_STOP_FILE" ]] || printf '%s\t%s\n' "$1" "$2" > "$WAIT_STOP_FILE"; }
wait_stop_read() {
  [[ -n "$WAIT_STOP_FILE" && -s "$WAIT_STOP_FILE" ]] || return 0
  IFS=$'\t' read -r WAIT_STOP_KIND WAIT_STOP_REASON < "$WAIT_STOP_FILE" || true
  : > "$WAIT_STOP_FILE"
}

# screen_kind 터미널 → usage_limit | permission_prompt | 빈 값을 stdout에 쓰고 SCREEN_KIND에도 둔다(커맨드 치환 없이 불러야 아래 값이 남는다).
# 맞은 줄은 SCREEN_LINE(앞뒤 공백을 지운 것 — 멈춤 사유에 싣는다), 화면 체크섬은 SCREEN_SUM(확인 창 체류 시간용), 사용량 한도면 화면의
# 재설정 시각 문구("resets at …", "try again at …")를 SCREEN_RESET에 둔다(맞은 줄 안에 이미 있으면 비운다). 두 문구가 다 있으면 한도가 먼저다
SCREEN_KIND=""; SCREEN_LINE=""; SCREEN_SUM=""; SCREEN_RESET=""
screen_trim() { sed -e 's/^[[:space:]]*\(│\)\{0,1\}[[:space:]]*//' -e 's/[[:space:]]*\(│\)\{0,1\}[[:space:]]*$//'; }   # 앞뒤 공백과 TUI 상자 테두리(│)
screen_kind() {
  local tail line
  SCREEN_KIND=""; SCREEN_LINE=""; SCREEN_SUM=""; SCREEN_RESET=""
  [[ -n "${USAGE_LIMIT_REGEX:-}" || -n "${PERMISSION_PROMPT_REGEX:-}" ]] || return 0
  tail="$(terminal_tail "$1" 2>/dev/null)" || true
  [[ -n "$tail" ]] || return 0
  SCREEN_SUM="$(cksum <<<"$tail" | cut -d' ' -f1)"
  if [[ -n "${USAGE_LIMIT_REGEX:-}" ]]; then
    line="$(grep -E "$USAGE_LIMIT_REGEX" <<<"$tail" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      SCREEN_KIND=usage_limit; SCREEN_LINE="$(screen_trim <<<"$line")"
      SCREEN_RESET="$(grep -iEo '(resets?|try again)( at| in| on)?[[:space:]]+[^|]*' <<<"$tail" | head -n 1 | screen_trim || true)"
      [[ -n "$SCREEN_RESET" && "$SCREEN_LINE" != *"$SCREEN_RESET"* ]] || SCREEN_RESET=""
    fi
  fi
  if [[ -z "$SCREEN_KIND" && -n "${PERMISSION_PROMPT_REGEX:-}" ]]; then
    line="$(grep -E "$PERMISSION_PROMPT_REGEX" <<<"$tail" | tail -n 1 || true)"
    [[ -z "$line" ]] || { SCREEN_KIND=permission_prompt; SCREEN_LINE="$(screen_trim <<<"$line")"; }
  fi
  printf '%s' "$SCREEN_KIND"
}

# 확인 창 체류 시간 — $1 지금 화면의 체크섬. 처음 본 시각(PROMPT_AT)과 그때의 화면(PROMPT_SUM)을 두고, 화면이 바뀌면 다시 센다.
# 같은 화면이 PROMPT_STALL_SEC 이상 머물렀으면 0. 대기 함수가 시작할 때 PROMPT_SUM=""로 비운다
PROMPT_SUM=""; PROMPT_AT=0
prompt_stalled() {
  local now; now="$(date +%s)"
  if [[ "$1" != "$PROMPT_SUM" ]]; then PROMPT_SUM="$1"; PROMPT_AT="$now"; return 1; fi
  [[ $(( now - PROMPT_AT )) -ge $PROMPT_STALL_SEC ]]
}

# 대기 한 바퀴의 화면 확인 — $1 터미널, $2 사유의 주어(worker | triage session), $3 idle 판정이면 1(세션 기록 가드 뒤에서만 부른다), 타임아웃으로
# 돌아온 바퀴면 0. 멈출 일이면 wait_stop을 채우고 0을 돌려준다(대기 함수는 "멈춤"으로 돌아간다). 아니면 1 — 대기 함수는 전처럼 간다
screen_check() {
  local handle="$1" who="$2" idle="${3:-0}"
  screen_kind "$handle" >/dev/null
  case "$SCREEN_KIND" in
    usage_limit)
      [[ $idle -eq 1 ]] || return 1   # 한도는 idle로 확인된 화면에서만 — 일하는 워커의 화면에 그 낱말이 지나갈 수 있다
      wait_stop usage_limit "${who} hit the usage limit: ${SCREEN_LINE}${SCREEN_RESET:+ — ${SCREEN_RESET}}"; return 0 ;;
    permission_prompt)
      prompt_stalled "$SCREEN_SUM" || return 1
      wait_stop worker_no_pr "${who} is waiting at a confirmation prompt: ${SCREEN_LINE} (screen unchanged for $(( $(date +%s) - PROMPT_AT ))s)"; return 0 ;;
    *) PROMPT_SUM=""; return 1 ;;   # 확인 창이 사라졌다 — 다시 보이면 처음부터 센다
  esac
}

# 대기가 화면 분류로 멈췄으면 여기서 멈춘다(die) — $1 티켓, $2 사유에 덧붙일 맥락(선택, 예 " while repairing PR #34"). 사용량 한도는 수습 없이
# usage_limit로(수습 세션도 같은 한도에 걸린다 — 멈춤 기록은 stop_report가 manual로 쓴다), 확인 창은 전의 worker_no_pr처럼 진단만 하는 수습 뒤
# 멈춘다. 분류가 없으면 0 — 호출부가 전처럼 간다(idle strike → worker_no_pr, 수리 끝 → head 비교)
screen_stop_check() {
  local n="$1" ctx="${2:-}" reason
  wait_stop_read
  case "$WAIT_STOP_KIND" in
    usage_limit)
      STOP_KIND=usage_limit
      die "#${n}: ${WAIT_STOP_REASON}${ctx}. No triage (it would hit the same limit) — rerun the loop after the limit resets. The ${BRANCH_PREFIX}${n} worktree is kept in ${BACKEND_NAME}." ;;
    worker_no_pr)
      reason="#${n}: ${WAIT_STOP_REASON}${ctx}. The loop does not answer prompts — check the ${BRANCH_PREFIX}${n} worktree in ${BACKEND_NAME}."
      STOP_KIND=worker_no_pr
      triage worker_no_pr "$reason" || true   # 진단만 — 요약을 사유에 붙여 멈춘다
      die "${reason}${TRIAGE_NOTE}" ;;
  esac
  return 0
}
# ----- 화면 분류 끝 -----

# PR을 찾은 뒤 워커가 이슈 정리(implement 스킬의 마지막 단계 — 체크박스, 맨 끝에 IN_REVIEW_LABEL)를 마치기를 기다린다. 이슈에 그 라벨이
# 붙었거나 워커가 idle이면 끝, 아니면 PR_SETTLE_SEC에서 넘어간다. 기다림은 남긴다 — CI 경로 필터로 체크 없이 바로 병합하는 PR은 워커보다
# 먼저 병합·이슈 닫힘·라벨 제거가 일어난다. 0.9.1까지는 idle 하나만 IDLE_WAIT_MS(10분)까지 기다렸다 — rental-portal 스펙 #141(cmux)에서
# lifecycle이 빈 값으로 이어져 13건 중 3건이 10분을 다 썼고, CI는 그사이 끝나 2~3초로 찍혔다. 세 건 모두 라벨은 PR 생성 8~12초 뒤에 붙어 있었다
pr_settle() {
  local n="$1" handle="$2" until=$(( $(date +%s) + PR_SETTLE_SEC )) rc
  while :; do
    ! issue_has_label "$n" "$IN_REVIEW_LABEL" || return 0
    rc=0; terminal_idle "$handle" 10000 || rc=$?
    [[ $rc -ne 0 && $rc -ne 3 ]] || return 0   # idle, 또는 터미널에 닿지 못함(기다려도 소용없다)
    if [[ "$(date +%s)" -ge "$until" ]]; then
      log warn "#${n}: no ${IN_REVIEW_LABEL} label on the issue and the worker not idle ${PR_SETTLE_SEC}s after finding the PR — moving on"
      return 0
    fi
  done
}

# PR이 생길 때까지(또는 워커가 멈출 때까지) 기다린다. 성공 시 PR 번호를 stdout에 쓴다.
# 반환: 0 PR 열림, 1 PR 없이 멈춤, 2 타임아웃, 3 백엔드 터미널 끊김
# idle 오판(idle_fp_add)은 PR 없이 센 idle 뒤에 워커가 다시 일한 것, 그리고 idle을 잡은 뒤 열린 PR이다. 0.9.1까지는 "idle 뒤 다시 보니
# PR이 열려 있음"을 다 셌는데, 대개 일을 마친 워커였다(PR을 연 뒤 idle) — 폴링 순서의 부산물이지 오판이 아니다
wait_for_pr() {
  local n="$1" handle="$2" deadline="$3" strikes=0 pending=0 pr started idle idle_at created last_screen="" screen wait_ms active_said=0
  started="$(date +%s)"; wait_ms="$(idle_wait_ms)"; PROMPT_SUM=""; PROMPT_AT=0
  while :; do
    pr="$(open_pr_for "${n}")"
    if [[ -n "${pr}" ]]; then
      idle_fp_add "$pending"   # 앞서 센 idle 뒤에 워커가 PR까지 갔다
      pr_settle "${n}" "${handle}"
      [[ "$PROGRESS_SEC" -le 0 ]] || progress_check "${n}"
      echo "${pr}"; return 0
    fi
    [[ "$(date +%s)" -lt "$deadline" ]] || return 2
    idle=0; terminal_idle "${handle}" "$wait_ms" || idle=$?
    [[ $idle -ne 3 ]] || return 3
    [[ "$PROGRESS_SEC" -le 0 ]] || progress_check "${n}"
    if [[ $idle -eq 0 ]]; then
      idle_at="$(date +%s)"
      if [[ $(( idle_at - started )) -lt $STARTUP_GRACE_SEC ]]; then sleep "$IDLE_RECHECK_SEC"; continue; fi
      # PR을 연 직후에는 idle이 PR 조회보다 먼저 잡힌다(매 티켓 실측) — 잠깐 뒤 PR부터 다시 본다. PR이 idle보다 먼저 열렸으면 일을 마친
      # 워커다. idle을 잡은 뒤에 열렸으면 그 idle은 일하던 워커를 본 오판이다
      sleep "$IDLE_RECHECK_SEC"
      pr="$(open_pr_for "${n}")"
      if [[ -n "$pr" ]]; then
        created="$(pr_created_epoch "$pr")"
        [[ -z "$created" || "$created" -le "$idle_at" ]] || idle_fp_add 1
        continue
      fi
      # 지난 idle 이후 화면이 바뀌었으면 그사이 일했다는 뜻 — 앞서 센 idle은 오판이고, 연속 횟수를 새로 센다
      screen="$(terminal_tail "${handle}" | cksum | cut -d' ' -f1)"
      if [[ "$screen" != "$last_screen" ]]; then idle_fp_add "$pending"; pending=0; strikes=0; last_screen="$screen"; fi
      # 세션 기록이 방금 갱신됐으면 일하던 워커를 idle로 본 것 — 이번 idle과 앞서 센 idle은 오판이고 strike를 세지 않는다(화면이 바뀐
      # 경우와 같은 처리). 로그는 연속된 idle 판정에서 한 번만
      if session_active_recently "${WT_PATH:-}"; then
        [[ $active_said -eq 1 ]] || log "#${n}: idle reported, but the session log was written ${SESSION_LOG_AGE}s ago — still working"
        idle_fp_add $((pending + 1)); pending=0; strikes=0; active_said=1
        sleep "$IDLE_RECHECK_SEC"; continue
      fi
      active_said=0
      # 화면 분류(screen_check): 사용량 한도면 strike 없이 바로, 확인 창에 PROMPT_STALL_SEC 머물렀으면 worker_no_pr로 — 둘 다 PR 없이 멈춤(1)
      ! screen_check "${handle}" worker 1 || return 1
      strikes=$((strikes + 1)); pending=$((pending + 1))
      log warn "#${n}: worker idle, no PR (${strikes}/${IDLE_STRIKES})"
      [[ ${strikes} -lt $IDLE_STRIKES ]] || return 1   # 정말 멈췄다 — 이 연속 idle은 오판이 아니다
      sleep "$IDLE_RECHECK_SEC"
    else
      idle_fp_add "$pending"; pending=0; strikes=0; active_said=0   # 워커가 계속 일한다 — 앞서 센 idle은 오판
      ! screen_check "${handle}" worker 0 || return 1   # idle 신호가 없어도 확인 창에 멈춘 워커는 여기서 잡는다(타임아웃으로 돌아온 바퀴)
    fi
  done
}

# 수리 프롬프트를 보내고 워커가 다시 idle이 될 때까지 기다린다(그동안의 커밋도 진행 로그에 찍힌다). $4 PR 번호를 주면 두 가지를 더 본다.
#   - idle인데 PR에 새 커밋이 아직 없으면 바로 끝내지 않는다. 화면이 그대로인 idle을 IDLE_STRIKES번 연달아(그 사이 IDLE_RECHECK_SEC) 볼
#     때만 끝이고, 호출부가 head를 비교해 "새 커밋 없음"으로 멈춘다. 그 전에 커밋이 들어오면 끝, 화면이 바뀌거나 워커가 다시 일하면 처음부터
#     센다(wait_for_pr와 같은 규칙). 프롬프트 직후의 묵은 idle(2026-10-20 rental-portal #251, cmux — cmux_send 참고)과 백그라운드
#     서브에이전트를 기다리는 동안의 idle을 수리 끝으로 읽지 않기 위해서다. 0.9.2까지는 첫 idle에서 끝냈다
#   - idle이 끝내 안 잡히는 백엔드(cmux lifecycle이 빈 값으로 이어질 때 — rental-portal 스펙 #141에서 하루 126번)에서도 끝을 알아챈다:
#     수리 프롬프트 뒤 새 커밋이 push됐고 head가 REPAIR_SETTLE_SEC 동안 그대로이며 워크트리에 커밋 안 된 변경이 없으면 끝난 것으로 본다.
#     0.9.1까지는 티켓 제한 시간까지 기다렸다
repair() {
  local handle="$1" text="$2" deadline="$3" pr="${4:-}" idle wait_ms before="" head="" seen="" seen_at=0 strikes=0 last_screen="" screen active_said=0
  wait_ms="$(idle_wait_ms)"; PROMPT_SUM=""; PROMPT_AT=0
  [[ -z "$pr" ]] || before="$(pr_head_sha "$pr" 2>/dev/null || true)"
  send_prompt "${handle}" "$text"
  while :; do
    idle=0; bg_wait terminal_idle "${handle}" "$wait_ms" || idle=$?
    [[ $idle -eq 3 ]] || [[ "$PROGRESS_SEC" -le 0 ]] || progress_check "${CUR_N}"
    [[ $idle -ne 3 ]] || die "Cannot reach ${BACKEND_NAME} terminal ${handle} (${BACKEND_NAME} app closed?)"
    [[ -z "$before" ]] || head="$(pr_head_sha "$pr" 2>/dev/null || true)"
    if [[ $idle -eq 0 ]]; then
      # 새 커밋이 있으면 끝이다. PR 번호가 없거나 head를 못 읽으면 전처럼 idle 하나로 끝낸다
      [[ -n "$before" && -n "$head" && "$head" == "$before" ]] || return 0
      screen="$(terminal_tail "${handle}" | cksum | cut -d' ' -f1)"
      if [[ "$screen" != "$last_screen" ]]; then strikes=0; last_screen="$screen"; fi
      if session_active_recently "${WT_PATH:-}"; then   # 세션 기록이 방금 갱신됐으면 아직 일하는 중 — strike를 세지 않는다(wait_for_pr와 같은 규칙)
        [[ $active_said -eq 1 ]] || log "#${CUR_N}: idle reported, but the session log was written ${SESSION_LOG_AGE}s ago — still working"
        strikes=0; active_said=1
      else
        active_said=0
        ! screen_check "${handle}" worker 1 || return 0   # 사용량 한도·확인 창 — 호출부(screen_stop_check)가 종류대로 멈춘다
        strikes=$((strikes + 1))
        log warn "#${CUR_N}: worker idle after the repair prompt, no new commit on PR #${pr} yet (${strikes}/${IDLE_STRIKES})"
        [[ ${strikes} -lt $IDLE_STRIKES ]] || return 0
      fi
      sleep "$IDLE_RECHECK_SEC"
    else
      strikes=0; active_said=0   # 워커가 다시 일한다
      ! screen_check "${handle}" worker 0 || return 0   # idle 신호가 없어도 확인 창에 멈춘 워커는 여기서 잡는다
      if [[ -n "$head" && "$head" != "$before" ]]; then
        [[ "$head" == "$seen" ]] || { seen="$head"; seen_at="$(date +%s)"; }
        if [[ $(( $(date +%s) - seen_at )) -ge $REPAIR_SETTLE_SEC && -z "$(progress_dirty)" ]]; then
          log warn "#${CUR_N}: the worker never went idle, but PR #${pr} has had a new commit (${head:0:7}) for ${REPAIR_SETTLE_SEC}s+ and the worktree is clean — treating the repair as done"
          return 0
        fi
      fi
    fi
    [[ "$(date +%s)" -lt "$deadline" ]] || return 1
  done
}

# ---------- CI · 병합 ----------

wait_checks_appear() {
  local pr="$1" until=$(( $(date +%s) + CI_APPEAR_TIMEOUT_SEC ))
  while [[ "$(gh pr checks "${pr}" --json name --jq 'length' 2>/dev/null || echo 0)" == "0" ]]; do
    [[ "$(date +%s)" -lt "$until" ]] || return 1
    sleep 30
  done
}

# --watch는 GitHub API 오류 한 번에도 1로 끝난다 — 체크 실패와 같은 코드다. 그대로 실패로 읽으면 워커에게 할 일 없는 수리를 보낸다.
# 1이면 체크 상태(bucket)를 다시 읽어 실패·취소가 있을 때만 실패, 다 통과했으면 통과, 아직 도는 체크가 있으면 다시 본다(GH_TRIES번까지).
# 체크 목록이 비었거나 못 읽었으면 실패가 아니라 재등록 중으로 본다 — GitHub가 job을 다시 큐에 넣는 순간(재시도·장애 복구) PR의 체크
# 목록이 잠깐 비고 --watch는 "no checks reported"로 끝난다(이슈 #24: 2026-10-23 rental-portal #316, run은 success인데 check-run 하나가
# 장애로 in_progress에 굳었다가 27분 뒤 attempt 2로 다시 돌았다 — 0.9.12는 그 빈 목록을 실패로 읽어 할 일 없는 수리를 보냈다).
# 그래서 빈 목록이면 체크가 다시 나타나기를 기다린 뒤(wait_checks_appear, CI_APPEAR_TIMEOUT_SEC) 다시 본다. 그 안에 나타나지 않거나
# GH_TRIES번 뒤에도 비어 있으면 전처럼 실패다. --watch의 stderr는 버린다 — 타임스탬프 없는 줄이 루프 로그에 그대로 섞이기 때문이고,
# 결과는 어차피 bucket으로 다시 읽는다
ci_passed() {
  local try buckets
  wait_checks_appear "$1" || { log warn "PR #$1: no checks were registered"; return 1; }
  for (( try = 1; try <= GH_TRIES; try++ )); do
    bg_wait gh pr checks "$1" --watch --fail-fast >/dev/null 2>&1 && return 0   # 끝날 때까지 블록, 실패 시 비0
    buckets="$(gh pr checks "$1" --json bucket --jq '[.[].bucket] | unique | join(" ")' 2>/dev/null || true)"
    if [[ -z "$buckets" ]]; then
      [[ $try -lt $GH_TRIES ]] || { log warn "PR #$1: the check list was empty after ${GH_TRIES} CI watches — treating it as a failure"; break; }
      log warn "PR #$1: CI watch ended with an empty check list (checks being re-registered?) — waiting for them to reappear (${try}/${GH_TRIES})"
      wait_checks_appear "$1" || { log warn "PR #$1: the checks did not reappear within ${CI_APPEAR_TIMEOUT_SEC}s"; return 1; }
      continue
    fi
    [[ " $buckets " != *" fail "* && " $buckets " != *" cancel "* ]] || return 1
    [[ " $buckets " == *" pending "* ]] || { log warn "PR #$1: CI watch failed but every check passed (GitHub error?) — going on"; return 0; }
    [[ $try -lt $GH_TRIES ]] || break
    log warn "PR #$1: CI watch failed with no failed check (GitHub error?) — watching again (${try}/${GH_TRIES})"
  done
  return 1
}

pr_head_sha() { gh pr view "$1" --json headRefOid -q .headRefOid; }

# CI 수리를 보내고 기다린다. 0: 충돌·CI 확인부터 다시 볼 것, 1: 새 커밋도 없고 CI도 그대로 실패. 제한 시간이면 멈춘다.
# 코드를 바꾸지 않는 수리도 있다 — 러너·네트워크 장애로 실패한 job은 `gh run rerun --failed`로 다시 돌리면 녹색이 되고, push할 커밋이
# 없다(2026-10-21 rental-portal #258: 같은 HOME을 나눠 쓰는 self-hosted 러너 둘의 설치 경합. 워커는 재실행만 했고 1분 뒤 통과했는데,
# 0.9.4까지는 head가 그대로라 멈췄다). 그래서 head가 그대로면 CI를 한 번 더 본다 — 재실행이 도는 중이면 끝까지 보고, 통과면 0이다
repair_ci() {
  local n="$1" pr="$2" handle="$3" deadline="$4" before rc=0
  before="$(pr_head_sha "${pr}")"
  phase repair
  repair "${handle}" "PR #${pr} 의 CI가 실패했다. \`gh pr checks ${pr}\` 와 \`gh run view --log-failed\` 로 원인을 보고 고친 뒤 테스트·lint를 다시 돌리고 같은 브랜치에 push해라. 테스트를 건너뛰거나 지우지 마라. 같은 커밋의 다른 job은 통과했고 실패가 러너·네트워크 오류처럼 코드와 무관하면 코드를 바꾸지 말고 \`gh run rerun <run-id> --failed\` 로 실패한 job만 다시 돌려라(push할 커밋이 없어도 된다). 질문하지 말고 끝까지 해라." "$deadline" "${pr}" \
    || die "#${n}: timed out while repairing CI"
  phase ""
  screen_stop_check "${n}" " while repairing PR #${pr}"   # 수리 중 사용량 한도·확인 창이면 여기서 멈춘다
  [[ "$(pr_head_sha "${pr}")" == "$before" ]] || return 0
  log warn "#${n}: no new commit after the repair — checking CI again (a re-run needs no commit)"
  phase ci   # 재실행을 기다리는 동안은 CI다
  ci_passed "${pr}" || rc=$?
  phase ""
  return "$rc"
}

# CI가 실제로 돈 시간(초) — PR head 체크들의 가장 이른 시작부터 가장 늦은 끝까지(GitHub 시각). 루프가 CI 대기를 시작한 때부터 재면 그 전에
# 끝난 CI가 2~3초로 찍힌다(0.9.1까지 — PR을 알아채는 게 늦으면). 못 읽으면 빈 값이고, 부르는 쪽이 루프가 잰 값을 쓴다
ci_run_sec() {
  { gh pr checks "$1" --json startedAt,completedAt 2>/dev/null || true; } | jq -r '
    def t: if . == null or . == "" or startswith("0001-") then empty else sub("\\.[0-9]+Z$"; "Z") | fromdate end;
    ([.[].startedAt | t] | min) as $s | ([.[].completedAt | t] | max) as $e
    | if $s == null or $e == null or $e < $s then empty else ($e - $s) end' 2>/dev/null || true
}

# 반환 0: CI가 도는 PR, 1: 저장소 CI의 경로 필터에 걸려 체크가 안 붙는 게 정상인 PR(CI_SKIP_CMD가 "skip", 또는 바뀐 파일이 전부
# CI_SKIP_REGEX에 맞음). 둘 다 없거나 판정이 안 되면 0(기다리는 쪽).
ci_expected() {
  local files verdict
  [[ -n "$CI_SKIP_CMD" || -n "$CI_SKIP_REGEX" ]] || return 0
  files="$(gh pr diff "$1" --name-only 2>/dev/null)" || return 0
  [[ -n "$files" ]] || return 0
  if [[ -n "$CI_SKIP_CMD" ]]; then
    verdict="$(cd "$ROOT" && printf '%s\n' "$files" | bash -c "$CI_SKIP_CMD" 2>/dev/null)" || return 0
    [[ "$verdict" != "skip" ]]
    return
  fi
  grep -Evq "$CI_SKIP_REGEX" <<<"$files"
}

mergeable_state() {
  # MERGEABLE | CONFLICTING | UNKNOWN(계산 중)
  local pr="$1" s i
  for i in 1 2 3 4 5 6; do
    s="$(gh pr view "${pr}" --json mergeable -q .mergeable)"
    [[ "$s" == "UNKNOWN" ]] || { echo "$s"; return; }
    sleep 10
  done
  echo "UNKNOWN"
}

# PR을 병합한다. GitHub 일시 장애(GH_TRANSIENT_RE, 그리고 "Base branch was modified")면 GH_TRIES번까지 다시 해 본다(GH_RETRY_SEC×회차씩 쉬고).
# 실패할 때마다 먼저 이미 병합됐는지 본다 — 서버는 병합을 끝냈는데 응답에서만 502가 났을 수 있고, 그대로 다시 부르면 "already merged"로
# 실패한다. 그 밖의 실패(권한, 필수 리뷰 같은 브랜치 보호, 충돌)는 바로 1이다. 마지막 gh 오류의 첫 줄을 MERGE_ERR에 남긴다.
# 실측(0.9.2, cmux): CI 통과 직후 병합 한 번이 "non-200 OK status code: 502 Bad Gateway"를 받아 루프가 멈췄다(이슈 #7)
MERGE_ERR=""
merge_pr() {
  local pr="$1" out try pause
  local transient="${GH_TRANSIENT_RE}|base branch was modified"
  MERGE_ERR=""
  for (( try = 1; try <= GH_TRIES; try++ )); do
    out="$(gh pr merge "$pr" "--$MERGE_METHOD" 2>&1)" && return 0
    if [[ "$(gh pr view "$pr" --json state -q .state 2>/dev/null || true)" == MERGED ]]; then
      log warn "PR #${pr}: the merge call failed but the PR is merged — going on"
      return 0
    fi
    [[ -z "$out" ]] || printf '%s\n' "$out" | dim_lines
    MERGE_ERR="$(grep -m1 . <<<"$out" || true)"
    grep -Eqi "$transient" <<<"$out" || return 1
    [[ $try -lt $GH_TRIES ]] || break
    pause=$(( try * GH_RETRY_SEC ))
    log warn "PR #${pr}: merge hit a transient GitHub error (${try}/${GH_TRIES}) — retrying in ${pause}s"
    sleep "$pause"
  done
  return 1
}

# ---------- 병합 뒤 검증 ----------
# 워커가 돌리기 어려운 검증(실제 서버·공유 DB·고정 포트를 쓰는 통합·E2E 테스트)을 병합된 기본 브랜치로
# 한 번 돌린다. 루프는 직렬이라 여기서 돌리면 워커끼리 부딪히지 않는다. 저장소 밖 전용 워크트리를 쓴다.

port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
port_holder() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" pid "$2}'; }   # 예: "node pid 48213"

post_merge_worktree_path() {
  if [[ -n "$POST_MERGE_WORKTREE" ]]; then printf '%s' "$POST_MERGE_WORKTREE"; return; fi
  printf '%s/.cache/ticket-loop/%s/post-merge' "$HOME" "${OWNER_REPO//\//-}"
}

# ----- 묶어 돌리는 검증(POST_MERGE_EVERY) -----
# 병합 뒤 검증은 누적이다 — 기본 브랜치 끝에서 도는 검증은 그 전의 병합을 모두 덮는다. 그래서 병합 몇 개마다 한 번 돌려도 빠지는 병합은 없고,
# 잃는 것은 "어느 병합이 깨뜨렸나"뿐이다(그 답은 실패했을 때 pm_bisect가 찾는다). 루프는 한 번에 한 티켓이라 병합 직전 기본 브랜치는 워커가
# 테스트한 그 상태다 — 워커의 관련 테스트가 이미 돈 코드에 전체 스위트를 다시 도는 것이다. 실측(rental-portal, 0.9.5): 통합 테스트가
# 티켓마다 47~52분, 스펙 #248에서 12회 9.8시간이었고, 워커가 PR 전에 관련 통합 테스트를 돌리기 시작한 뒤 34회 동안 잡은 회귀는 없었다.
#   PM_BASE     창의 시작 — 마지막으로 검증을 통과한 커밋(없으면 창 첫 병합의 부모)
#   PM_PENDING  아직 검증을 거치지 않은 루프의 병합, 한 줄에 "이슈<탭>PR<탭>병합 커밋"(병합 순서)
#   PM_SPEC_COMPLETE  창의 병합이 끝낸 스펙 번호들(공백 구분, 보통 하나) — 검증 명령이 TICKET_LOOP_POST_MERGE_SPEC_COMPLETE로 받는다.
#               병합이 모두 검증을 거친 뒤에 닫힌 스펙이면 창이 비어도 남는다(루프 끝 검증이 받는다 — pm_flush_end)
# 셋 다 PM_STATE_FILE에 남는다. 이분 탐색은 PM_PENDING이 아니라 git의 PM_BASE..끝을 훑는다 — 사람이 병합한 커밋도 범위에 든다
#   PM_SPEC_COVERED  이번 실행에서 TICKET_LOOP_POST_MERGE_SPEC_COMPLETE에 실려 통과한 스펙 번호들 — 창에 다시 적지 않는다(저장하지 않는다)
PM_BASE=""; PM_PENDING=""; PM_SPEC_COMPLETE=""; PM_SPEC_COVERED=""; PM_WHY=""; PM_WHY_KEY=""; PM_BISECT=""; PM_FIRST_FAILING=""; PM_REASON=""
NEXT_TARGETS=""; NEXT_TARGETS_SET=0   # pm_due가 미리 계산한 다음 대상 — 메인 고리가 그대로 쓴다

pm_count() { local c; c="$(grep -c . <<<"$PM_PENDING" || true)"; printf '%s' "${c:-0}"; }
pm_list() { awk -F'\t' 'NF && $1 != "" { printf "%s#%s", (k++ ? " " : ""), $1 }' <<<"$PM_PENDING"; }
# 창에 적힌 스펙 완료 — "#40" 또는 드물게 "#40 #41"
pm_spec_list() { [[ -z "$PM_SPEC_COMPLETE" ]] || printf '#%s' "${PM_SPEC_COMPLETE// / #}"; }
# 검증 결과 문자열에 붙일 꼬리 — 창에 이 티켓 말고 다른 병합이 있을 때만 ", covering #a #b …"
pm_cover() { [[ -z "$PM_PENDING" || "$(pm_list)" == "#$1" ]] || printf ', covering %s' "$(pm_list)"; }
# 미룬 병합 수 — "2/4"(창이 차면 돈다) 또는 POST_MERGE_EVERY=0이면 "2"(스펙·실행이 끝날 때만 돈다)
pm_of() { printf '%s' "$(pm_count)"; [[ "$POST_MERGE_EVERY" -eq 0 ]] || printf '/%s' "$POST_MERGE_EVERY"; }

pm_save() {
  [[ -n "${PM_STATE_FILE:-}" ]] || return 0
  if [[ -z "$PM_BASE" && -z "$PM_PENDING" && -z "$PM_SPEC_COMPLETE" ]]; then rm -f "$PM_STATE_FILE"; return 0; fi
  jq -Rn --arg base "$PM_BASE" --arg specs "$PM_SPEC_COMPLETE" '
    {base: (if $base == "" then null else $base end),
     pending: [inputs | split("\t") | select(length == 3 and .[0] != "")
               | {issue: (.[0] | tonumber), pr: (if .[1] == "" then null else (.[1] | tonumber) end), commit: (if .[2] == "" then null else .[2] end)}],
     spec_complete: ($specs | split(" ") | map(select(. != "") | tonumber))}' \
    <<<"$PM_PENDING" > "$PM_STATE_FILE" 2>/dev/null || log warn "could not save the post-merge check state (${PM_STATE_FILE})"
}

# 시작 때 지난 실행이 남긴 창을 읽는다. 창의 시작이 기본 브랜치에 없으면(강제 push 등) 시작만 버린다 — 병합들은 여전히 검증해야 한다
pm_load() {
  [[ -n "${PM_STATE_FILE:-}" && -f "$PM_STATE_FILE" ]] || return 0
  local base pending specs
  if ! base="$(jq -r '.base // ""' "$PM_STATE_FILE" 2>/dev/null)" \
     || ! pending="$(jq -r '.pending[]? | [(.issue | tostring), (.pr // "" | tostring), (.commit // "")] | join("\t")' "$PM_STATE_FILE" 2>/dev/null)" \
     || ! specs="$(jq -r '[.spec_complete[]? | tostring] | join(" ")' "$PM_STATE_FILE" 2>/dev/null)"; then
    log warn "post-merge check: unreadable state ${PM_STATE_FILE} — ignored"
    return 0
  fi
  if [[ -n "$base" ]]; then
    git -C "$ROOT" fetch -q origin "$BASE_BRANCH" 2>/dev/null || true
    if ! git -C "$ROOT" merge-base --is-ancestor "$base" "origin/${BASE_BRANCH}" 2>/dev/null; then
      log warn "post-merge check: the last passed commit ${base:0:7} is not on origin/${BASE_BRANCH} any more — bisecting a failure will not be possible until the next pass"
      base=""
    fi
  fi
  PM_BASE="$base"; PM_PENDING="$pending"; PM_SPEC_COMPLETE="$specs"
}

# 루프가 병합한 티켓을 창에 넣는다. $1 이슈 $2 PR $3 병합 커밋(모르면 빈 값). 창이 처음 열리면 시작은 그 병합의 부모다
pm_add() {
  local commit="${3:-}"
  if [[ -z "$PM_BASE" && -z "$PM_PENDING" && -n "$commit" ]]; then
    PM_BASE="$(git -C "$ROOT" rev-parse -q --verify "${commit}^1" 2>/dev/null || true)"
  fi
  PM_PENDING+="${PM_PENDING:+$'\n'}${1}"$'\t'"${2:-}"$'\t'"${commit}"
  pm_save
}

# 스펙 $1(없으면 0)이 끝났나 — 이번 실행이 그 스펙 이슈를 닫았다(close_spec_if_done). pm_due의 spec_end와 창에 적는 스펙 완료가 같은 조건을 쓴다
spec_closed_this_run() { [[ "${1:-0}" != 0 && " ${CLOSED_SPECS:-} " == *" $1 "* ]]; }

# 스펙 $1이 끝났으면 창에 적는다 — 창을 덮는 검증이 받는다(pm_exec). POST_MERGE_EVERY=1이면 스펙 끝의 검증도 이유가 every라 이유만으로는
# 모른다. 창이 비었어도 적는다 — 병합이 모두 검증을 거친 뒤에 닫힌 스펙은 루프 끝 검증(pm_flush_end)이 그 번호로 한 번 돈다(#34).
# 이번 실행에서 그 번호를 싣고 통과한 검증이 있었으면 적지 않는다. 검증이 꺼진 실행은 창을 건드리지 않는다
pm_spec_closed() {
  local spec="${1:-0}"
  [[ ${POST_MERGE:-0} -eq 1 && " ${PM_SPEC_COMPLETE} ${PM_SPEC_COVERED} " != *" ${spec} "* ]] && spec_closed_this_run "$spec" || return 0
  PM_SPEC_COMPLETE="${PM_SPEC_COMPLETE:+${PM_SPEC_COMPLETE} }${spec}"
  pm_save
}

# 검증이 $1 커밋에서 통과했다 — 창을 닫고 그 커밋이 다음 창의 시작이 된다. 그 검증이 받은 스펙은 덮였다(PM_SPEC_COVERED)
pm_passed() { PM_BASE="${1:-$PM_BASE}"; PM_SPEC_COVERED+="${PM_SPEC_COMPLETE:+ ${PM_SPEC_COMPLETE}}"; PM_PENDING=""; PM_SPEC_COMPLETE=""; pm_save; }

# 이번 병합 뒤에 검증을 돌릴 때인가. 창이 POST_MERGE_EVERY개 찼거나(0이면 이 조건은 없다), 이 티켓의 스펙이 끝났거나(이번 실행이 스펙 이슈를 닫음), 이번 실행의
# 마지막 티켓이면 0. 마지막인지는 다음 대상을 미리 계산해 본다 — 미룰 때는 그 목록을 메인 고리가 그대로 쓴다(NEXT_TARGETS, 같은 조회를 두 번
# 하지 않게). 검증을 돌린 뒤에는 메인 고리가 다시 계산한다(검증이 도는 동안 바뀌었을 수 있다). PM_WHY에 이유를, PM_WHY_KEY에 검증 명령이
# 받는 고정 값(every·spec_end·run_end — pm_exec)을 남긴다. $1 이슈 $2 스펙(없으면 0)
pm_due() {
  local n="$1" spec="${2:-0}" cand ctitle next=""
  PM_WHY=""; PM_WHY_KEY=""; NEXT_TARGETS_SET=0
  [[ -n "$PM_PENDING" ]] || return 1
  if [[ "$POST_MERGE_EVERY" -gt 0 && "$(pm_count)" -ge "$POST_MERGE_EVERY" ]]; then
    PM_WHY="every ${POST_MERGE_EVERY} merged ticket$([[ $POST_MERGE_EVERY -eq 1 ]] || echo s)"; PM_WHY_KEY=every; return 0
  fi
  if spec_closed_this_run "$spec"; then PM_WHY="spec #${spec} complete"; PM_WHY_KEY=spec_end; return 0; fi
  if [[ ${MAX:-0} -gt 0 && $(( ${done_count:-0} + 1 )) -ge ${MAX:-0} ]] \
     || [[ ${#TICKETS[@]} -gt 0 && $(( ${done_count:-0} + 1 )) -ge ${#TICKETS[@]} ]]; then
    PM_WHY="last ticket of this run"; PM_WHY_KEY=run_end; return 0
  fi
  if [[ ${#TICKETS[@]} -eq 0 ]]; then
    # 조회가 실패하거나, 두 번 다 빈 목록인데 스펙에 열린 하위 이슈가 남으면(pick_next_targets 2) 미룬다 — 빈 목록을 "남은 티켓 없음"으로
    # 읽어 검증을 앞당기지 않게(#8·#22). 메인 고리가 다시 계산하고, 대상 없이 끝나면 루프 끝 검증(pm_flush_end)이 덮는다
    if ! NEXT_TARGETS="$(pick_next_targets </dev/null)"; then NEXT_TARGETS=""; return 1; fi
    while IFS=$'\t' read -r cand ctitle; do
      [[ -n "$cand" && "$cand" != "$n" && " ${PROCESSED:-} " != *" ${cand} "* ]] || continue
      next="$cand"; break
    done <<<"$NEXT_TARGETS"
    if [[ -z "$next" ]]; then PM_WHY="no more tickets"; PM_WHY_KEY=run_end; return 0; fi
    NEXT_TARGETS_SET=1
  fi
  return 1
}

# 검증 명령 하나를 검증 워크트리 $1에서 돌린다 — bg_wait로 부르고 출력은 검증 로그로 보낸다. $2 명령, $3 첫 실행 로그(재실행·이분 탐색이
# POST_MERGE_FAILED_LOG로 받는다). 왜 도는지와 창이 끝낸 스펙을 env로 넘기고(머리 주석 POST_MERGE_CMD, #32) 로그 첫 줄에 남긴다.
# 재실행·이분 탐색·수습 뒤 재검증도 같은 창이라 같은 값이다 — 실패한 검증과 같은 조건으로 다시 돈다
pm_exec() {
  local vars=("TICKET_LOOP_POST_MERGE_WHY=${PM_WHY_KEY}" "TICKET_LOOP_POST_MERGE_SPEC_COMPLETE=${PM_SPEC_COMPLETE}")
  [[ -z "${3:-}" ]] || vars+=("POST_MERGE_FAILED_LOG=$3")
  printf '# ticket-loop: TICKET_LOOP_POST_MERGE_WHY="%s" TICKET_LOOP_POST_MERGE_SPEC_COMPLETE="%s"\n' "$PM_WHY_KEY" "$PM_SPEC_COMPLETE"
  env "${vars[@]}" bash -c 'cd "$1" && exec bash -c "$2"' _ "$1" "$2"
}

# 이분 탐색의 한 번 — 검증 워크트리를 $3 커밋으로 옮겨 POST_MERGE_RETRY_CMD를 첫 실행 로그($4)와 함께 돌린다.
# 반환 0 통과, 1 실패, 2 포트가 끝내 안 빔, 3 그 커밋으로 옮기지 못함
pm_probe() {
  local n="$1" wt="$2" c="$3" failed_log="$4" plog rc=0
  git -C "$wt" checkout -q -f --detach "$c" 2>/dev/null || return 3   # 루프의 검증 워크트리다 — 지난 실행이 남긴 변경은 버린다
  wait_post_merge_port "$n" || return 2
  plog="${failed_log%.log}-bisect-${c:0:7}.log"
  phase post
  bg_wait pm_exec "$wt" "$POST_MERGE_RETRY_CMD" "$failed_log" >"$plog" 2>&1 || rc=$?
  phase ""
  log "#${n}: failed tests at ${c:0:7} $(git -C "$wt" log -1 --format=%s "$c" 2>/dev/null | cut -c1-60) — $([[ $rc -eq 0 ]] && echo pass || echo fail) (log ${plog})"
  [[ $rc -eq 0 ]] || return 1
}

# 이분 탐색이 찾은 커밋을 사람이 읽는 꼴로 — 창의 병합이면 "#이슈 (PR #P, 커밋)", 아니면(사람이 병합한 것 등) "커밋 제목"
pm_describe() {
  local line issue pr pc
  while IFS= read -r line; do   # 탭 IFS로 read 하면 빈 칸(PR을 모름)이 붙어 버린다 — 직접 자른다
    issue="${line%%$'\t'*}"; pc="${line#*$'\t'}"; pr="${pc%%$'\t'*}"; pc="${pc#*$'\t'}"
    [[ -z "$pc" || "$pc" != "$1" ]] || { printf '#%s (%scommit %s)' "$issue" "${pr:+PR #${pr}, }" "${1:0:7}"; return 0; }
  done <<<"$PM_PENDING"
  printf 'commit %s %s' "${1:0:7}" "$(git -C "$2" log -1 --format=%s "$1" 2>/dev/null)"
}

# 묶어 돌린 검증이 재실행까지 실패했을 때 처음 실패하는 병합을 찾는다. 실패한 테스트만 다시 돌리는 명령(POST_MERGE_RETRY_CMD — 1~2분)을
# 창의 시작에서 한 번(통과해야 탐색이 성립한다 — 거기서도 실패하면 플레이크·환경, 또는 그 명령이 테스트를 못 고른 것), 그다음 PM_BASE..끝의
# 첫 부모 커밋들을 이분 탐색한다(끝은 방금 재실행이 실패했다). 전체 스위트(한 번에 수십 분)로는 탐색하지 않는다 — 그때는 묶음만 적고
# 원인 찾기는 무인 수습에 맡긴다. 결과는 PM_BISECT(사유에 붙일 문장)와 PM_FIRST_FAILING(커밋). 검증 워크트리는 끝 커밋으로 되돌린다
pm_bisect() {
  local n="$1" wt="$2" failed_log="$3" head c lo hi mid rc=0 base_rc=0 commits=()
  PM_BISECT=""; PM_FIRST_FAILING=""
  [[ -n "$POST_MERGE_RETRY_CMD" && -n "$PM_BASE" ]] || return 0
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 0
  git -C "$wt" merge-base --is-ancestor "$PM_BASE" "$head" 2>/dev/null || return 0
  while IFS= read -r c; do [[ -z "$c" ]] || commits+=("$c"); done < <(git -C "$wt" rev-list --first-parent --reverse "${PM_BASE}..${head}" 2>/dev/null)
  [[ ${#commits[@]} -ge 2 ]] || return 0
  log step "#${n}: finding the first failing merge — rerunning the failed tests at ${#commits[@]} merges since ${PM_BASE:0:7} (bisect, POST_MERGE_RETRY_CMD)"
  pm_probe "$n" "$wt" "$PM_BASE" "$failed_log" || base_rc=$?
  if [[ $base_rc -eq 0 ]]; then
    lo=0; hi=$(( ${#commits[@]} - 1 ))
    while [[ $lo -lt $hi ]]; do
      mid=$(( (lo + hi) / 2 )); rc=0
      pm_probe "$n" "$wt" "${commits[$mid]}" "$failed_log" || rc=$?
      [[ $rc -le 1 ]] || break
      if [[ $rc -eq 0 ]]; then lo=$(( mid + 1 )); else hi=$mid; fi
    done
  fi
  git -C "$wt" checkout -q -f --detach "$head" 2>/dev/null || log warn "#${n}: could not move the check worktree back to ${head:0:7}"
  if [[ $base_rc -eq 2 || $rc -eq 2 ]]; then
    PM_BISECT="first failing merge not found: port ${POST_MERGE_PORT} did not free up"
  elif [[ $base_rc -eq 3 || $rc -eq 3 ]]; then
    PM_BISECT="first failing merge not found: could not check out a commit in the check worktree"
  elif [[ $base_rc -ne 0 ]]; then
    PM_BISECT="first failing merge not found: the failed tests fail at ${PM_BASE:0:7} (last passed) too — flaky, environment, or the retry command could not pick them"
  else
    PM_FIRST_FAILING="${commits[$lo]}"
    PM_BISECT="first failing merge: $(pm_describe "$PM_FIRST_FAILING" "$wt")"
  fi
  log warn "#${n}: ${PM_BISECT}"
}

# 스펙 리포트·멈춤 기록에 싣는 창 — 병합도 스펙 완료도 없으면 null
pm_window_json() {
  [[ -n "$PM_PENDING" || -n "$PM_SPEC_COMPLETE" ]] || { echo null; return 0; }
  jq -Rnc --arg base "$PM_BASE" --arg bisect "$PM_BISECT" --arg first "$PM_FIRST_FAILING" --arg specs "$PM_SPEC_COMPLETE" '
    def str: if . == "" then null else . end;
    {base: ($base | str), first_failing_commit: ($first | str), bisect: ($bisect | str),
     pending: [inputs | split("\t") | select(length == 3 and .[0] != "")
               | {issue: (.[0] | tonumber), pr: (if .[1] == "" then null else (.[1] | tonumber) end), commit: (.[2] | str)}],
     spec_complete: ($specs | split(" ") | map(select(. != "") | tonumber))}' <<<"$PM_PENDING"
}

# POST_MERGE_PORT가 비기를 기다린다. 반환 0: 비었음(포트 설정이 없으면 바로), 1: PORT_WAIT_SEC 안에 비지 않음.
# 첫 실행과 재실행이 같이 쓴다 — 첫 실행이 띄운 서버가 명령이 끝난 뒤에도 포트를 늦게 놓을 수 있다
wait_post_merge_port() {
  local n="$1" port_deadline holder
  [[ -n "$POST_MERGE_PORT" ]] || return 0
  port_deadline=$(( $(date +%s) + PORT_WAIT_SEC ))
  # 기다리는 동안 아무것도 찍지 않으면 루프가 멈춘 것처럼 보인다(실측: 사람이 띄운 개발 서버가 포트를 쥔 채 4분을
  # 조용히 기다렸다). 처음 한 번 점유 프로세스와 기한을 적는다 — 그 서버를 끄면 30초 안에 이어 간다
  if port_in_use "$POST_MERGE_PORT"; then
    holder="$(port_holder "$POST_MERGE_PORT")"
    log warn "#${n}: port ${POST_MERGE_PORT} in use (${holder:-?}) — waiting for it to free up until $(fmt_epoch "$port_deadline"). Stop that server and the loop continues right away"
  fi
  while port_in_use "$POST_MERGE_PORT"; do
    [[ "$(date +%s)" -lt "$port_deadline" ]] || { log warn "#${n}: port ${POST_MERGE_PORT} did not free up — keep it free while the loop runs, or use --skip-post-merge"; return 1; }
    sleep 30
  done
}

# 반환 0: 통과(재실행에서 통과한 것 포함), 1: 실패(로그 꼬리를 남긴다). $2 로그 이름에 붙일 꼬리표 — 무인 수습 뒤 다시 돌릴 때
# (post-merge-N-after-triage.log) 앞 실행의 로그를 덮지 않게
run_post_merge() {
  local n="$1" tag="${2:-}" wt logfile retry_log started first_sec retry_sec f head cover
  wt="$(post_merge_worktree_path)"
  POST_MERGE_WT="$wt"
  POST_MERGE_RESULT="did not start"   # 검증 명령을 돌리기 전에 끝나면(워크트리·포트) 이 값이 남는다
  POST_MERGE_WHY="$PM_WHY_KEY"; POST_MERGE_SPEC_COMPLETE="$PM_SPEC_COMPLETE"   # 기록용(record_ticket) — 통과하면 창과 함께 비므로 떠 둔다
  PM_BISECT=""; PM_FIRST_FAILING=""   # 앞 검증의 이분 탐색 결과가 이번 멈춤 사유에 섞이지 않게
  if [[ ! -d "$wt/.git" && ! -f "$wt/.git" ]]; then
    mkdir -p "$(dirname "$wt")"
    git -C "$ROOT" worktree add -q --detach "$wt" "origin/${BASE_BRANCH}" || { log warn "#${n}: failed to create the post-merge check worktree (${wt})"; return 1; }
  fi
  git -C "$ROOT" fetch -q origin "$BASE_BRANCH"
  git -C "$wt" checkout -q --detach "origin/${BASE_BRANCH}" || { log warn "#${n}: failed to move the check worktree to origin/${BASE_BRANCH}"; return 1; }
  head="$(git -C "$wt" rev-parse HEAD)"
  cover="$(pm_cover "$n")"   # 묶어 돌리면(POST_MERGE_EVERY) 이 검증이 덮는 병합들
  for f in $POST_MERGE_COPY; do
    [[ ! -f "$MAIN_WT/$f" ]] || cp "$MAIN_WT/$f" "$wt/$f"
  done
  wait_post_merge_port "$n" || return 1
  # 검증 로그는 LOG_FILE과 같은 디렉터리(절대 경로 — 아래 리다이렉트는 cd 한 뒤의 서브셸에서 열리므로 상대 경로면 워크트리 안에 생긴다)
  logfile="${TMPDIR:-/tmp}/ticket-loop-post-merge-${n}${tag}.log"
  [[ "$LOG_FILE" == "/dev/null" ]] || logfile="$(dirname "$LOG_FILE")/post-merge-${n}${tag}.log"
  POST_MERGE_LOG="$logfile"; POST_MERGE_RETRY_LOG=""
  mkdir -p "$(dirname "$logfile")"
  started="$(date +%s)"
  log step "#${n}: post-merge check started (${wt}, log ${logfile})"
  [[ -z "$cover" ]] || log step "#${n}: this check covers the merged tickets ${cover#, covering }${PM_WHY:+ (${PM_WHY})}"
  phase post   # 명령이 도는 동안만(포트 대기는 빼고) — 리포트의 병합 뒤 검증 시간
  if bg_wait pm_exec "$wt" "$POST_MERGE_CMD" >"$logfile" 2>&1; then
    phase ""
    POST_MERGE_RESULT="passed in $(( $(date +%s) - started ))s${cover}"
    log ok "#${n}: post-merge check ${POST_MERGE_RESULT}"
    pm_passed "$head"
    return 0
  fi
  phase ""
  first_sec=$(( $(date +%s) - started ))
  POST_MERGE_RESULT="failed in ${first_sec}s${cover}"
  log warn "#${n}: post-merge check failed — tail ---"; tail -n 40 "$logfile" | dim_lines || true
  [[ -n "$POST_MERGE_RETRY_CMD" ]] || return 1
  # 재실행은 딱 한 번, 같은 워크트리에서. 무거운 스위트는 그 병합과 무관하게 아무 테스트나 가끔 시간 초과로 깨진다(실측: rental-portal
  # 44분 통합 테스트 7회 중 2회, 매번 다른 테스트 하나 — 그것만 다시 돌리면 통과할 성격이었다). 무엇을 다시 돌릴지는 재실행 명령이
  # 첫 실행 로그(POST_MERGE_FAILED_LOG)를 보고 정한다. 키트는 테스트 도구를 모르므로 그 판단을 저장소 쪽 명령에 맡긴다
  wait_post_merge_port "$n" || return 1
  retry_log="${logfile%.log}-retry.log"
  POST_MERGE_RETRY_LOG="$retry_log"
  started="$(date +%s)"
  log step "#${n}: retrying the post-merge check once (log ${retry_log})"
  phase post
  if bg_wait pm_exec "$wt" "$POST_MERGE_RETRY_CMD" "$logfile" >"$retry_log" 2>&1; then
    phase ""
    retry_sec=$(( $(date +%s) - started ))
    POST_MERGE_RESULT="passed on retry in ${retry_sec}s (first run failed in ${first_sec}s)${cover}"
    log warn "#${n}: post-merge check ${POST_MERGE_RESULT} — likely flaky, continuing"
    post_merge_flaky_record "$n" "$logfile" "$retry_log" "$first_sec" "$retry_sec"
    pm_passed "$head"
    return 0
  fi
  phase ""
  POST_MERGE_RESULT="failed on retry in $(( $(date +%s) - started ))s (first run failed in ${first_sec}s)${cover}"
  log warn "#${n}: post-merge retry failed too — tail ---"; tail -n 40 "$retry_log" | dim_lines || true
  # 여러 병합을 묶어 돌렸으면 처음 실패하는 병합을 찾는다(재실행이 실패한 테스트를 골라 돌릴 수 있을 때만 — pm_bisect)
  if [[ -n "$cover" ]]; then
    pm_bisect "$n" "$wt" "$logfile"
    [[ -z "$PM_BISECT" ]] || POST_MERGE_RESULT+="; ${PM_BISECT}"
  fi
  return 1
}

# 병합 뒤 검증 실패 뒤처리 — 멈추기 전에 무인 수습을 띄운다(post_merge_failed). 수정 PR이 병합되면(또는 플레이크로 판정하면) 병합된 기본
# 브랜치로 검증을 다시 돌리고(로그 post-merge-N-after-triage.log) 통과하면 0(이어 간다). 아니면 1, 멈출 사유는 PM_REASON.
# 재실행까지 실패했으면 두 로그를 다 적는다. 재실행이 실패한 테스트를 못 찾아 끝냈을 수도, 같은 플레이크가 또 났을 수도 있어 판단은
# 수습 세션(또는 사람)이 한다. 여러 병합을 묶어 돌렸으면 묶음과 이분 탐색 결과를, 창이 빈 스펙 끝 검증(pm_flush_end)이면 그렇다고
# 사유에 적는다 — 수습 세션은 멈춤 기록의 post_merge_window에서 같은 것을 읽는다
post_merge_recover() {
  local n="$1" reason scope="" first_result post_rc=0
  [[ -z "$(pm_cover "$n")" ]] || scope=" (merges checked together: $(pm_list)${PM_BISECT:+ — ${PM_BISECT}})"
  [[ -n "$PM_PENDING" || -z "$PM_SPEC_COMPLETE" ]] || scope=" (spec-end check for spec $(pm_spec_list) — no merge was left unchecked)"
  if [[ -z "$POST_MERGE_RETRY_LOG" ]]; then
    reason="#${n}: post-merge check failed on the merged ${BASE_BRANCH}${scope}. Check the log (${POST_MERGE_LOG}) and the check worktree ($(post_merge_worktree_path)), then rerun after a fix PR."
  else
    reason="#${n}: post-merge check failed on the merged ${BASE_BRANCH}${scope}, and again on retry. Check the logs (first run ${POST_MERGE_LOG}, retry ${POST_MERGE_RETRY_LOG}) and the check worktree ($(post_merge_worktree_path)). If it looks like a flake, just rerun; otherwise rerun after a fix PR."
  fi
  STOP_KIND=post_merge_failed
  if triage post_merge_failed "$reason"; then
    first_result="$POST_MERGE_RESULT"
    run_post_merge "${n}" -after-triage || post_rc=$?
    POST_MERGE_RESULT="${first_result}; after triage${TRIAGE_FIX_PR:+ (fix PR #${TRIAGE_FIX_PR})}: ${POST_MERGE_RESULT}"
    if [[ $post_rc -ne 0 ]]; then
      STOP_KIND=post_merge_failed
      reason="#${n}: post-merge check failed again after triage${TRIAGE_FIX_PR:+ (fix PR #${TRIAGE_FIX_PR} merged)}. Check the logs (${POST_MERGE_LOG}${POST_MERGE_RETRY_LOG:+, retry ${POST_MERGE_RETRY_LOG}}) and the check worktree ($(post_merge_worktree_path))."
    fi
  else
    reason+="$TRIAGE_NOTE"; post_rc=1
  fi
  PM_REASON="$reason"
  return $post_rc
}

# 루프가 끝날 때 창에 병합이 남았으면 검증한다 — 마지막 티켓 뒤에 돌리지 못한 경우(다음 대상이 있다고 봤는데 고리가 대상 없이 끝남,
# 지난 실행이 멈추며 남긴 창에 이번 실행이 처리할 티켓이 없음). 창이 비었어도 스펙 완료가 적혀 있으면 기본 브랜치 끝에서 한 번 돈다(#34) —
# 병합이 모두 검증을 거친 뒤에 닫힌 스펙(POST_MERGE_EVERY=1에서 사람이 마지막 티켓을 닫음·하위 이슈 반영 지연). 그때 이유는 spec_end다.
# 어느 티켓의 기록에도 들지 않는다(로그·Slack에만 남는다). 실패하면 창의 마지막 티켓(창이 비었으면 마지막 스펙 이슈)으로 멈춘다
pm_flush_end() {
  [[ $POST_MERGE -eq 1 && ( -n "$PM_PENDING" || -n "$PM_SPEC_COMPLETE" ) ]] || return 0
  local n pr=""
  if [[ -n "$PM_PENDING" ]]; then
    n="$(tail -n 1 <<<"$PM_PENDING" | cut -f1)"; pr="$(tail -n 1 <<<"$PM_PENDING" | cut -f2)"
    PM_WHY="end of run"; PM_WHY_KEY=run_end
    log step "post-merge check for the merged tickets not checked yet ($(pm_list))"
  else
    n="${PM_SPEC_COMPLETE##* }"
    PM_WHY="spec $(pm_spec_list) complete"; PM_WHY_KEY=spec_end
    log step "post-merge check for the completed spec $(pm_spec_list) — no passed check has covered it yet"
  fi
  STOP_ISSUE="$n"; STOP_KIND=""; STOP_RECORD=""; TRIAGE_RESULT=""
  # 멈춤 기록·GitHub 기록이 앞 티켓의 PR·시작 시각·워크트리를 싣지 않게 — 창의 마지막 병합(창이 비었으면 마지막 스펙 이슈)으로 채운다
  CUR_PR="$pr"; CUR_TITLE="$(issue_title "$n" 2>/dev/null || true)"; CUR_STARTED=""; WT_PATH=""
  POST_MERGE_RESULT=""; POST_MERGE_LOG=""; POST_MERGE_RETRY_LOG=""; POST_MERGE_WHY=""; POST_MERGE_SPEC_COMPLETE=""
  if ! run_post_merge "$n" -end; then
    post_merge_recover "$n" || die "$PM_REASON"
  fi
  log ok "post-merge check at the end of the run: ${POST_MERGE_RESULT}"
  STOP_ISSUE=""
}

# ---------- 무인 수습 ----------
# 멈출 일이 생긴 자리 네 곳(머리 주석 "무인 수습" 절)에서 바로 die하지 않고 triage를 부른다. 수습 세션은 워커와 같은 길
# (backend_worktree_create)로 새 워크트리에 띄운 에이전트이고, 할 일은 기본 브랜치에 커밋된 loop-triage 스킬이 정한다(멈춤 기록을 읽고
# 분류 → 고치거나 진단 → 판정 파일). 루프는 판정 파일만 보고, 수정 PR은 티켓 PR처럼 CI 뒤에 병합한다 — 수습 세션은 병합하지 않는다.
# 이어 가는 곳은 멈춘 그 자리다. 처음부터 다시 실행하면 진행 중인 티켓(PR이 열렸거나 담당자가 붙은)을 자동 선택이 건너뛰어 버린다.
# 루프 스크립트 자체(키트 관리 파일)는 수습 세션이 고치지 않는다 — 루프 버그는 진단과 키트 버그 보고서까지만 하고 멈춘다

TRIAGE_USED=0; TRIAGE_KEYS=""; TRIAGE_NOTE=""; TRIAGE_RESULT=""; TRIAGE_FIX_PR=""

triage_skill_on_base() { git -C "$ROOT" cat-file -e "origin/${BASE_BRANCH}:.agents/skills/loop-triage/SKILL.md" 2>/dev/null; }

# 한 줄로 보낸다(워커 프롬프트와 같은 이유). 무인 실행에서만 참인 것 — 질문 금지, 병합 금지, 판정 파일 — 만 둔다. 절차는 스킬이 단일 진실이다
triage_prompt() {
  printf '%s' "${SKILL_PREFIX}loop-triage $1 — 무인 루프(ticket-loop.sh)가 멈춘 지점에서 띄운 수습 세션이다. 사람이 답할 수 없으니 사람에게 묻거나 확인을 구하지 말고(질문 도구도 쓰지 말고) 스스로 판단해 끝까지 진행해라. PR은 병합하지 마라 — 루프가 CI 뒤에 병합한다. 마지막에 판정을 $2 에 써라."
}

# 수습 세션의 워크트리와 에이전트를 띄운다. bg_wait로(백그라운드 서브셸에서) 부른다 — 백엔드 함수는 실패하면 die하는데, 여기서의 실패가
# 원래 멈춤 사유를 덮으면 안 되므로 die를 "이 서브셸만 끝냄"으로 바꾼다(EXIT trap은 서브셸에 이어지지 않는다).
# 결과(WT, WT_PATH, WT_BRANCH, HANDLE)를 $4 파일에 탭으로 쓴다
triage_spawn() {
  local n="$1" prompt="$2" name="$3" out="$4"
  set -e
  die() { log warn "#${n}: triage session did not start — $*"; exit 1; }
  WT=""; WT_PATH=""; WT_BRANCH=""; HANDLE=""
  backend_worktree_create "$n" "$prompt" "$name"
  ensure_agent_started "$n" "$HANDLE" "$prompt"
  printf '%s\t%s\t%s\t%s\n' "$WT" "$WT_PATH" "$WT_BRANCH" "$HANDLE" > "$out"
}

verdict_written() { jq -e '.verdict == "resume" or .verdict == "halt"' "$1" >/dev/null 2>&1; }

# 수습 세션이 판정 파일을 쓸 때까지 기다린다 — wait_for_pr와 같은 틀(idle 연속 IDLE_STRIKES번이면 판정 없이 멈춘 것, 그사이 화면이 바뀌면
# 새로 센다). bg_wait로 부른다. 진행 로그는 수습 워크트리를 본다("#N triage: commit …").
# 반환: 0 판정 있음, 1 판정 없이 멈춤, 2 시간 초과, 3 터미널 끊김
wait_for_verdict() {
  local n="$1" handle="$2" vfile="$3" deadline="$4" wt_path="$5" strikes=0 started idle last_screen="" screen wait_ms active_said=0
  started="$(date +%s)"; wait_ms="$(idle_wait_ms)"; PROMPT_SUM=""; PROMPT_AT=0
  [[ "$PROGRESS_SEC" -le 0 ]] || progress_reset "$wt_path"
  while :; do
    if verdict_written "$vfile"; then
      terminal_idle "$handle" 120000 || true   # 판정을 쓴 뒤 마무리(코멘트 등)가 끝나도록 잠깐
      return 0
    fi
    [[ "$(date +%s)" -lt "$deadline" ]] || return 2
    idle=0; terminal_idle "$handle" "$wait_ms" || idle=$?
    [[ $idle -ne 3 ]] || return 3
    [[ "$PROGRESS_SEC" -le 0 ]] || progress_check "${n} triage"
    if [[ $idle -eq 0 ]]; then
      if [[ $(( $(date +%s) - started )) -lt $STARTUP_GRACE_SEC ]]; then sleep "$IDLE_RECHECK_SEC"; continue; fi
      sleep "$IDLE_RECHECK_SEC"
      ! verdict_written "$vfile" || continue
      screen="$(terminal_tail "$handle" | cksum | cut -d' ' -f1)"
      if [[ "$screen" != "$last_screen" ]]; then strikes=0; last_screen="$screen"; fi
      if session_active_recently "$wt_path"; then   # 수습 세션의 기록이 방금 갱신됐으면 아직 일하는 중 — strike를 세지 않는다
        [[ $active_said -eq 1 ]] || log "#${n}: idle reported, but the session log was written ${SESSION_LOG_AGE}s ago — still working"
        strikes=0; active_said=1
      else
        active_said=0
        ! screen_check "$handle" "triage session" 1 || return 1   # 수습 세션도 같은 한도에 걸린다 — "판정 없이 멈춤"이 아니라 usage_limit로
        strikes=$((strikes + 1))
        log warn "#${n}: triage session idle, no verdict (${strikes}/${IDLE_STRIKES})"
        [[ ${strikes} -lt $IDLE_STRIKES ]] || return 1
      fi
      sleep "$IDLE_RECHECK_SEC"
    else
      strikes=0; active_said=0
      ! screen_check "$handle" "triage session" 0 || return 1
    fi
  done
}

# 수습 세션이 낸 수정 PR을 티켓 PR처럼 병합한다 — 기본 브랜치로 가는 열린 PR인지 보고, TRIAGE_LABEL을 붙이고, CI를 기다려 병합한다.
# 반환 1이면 TRIAGE_NOTE에 이유를 남긴다
triage_merge_fix_pr() {
  local pr="$1" info state base head
  info="$(gh pr view "$pr" --json state,baseRefName,headRefName 2>/dev/null)" || { TRIAGE_NOTE=" (fix PR #${pr} not found)"; return 1; }
  state="$(jq -r .state <<<"$info")"; base="$(jq -r .baseRefName <<<"$info")"; head="$(jq -r .headRefName <<<"$info")"
  [[ "$state" == OPEN && "$base" == "$BASE_BRANCH" ]] \
    || { TRIAGE_NOTE=" (fix PR #${pr} is not an open PR into ${BASE_BRANCH}: ${state}, base ${base})"; return 1; }
  gh label create "$TRIAGE_LABEL" --color 1D76DB --description "ticket-loop 무인 수습이 낸 수정 PR" </dev/null >/dev/null 2>&1 || true
  gh pr edit "$pr" --add-label "$TRIAGE_LABEL" </dev/null >/dev/null 2>&1 || log warn "fix PR #${pr}: failed to add the ${TRIAGE_LABEL} label"
  if ci_expected "$pr"; then
    log step "triage: waiting for CI (fix PR #${pr})"
    ci_passed "$pr" || { TRIAGE_NOTE=" (fix PR #${pr}: CI failed — gh pr checks ${pr})"; return 1; }
    log ok "triage: fix PR #${pr} CI passed"
  else
    log step "triage: fix PR #${pr} excluded by the repository CI path filter — merging without checks"
  fi
  merge_pr "$pr" || { TRIAGE_NOTE=" (fix PR #${pr}: merge failed${MERGE_ERR:+ — ${MERGE_ERR}})"; return 1; }
  log ok "triage: fix PR #${pr} merged"
  git -C "$ROOT" push -q origin --delete "$head" >/dev/null 2>&1 || true
  git -C "$ROOT" fetch -q origin "$BASE_BRANCH" || true
}

# 수정 PR의 병합 커밋이 처리 중인 티켓 이슈를 닫았으면 다시 연다 — 병합 뒤 검증 실패가 아니면 그 티켓은 아직 진행 중이다. GitHub는
# 기본 브랜치에 들어온 커밋 메시지의 닫기 키워드(병합 커밋에는 PR 제목이 들어간다 — `fix: #17 …`)로 이슈를 닫는다. 실측(0.9.0, 더미
# 저장소): 준비 실패의 수정 PR #18 병합 커밋이 #17을 닫았고, 워커가 알아채 다시 열었다. 스킬이 그런 제목을 막지만 커밋 메시지까지
# 다 막는다는 보장은 없다. 닫힘은 병합 몇 초 뒤에 일어나므로 REOPEN_WATCH_SEC 간격으로 다섯 번 본다
triage_keep_issue_open() {
  local n="$1" pr="$2" i state=""
  for i in 1 2 3 4 5; do
    state="$(gh issue view "$n" --json state -q .state </dev/null 2>/dev/null || true)"
    [[ "$state" != CLOSED && $i -lt 5 ]] || break
    sleep "$REOPEN_WATCH_SEC"
  done
  [[ "$state" == CLOSED ]] || return 0
  log warn "#${n}: merging fix PR #${pr} closed the issue — reopening it (the ticket is still in progress)"
  gh issue reopen "$n" --comment "ticket-loop 무인 수습: 수정 PR #${pr}의 병합 커밋이 이 이슈를 닫아 다시 연다. 티켓은 아직 진행 중이다 — 루프가 이어 간다." \
    </dev/null >/dev/null 2>&1 || log warn "#${n}: failed to reopen the issue — reopen it by hand (gh issue reopen ${n})"
}

# 메인 체크아웃이 기본 브랜치에 있으면 fast-forward한다 — WORKTREE_SETUP_CMD가 메인 체크아웃의 스크립트를 부르는 저장소에서도 수정 PR이
# 반영되게(예: "$LOOP_ROOT_PATH/scripts/worktree-setup.sh"). git은 로컬 변경을 덮는 merge를 거부하므로 사람의 미커밋 변경은 그대로다
sync_main_checkout() {
  local cur
  cur="$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$cur" != "$BASE_BRANCH" ]]; then
    log warn "main checkout is on ${cur:-?}, not ${BASE_BRANCH} — left as is (files the setup reads from it are not updated)"
  elif git -C "$MAIN_WT" merge --ff-only -q "origin/${BASE_BRANCH}" 2>/dev/null; then
    log step "main checkout fast-forwarded to origin/${BASE_BRANCH}"
  else
    log warn "main checkout could not fast-forward to origin/${BASE_BRANCH} (local changes in the way, or diverged) — left as is"
  fi
}

# triage 종류 사유 — 멈출 자리에서 수습 세션을 띄우고 판정을 기다린다. 반환 0: 고쳐졌으니 멈춘 자리에서 이어 간다(이어 갈 수 있는 종류의
# resume만), 1: 멈춘다 — 부른 쪽이 사유 뒤에 TRIAGE_NOTE(판정 요약, 또는 띄우지 않은 이유)를 붙여 die한다.
# 띄우지 않는 경우: LOOP_TRIAGE=0, 잠금을 안 잡은 실행, 이 실행에서 TRIAGE_MAX번을 다 씀, 같은 멈춤(종류·이슈)에 이미 띄움, 기본 브랜치에
# loop-triage 스킬이 아직 없음. TRIAGE_RESULT(티켓 기록·스펙 리포트), TRIAGE_FIX_PR(병합한 수정 PR)을 남긴다
triage() {
  local kind="$1" reason="$2" n="${STOP_ISSUE:-0}" resumable=0 key stopfile vfile prompt name tmp deadline rc=0 why
  local t_wt="" t_path="" t_branch="" t_handle="" saved_state="${TMUX_STATE_FILE:-}"
  local verdict category summary fix_pr pushed kit_bug action action_ko
  TRIAGE_NOTE=""; TRIAGE_FIX_PR=""
  # usage_limit는 띄우지 않는 쪽(*) — 수습 세션도 같은 한도에 걸린다. 사람이 터미널에서 잇거나 한도가 풀린 뒤 루프를 다시 돌린다
  case "$kind" in post_merge_failed|ci_failed|setup_failed) resumable=1 ;; worker_no_pr) ;; *) return 1 ;; esac
  [[ "$LOOP_TRIAGE" == 1 && $LOCK_HELD -eq 1 ]] || return 1
  key="${kind}#${n}"
  if [[ " ${TRIAGE_KEYS} " == *" ${key} "* ]]; then TRIAGE_NOTE=" (triage already ran for this stop)"; return 1; fi
  if [[ $TRIAGE_USED -ge $TRIAGE_MAX ]]; then TRIAGE_NOTE=" (no triage: ${TRIAGE_USED}/${TRIAGE_MAX} used in this run)"; return 1; fi
  git -C "$ROOT" fetch -q origin "$BASE_BRANCH" 2>/dev/null || true
  if ! triage_skill_on_base; then
    log warn "#${n}: no triage — the loop-triage skill is not on origin/${BASE_BRANCH} yet (merge the kit install PR)"
    TRIAGE_NOTE=" (no triage: loop-triage skill not on origin/${BASE_BRANCH})"; return 1
  fi
  TRIAGE_USED=$((TRIAGE_USED + 1)); TRIAGE_KEYS="${TRIAGE_KEYS} ${key}"
  STOP_KIND="$kind"
  stopfile="$(write_stop_record "$kind" "$reason" unattended)" \
    || { log warn "#${n}: no triage — could not write the stop record"; TRIAGE_NOTE=" (no triage: stop record not written)"; return 1; }
  STOP_RECORD="$stopfile"; vfile="${stopfile%.json}.verdict.json"
  log warn "#${n}: stopping — ${reason}"
  log step "#${n}: triage — starting a session (stop record ${stopfile#"$ROOT"/})"
  sleep 1   # 로그 파일은 tee가 비동기로 쓴다 — 위 줄이 Slack 꼬리에 들어가게
  notify "Ticket loop stopped — triage started" "$reason" triage "$(run_log | tail -n 12)"

  name="loop-triage-${n}-$(date +%H%M%S)"
  prompt="$(triage_prompt "$stopfile" "$vfile")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-triage-${n}.XXXXXX")"
  if ! bg_wait triage_spawn "$n" "$prompt" "$name" "$tmp" || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    TRIAGE_NOTE=" (triage session did not start — see the loop log)"; TRIAGE_RESULT="no session"
    return 1
  fi
  IFS=$'\t' read -r t_wt t_path t_branch t_handle < "$tmp"; rm -f "$tmp"
  CUR_AGENT_PATHS+="${t_path}"$'\n'   # 수습 세션의 토큰도 그 티켓에 센다
  [[ "$BACKEND" != tmux ]] || TMUX_STATE_FILE="$TMUX_DIR/state/$(basename "$t_path")"   # tmux_* 가 보는 훅 상태 파일 — 끝나면 되돌린다
  backend_set_status "$t_wt" in-progress || true
  log step "#${n}: triage session ${t_wt} (${t_path}) / terminal ${t_handle} — waiting for a verdict (up to $((TRIAGE_TIMEOUT_SEC / 60))m)"
  deadline=$(( $(date +%s) + TRIAGE_TIMEOUT_SEC ))
  wait_stop_reset
  bg_wait wait_for_verdict "$n" "$t_handle" "$vfile" "$deadline" "$t_path" || rc=$?
  if [[ $rc -ne 0 ]]; then
    wait_stop_read
    case $rc in 2) why="timed out after $((TRIAGE_TIMEOUT_SEC / 60))m" ;; 3) why="lost the session terminal" ;; *) why="the session stopped without a verdict" ;; esac
    [[ -z "$WAIT_STOP_REASON" ]] || why="$WAIT_STOP_REASON"   # 화면 분류로 멈춤 — 사용량 한도(usage_limit로 끝낸다) 또는 확인 창에 멈춘 세션
    [[ "$WAIT_STOP_KIND" != usage_limit ]] || STOP_KIND=usage_limit
    log warn "#${n}: triage: ${why} — session output tail ---"; terminal_tail "$t_handle" | dim_lines || true
    TMUX_STATE_FILE="$saved_state"
    backend_set_status "$t_wt" todo "" "무인 수습: 판정 없이 끝남 — 확인 필요" || true
    TRIAGE_NOTE=" — triage: ${why} (session worktree ${t_path})"; TRIAGE_RESULT="no verdict: ${why}"
    return 1
  fi
  TMUX_STATE_FILE="$saved_state"

  verdict="$(jq -r '.verdict' "$vfile")"
  category="$(jq -r '.category // "unknown"' "$vfile")"
  summary="$(jq -r '.summary // "" | gsub("[\r\n]+"; " ")' "$vfile")"
  fix_pr="$(jq -r '.fix_pr // empty | tostring | select(test("^[0-9]+$"))' "$vfile" 2>/dev/null || true)"
  pushed="$(jq -r 'if .pushed_to_pr == true then 1 else 0 end' "$vfile")"
  kit_bug="$(jq -r '.kit_bug_report // empty' "$vfile")"
  log "#${n}: triage verdict: ${verdict} (${category}) — ${summary}"
  if [[ "$verdict" == resume && $resumable -eq 0 ]]; then log warn "#${n}: triage: ${kind} is diagnosis only — stopping"; verdict=halt; fi
  if [[ "$verdict" == resume && -n "$fix_pr" && "$fix_pr" == "${CUR_PR:-}" ]]; then pushed=1; fix_pr=""; fi   # 티켓 PR 번호를 적었다 = 그 브랜치에 push
  if [[ "$verdict" == resume && -n "$fix_pr" ]]; then
    if triage_merge_fix_pr "$fix_pr"; then
      TRIAGE_FIX_PR="$fix_pr"
      [[ "$kind" == post_merge_failed ]] || triage_keep_issue_open "$n" "$fix_pr"
      [[ "$kind" != setup_failed ]] || sync_main_checkout
    else
      verdict=halt
    fi
  fi
  if [[ "$verdict" != resume ]]; then
    backend_set_status "$t_wt" todo "" "무인 수습: 멈춤 — 확인 필요" || true
    TRIAGE_NOTE=" — triage (${category}): ${summary}${TRIAGE_NOTE}${kit_bug:+ · kit bug report ${kit_bug}}"
    TRIAGE_RESULT="halt (${category}): ${summary}"
    return 1
  fi

  if [[ -n "$TRIAGE_FIX_PR" ]]; then action="fix PR #${TRIAGE_FIX_PR} merged"; action_ko="수정 PR #${TRIAGE_FIX_PR} 병합"
  elif [[ $pushed -eq 1 ]]; then action="pushed to PR #${CUR_PR:-?}"; action_ko="PR #${CUR_PR:-?} 브랜치에 push"
  else action="no code change"; action_ko="코드 변경 없음"; fi
  backend_set_status "$t_wt" completed "" "무인 수습: 이어 감 (${action_ko})" || true
  backend_worktree_remove "$t_wt" "$t_path" || log warn "#${n}: failed to remove the triage worktree — clean up manually (${t_wt}, ${t_path})"
  git -C "$ROOT" worktree prune || true
  [[ -z "$t_branch" || "$t_branch" == HEAD || "$t_branch" == "$BASE_BRANCH" ]] || git -C "$ROOT" branch -D "$t_branch" >/dev/null 2>&1 || true
  log ok "#${n}: triage: resuming (${action}) — ${summary}"
  TRIAGE_RESULT="resumed (${category}, ${action}): ${summary}"
  triage_resume_record "$n" "$reason" "$category" "$summary" "$action" "$action_ko"
  STOP_KIND=""; STOP_RECORD=""
  return 0
}

# ---------- 티켓 기록 · 스펙 리포트 ----------
# 루프의 상태는 GitHub에만 두지만(기억 없음), 벽시계·CI 소요·수리 횟수·병합 뒤 검증 결과·모델은 GitHub에 없다. 티켓
# 하나가 끝날 때(병합·--no-merge·중단) RECORDS_FILE에 한 줄을 덧붙이고, --parent 실행이 정상 종료하면 그 기록과 GitHub
# (하위 이슈·PR 본문)을 합쳐 REPORT_DIR/spec-<N>.html을 만든다. 기록이 없는 티켓(다른 PC·사람 처리)은 PR 시각으로 대신한다.

CUR_N=""; CUR_TITLE=""; CUR_STARTED=0; CUR_STARTED_ISO=""; CUR_PR=""; CUR_MODEL=""; CUR_CI_SEC=""; CUR_PICKUP_SEC=""; CUR_ROUND=0
CUR_AGENT_PATHS=""   # 이 티켓의 에이전트 작업 폴더(워커·무인 수습), 한 줄에 하나 — 토큰을 셀 세션 기록을 찾는다(ticket_session_dirs)

# 티켓의 경과 시간을 단계별로 센다 — 구현(에이전트가 뜬 때부터 PR이 열린 때까지), 수리(수리 프롬프트부터 수리 끝까지, 충돌·CI 모두),
# CI(첫 회는 PR이 열린 때부터 — CI는 그때 돈다 — 수리 뒤에는 루프가 다시 보기 시작한 때부터 결과까지), 병합 뒤 검증(명령이 도는 동안,
# 재실행 포함). 나머지(워크트리 준비, PR을 알아채기, 병합·정리, 포트 대기, 무인 수습)는 세지 않는다 — 리포트가 경과 시간에서 뺀 나머지로
# 보인다. 0.9.7까지는 경과 시간 하나와 마지막 CI 회차만 남아, 몇 분이 구현이고 몇 분이 CI·통합 테스트인지 리포트에서 알 수 없었다.
# 단계는 메인 셸에서만 바꾼다(bg_wait 서브셸 안에서 바꾸면 부모에 남지 않는다). 멈추면 record_ticket이 열린 단계를 그 시각에 닫는다
PH_NAME=""; PH_AT=0; PH_IMPL=0; PH_REPAIR=0; PH_CI=0; PH_POST=0
phase() {   # $1 새 단계(impl|repair|ci|post, 빈 값이면 세지 않음), $2 바뀐 시각(생략하면 지금 — 지금 단계가 시작된 때보다 이르면 그때)
  local at="${2:-}" d
  [[ -n "$at" ]] || at="$(date +%s)"
  [[ "$at" -ge "${PH_AT:-0}" ]] || at="$PH_AT"
  d=$(( at - ${PH_AT:-0} ))
  case "${PH_NAME:-}" in
    impl) PH_IMPL=$(( ${PH_IMPL:-0} + d )) ;;
    repair) PH_REPAIR=$(( ${PH_REPAIR:-0} + d )) ;;
    ci) PH_CI=$(( ${PH_CI:-0} + d )) ;;
    post) PH_POST=$(( ${PH_POST:-0} + d )) ;;
  esac
  PH_NAME="$1"; PH_AT="$at"
}

# 워커 터미널의 에이전트 상태줄·배너에서 모델 이름을 뽑는다(Claude Code: "[Opus 5.5 | Max]", Codex: 기동 블록의 "model: gpt-5.1-codex"). 못 찾으면 빈 값.
detect_model() { [[ -n "$MODEL_REGEX" ]] || return 0; terminal_tail "$1" 2>/dev/null | grep -oE "$MODEL_REGEX" | tail -n1 || true; }

# 티켓이 속한 스펙 이슈 번호 — --parent가 없으면(이슈 번호 직접 지정) GitHub의 부모 이슈를 묻는다. 없으면 0.
spec_of_ticket() {
  [[ -z "$PARENT" ]] || { printf '%s' "$PARENT"; return; }
  gh api graphql -f query="{ repository(owner: \"${OWNER_REPO%%/*}\", name: \"${OWNER_REPO#*/}\") { issue(number: $1) { parent { number } } } }" \
    --jq '.data.repository.issue.parent.number // 0' 2>/dev/null || echo 0
}

# 스펙 이슈의 하위 이슈가 모두 닫혔으면 스펙 이슈를 닫는다. 요약 값 sub_issues_summary.completed 대신 목록을 센다
# (blocked_by 요약처럼 늦게 바뀔 수 있다). 하위 이슈가 없거나 하나라도 열려 있거나 스펙이 이미 닫혔으면 아무것도 하지 않는다.
close_spec_if_done() {
  local spec="${1:-}" counts total open
  [[ -n "$spec" && "$spec" != "0" ]] || return 0
  [[ "$(gh issue view "$spec" --json state -q .state 2>/dev/null)" == "OPEN" ]] || return 0
  counts="$(gh api "repos/${OWNER_REPO}/issues/${spec}/sub_issues?per_page=100" --paginate 2>/dev/null \
    | jq -rs 'add // [] | "\(length) \(map(select(.state == "open")) | length)"')" || return 0
  read -r total open <<<"$counts"
  [[ "${total:-0}" -gt 0 && "${open:-1}" -eq 0 ]] || return 0
  if gh issue close "$spec" --comment "하위 이슈 ${total}건이 모두 닫혀 완료 (ticket-loop)" >/dev/null 2>&1; then
    log ok "spec #${spec}: all ${total} sub-issues closed → closed the spec issue"
    CLOSED_SPECS="${CLOSED_SPECS:-} ${spec}"
  else
    log warn "spec #${spec}: all ${total} sub-issues are closed but the spec issue could not be closed — gh issue close ${spec}"
  fi
}

# 스펙의 티켓이 지나간 루프 로그들 — 루프가 멈췄다가 다른 날 다시 시작하면 로그 파일(loop-MMDD.log)이 여럿이 된다. 0.9.6까지 회고
# 안내는 이번 실행의 로그만 적어, 이어 간 스펙의 회고가 끊긴 지점부터만 읽었다. 기록의 log(0.9.7부터)를 모으고, 그 필드가 없는 지난
# 기록은 로그 디렉터리의 loop-*.log에서 그 티켓의 머리줄(=== #N)을 찾는다. 이번 실행의 로그는 늘 넣는다. 지워진 로그는 뺀다.
# 저장소 루트 기준 경로를 기록 순서대로 한 줄에 하나씩 쓴다
spec_logs() {
  local spec="$1" cur n f p
  [[ "$LOG_FILE" != "/dev/null" ]] || return 0
  cur="$LOG_FILE"; [[ -z "${ROOT:-}" ]] || cur="${cur#"$ROOT"/}"
  {
    if [[ -f "${RECORDS_FILE:-}" ]]; then
      while IFS=$'\t' read -r n f; do
        if [[ -n "$f" ]]; then printf '%s\n' "$f"
        else grep -lF "] === #${n} " "$(dirname "$LOG_FILE")"/loop-*.log 2>/dev/null || true; fi
      done < <(jq -rR --argjson spec "$spec" 'fromjson? | select(.spec == $spec) | "\(.issue)\t\(.log // "")"' "$RECORDS_FILE" 2>/dev/null || true)
    fi
    printf '%s\n' "$LOG_FILE"
  } | while IFS= read -r p; do
    [[ -z "${ROOT:-}" ]] || p="${p#"$ROOT"/}"
    if [[ "$p" == "$cur" || -f "$p" || -f "${ROOT:-.}/$p" ]]; then printf '%s\n' "$p"; fi
  done | awk '!seen[$0]++'
}

# 끝난 스펙이 있으면 회고를 권한다 — 안내일 뿐, 아무것도 실행하지 않는다. /retro 는 사람이 후보를 보고 고르는 스킬이라 무인 단계로 두지 않는다
suggest_retro() {
  local spec report skill="${SKILL_PREFIX:-/}retro" logs decs
  [[ -n "${CLOSED_SPECS// /}" ]] || return 0
  [[ -d "${ROOT:-.}/.agents/skills/retro" || -d "${ROOT:-.}/.claude/skills/retro" ]] || skill="${skill} (not in this repository yet — install it with the kit's --workflow-skills)"
  for spec in $CLOSED_SPECS; do
    report="$REPORT_DIR/spec-${spec}.html"
    if [[ -f "$report" || -f "${ROOT:-.}/$report" ]]; then report="report ${report}"
    else report="the report can be generated with ticket-loop.sh --parent ${spec}"; fi
    logs="$(spec_logs "$spec" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
    if [[ -z "$logs" ]]; then logs="log (none — logging is off)"
    elif [[ "$logs" == *", "* ]]; then logs="logs ${logs}"
    else logs="log ${logs}"; fi
    decs=""
    [[ -z "${REPORT_DECISIONS_HEADING:-}" || "$spec" != "${PARENT:-}" || -z "${REPORT_DECISIONS:-}" ]] \
      || decs=" (its '${REPORT_DECISIONS_HEADING}' list collects ${REPORT_DECISIONS} PR$([[ "$REPORT_DECISIONS" == 1 ]] || echo s) for a human)"
    log "spec #${spec} complete. If you like, review this batch with ${skill} — material to read: ${logs}, ${report}${decs}, and the 'remaining decisions' / 'not verified' sections of the merged PR bodies. If you end up changing the environment (skills, worker-rules.md, automated checks), a PR is recommended"
  done
}

# idle 오판 수 — 일하던 워커를 idle로 본 횟수(wait_for_pr 머리 주석). 0.9.1까지는 "idle 뒤 다시 보니 PR이 열려 있음"을 셌다.
# wait_for_pr는 서브셸(bg_wait, 0.8.7까지는 커맨드 치환)에서 돌아 변수로 세면 부모에 남지 않는다 — 0.8.9까지 요약 줄과 기록의
# idle_false_positives가 늘 0이었다. 티켓마다 IDLE_FP_FILE에 한 번에 한 줄씩 쓰고 줄 수를 센다
idle_fp_count() { if [[ -n "${IDLE_FP_FILE:-}" && -f "$IDLE_FP_FILE" ]]; then echo $(( $(wc -l < "$IDLE_FP_FILE") )); else echo 0; fi; }

# 티켓에 든 에이전트 토큰 — Claude Code 세션 기록에서 더한다. 기록은 CLAUDE_CONFIG_DIR(기본 ~/.claude)의 projects/<작업 폴더 경로에서
# 영숫자 밖 글자를 -로 바꾼 이름>/ 아래 *.jsonl이고, 서브에이전트 기록은 그 아래 subagents/에 있다. 응답마다 message.usage가 남는데 한 응답이
# 내용 블록마다 줄로 나뉘어 같은 usage가 되풀이되므로 message.id로 하나만 센다(rental-portal #250: 394줄 → 응답 210개). 워커 세션과 그 티켓의
# 무인 수습 세션(loop-triage-N-HHMMSS)을 더한다. Codex는 세션 기록 형식이 달라 아직 세지 않는다
claude_project_dir() { printf '%s/projects/%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }

# $1 이슈 번호, 나머지 그 밖의 작업 폴더(Orca 워크트리 등 — WORKTREE_DIR 밖) → 있는 세션 기록 폴더, 한 줄에 하나
ticket_session_dirs() {
  local n="$1" d
  shift
  {
    if [[ -n "${WORKTREE_DIR:-}" ]]; then
      claude_project_dir "${WORKTREE_DIR}/${BRANCH_PREFIX}${n}"; echo
      for d in "$(claude_project_dir "${WORKTREE_DIR}/loop-triage-${n}-")"*; do printf '%s\n' "$d"; done
    fi
    for d in "$@"; do [[ -z "$d" ]] || { claude_project_dir "$d"; echo; }; done
  } | while IFS= read -r d; do [[ ! -d "$d" ]] || printf '%s\n' "$d"; done | awk '!seen[$0]++'
}

# stdin 세션 기록 폴더들, $1 이 시각부터, $2 이 시각까지(빈 값이면 끝 없음 — 둘 다 ISO, 같은 경로를 쓴 앞선 시도를 빼려고) →
# {"input","output","cache_write","cache_read"} 한 줄. 응답이 하나도 없으면 빈 값
session_tokens() {
  local since="$1" upto="${2:-}" d f files=()
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$d" -type f -name '*.jsonl' -print0 2>/dev/null)
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  cat "${files[@]}" | jq -nRc --arg since "$since" --arg upto "$upto" '
    reduce (inputs | fromjson? | select(type == "object" and .type == "assistant" and (.message.usage | type) == "object")
            | select((.timestamp // "") >= $since and ($upto == "" or (.timestamp // "") <= $upto))) as $m
      ({}; .[$m.message.id // $m.uuid // "?"] = $m.message.usage)
    | [.[]] | select(length > 0)
    | {input: (map(.input_tokens // 0) | add), output: (map(.output_tokens // 0) | add),
       cache_write: (map(.cache_creation_input_tokens // 0) | add), cache_read: (map(.cache_read_input_tokens // 0) | add)}' 2>/dev/null || true
}

record_ticket() {
  local result="$1" reason="${2:-}" file="$RECORDS_FILE" spec   # RECORDS_FILE은 시작 때 절대 경로로 굳혔다
  [[ "$LOG_FILE" != "/dev/null" ]] || return 0
  phase ""   # 열린 단계(멈춘 때의 구현·CI 등)를 지금 닫는다
  mkdir -p "$(dirname "$file")"
  spec="$(spec_of_ticket "$CUR_N")"
  local tokens="" paths=() f
  if [[ "$AGENT" == claude ]]; then
    while IFS= read -r f; do [[ -z "$f" ]] || paths+=("$f"); done <<<"${CUR_AGENT_PATHS:-}"
    tokens="$(ticket_session_dirs "$CUR_N" ${paths[@]+"${paths[@]}"} | session_tokens "$CUR_STARTED_ISO")"
  fi
  jq -cn --argjson spec "${spec:-0}" --argjson issue "$CUR_N" --arg title "$CUR_TITLE" --arg result "$result" --arg reason "$reason" \
    --arg pr "$CUR_PR" --arg pickup "${CUR_PICKUP_SEC:-}" --arg started "$CUR_STARTED_ISO" --arg finished "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson wall "$(( $(date +%s) - CUR_STARTED ))" --arg ci "$CUR_CI_SEC" --argjson repairs "$CUR_ROUND" \
    --argjson idle "$(idle_fp_count)" --arg post "${POST_MERGE_RESULT:-}" --arg model "$CUR_MODEL" --arg agent "$AGENT" \
    --arg pmwhy "${POST_MERGE_WHY:-}" --arg pmspec "${POST_MERGE_SPEC_COMPLETE:-}" \
    --arg triage "${TRIAGE_RESULT:-}" --arg log "${LOG_FILE#"$ROOT"/}" \
    --argjson impl "${PH_IMPL:-0}" --argjson repair "${PH_REPAIR:-0}" --argjson ciwait "${PH_CI:-0}" --argjson postsec "${PH_POST:-0}" \
    --arg tokens "$tokens" '
    {spec: $spec, issue: $issue, title: $title, result: $result, started: $started, finished: $finished, wall_sec: $wall,
     impl_sec: $impl, repair_sec: $repair, ci_wait_sec: $ciwait, post_merge_sec: $postsec,
     repairs: $repairs, idle_false_positives: $idle, agent: $agent, log: $log}
    + (if $reason != "" then {reason: $reason} else {} end)
    + (if $triage != "" then {triage: $triage} else {} end)
    + (if $pr != "" then {pr: ($pr | tonumber)} else {} end)
    + (if $pickup != "" then {pr_pickup_sec: ($pickup | tonumber)} else {} end)
    + (if $ci != "" then {ci_sec: ($ci | tonumber)} else {} end)
    + (if $post != "" then {post_merge: $post} else {} end)
    + (if $pmwhy != "" then {post_merge_why: $pmwhy} else {} end)
    + (if $pmspec != "" then {post_merge_spec_complete: ($pmspec | split(" ") | map(select(. != "") | tonumber))} else {} end)
    + (if $tokens != "" then {tokens: ($tokens | fromjson)} else {} end)
    + (if $model != "" then {model: $model} else {} end)' >> "$file" 2>/dev/null \
    || log warn "#${CUR_N}: failed to write the ticket record (${file})"
}

# 스펙 리포트 HTML — jq 하나로 그린다(의존 도구를 늘리지 않는다). 표: 이슈·티켓·상태·결과 브리프(PR 제목, 본문의
# 인수 조건 체크 수, 중단 사유, 수리·병합 뒤 검증 결과)·구현·CI·병합 뒤 검증·경과 시간(단계 막대)·모델·마친 시각. 문자열은 전부 @html로 이스케이프한다.
# 리포트의 고정 문구는 영어, GitHub에서 가져온 값(이슈·PR 제목, 본문)과 기록의 중단 사유는 그대로(한국어면 한국어) 둔다.
# 기록의 post_merge는 0.8.7부터 영어("passed in Ns"·"failed in Ns"·"skipped")다. 그 전 기록의 한국어 값("통과 N초"·"실패 N초"·"건너뜀")은
# 표시할 때만 영어로 바꾼다(기록 파일은 그대로).
read -r -d '' REPORT_JQ <<'JQ' || true
def dur: if . == null then "—" elif . >= 3600 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
         elif . >= 60 then "\(. / 60 | floor)m" else "\(. | floor)s" end;
def epoch: if . == null or . == "" then null else (sub("\\.[0-9]+Z$"; "Z") | fromdate) end;
def when: epoch | if . == null then "—" else strflocaltime("%Y-%m-%d %H:%M") end;
def order: (.title | capture("^T(?<n>[0-9]+)") | .n | tonumber) // 999999;
# jq(Oniguruma Perl 문법)의 ^는 줄 머리가 아니라 문자열 머리다 — 앞에 \n을 붙여 줄 머리를 \n으로 잡는다
def checks: ("\n" + .) | {checked: ([scan("\n[ \t]*[-*] \\[x\\]"; "i")] | length), total: ([scan("\n[ \t]*[-*] \\[[ x]\\]"; "i")] | length)};
def badge: {merged: ["Merged", "ok"], "merged-after-stop": ["Merged after stop", "warn"], "closed-without-pr": ["Closed without PR", "muted"], "pr-open": ["PR open", "warn"],
            "in-progress": ["In progress", "warn"], stopped: ["Stopped", "bad"], pending: ["Not started", "muted"]}[.];
# 0.8.6 이하 기록의 한국어 post_merge 값을 표시용 영어로. 그 밖(이미 영어)은 그대로.
def post: if . == "건너뜀" then "skipped"
          else (capture("^(?<k>통과|실패) (?<s>[0-9]+)초$") // null) as $m
          | if $m == null then . else "\(if $m.k == "통과" then "passed" else "failed" end) in \($m.s)s" end end;
# 기록 하나의 병합 뒤 검증이 받은 env(#32) — " (every, spec #60 complete)". 그 값이 없는 기록(미룬 티켓, 그 전 기록)은 빈 문자열
def pmenv: [.post_merge_why // empty, ((.post_merge_spec_complete // []) | if length > 0 then "spec \(map("#\(.)") | join(" ")) complete" else empty end)]
           | if length > 0 then " (\(join(", ")))" else "" end;
def pos: if . != null and . > 0 then . else null end;
def tok: def d1($u; $s): (. / ($u / 10) | floor) as $d | "\($d / 10 | floor).\($d % 10)\($s)";   # 소수 한 자리(2.0M)
         if . == null then "—" elif . >= 1e9 then d1(1e9; "B") elif . >= 1e6 then d1(1e6; "M") elif . >= 1e3 then "\(. / 1e3 | floor)k" else "\(.)" end;
def tcell($v; $note): "<td class=\"nw\">" + (if $v == -1 then "none" else ($v | dur) end) + (if $note == "" then "" else "<div class=\"muted small\">\($note)</div>" end) + "</td>";
def seg($v; $c; $den): if ($v // 0) > 0 then "<i class=\"\($c)\" style=\"width:\($v * 1000 / $den | floor / 10)%\"></i>" else "" end;
# PR 본문에서 제목이 $h와 글자 그대로 같은 마크다운 절(#~######)의 본문 — 다음 같은·상위 수준 제목 앞까지(하위 절은 포함). 제목이 비었거나
# 절이 없거나 본문이 비면 null. 리포트 머리의 "사람 확인 필요" 목록이 쓴다(REPORT_DECISIONS_HEADING, 이슈 #25)
def section($h): if $h == "" or . == null then null else
  split("\n") as $lines
  | ($lines | map(capture("^(?<l>#{1,6})[ \t]+(?<t>.*?)[ \t]*#*[ \t]*$") // null)) as $hs
  | ($hs | to_entries | map(select(.value != null and .value.t == $h)) | first) as $start
  | if $start == null then null else
      ($start.value.l | length) as $lvl
      | (($hs | to_entries | map(select(.key > $start.key and .value != null and (.value.l | length) <= $lvl)) | first | .key) // ($lines | length)) as $end
      | $lines[$start.key + 1:$end] | join("\n") | gsub("^\\s+|\\s+$"; "") | if . == "" then null else . end
    end end;
# 절 본문이 "없음" 표시뿐인가 — 목록 기호(-·*)와 끝 마침표를 걷은 본문이 $none("|" 구분, 대소문자 무시)의 하나와 같으면 참.
# pr 스킬이 "없으면 '없음'"이라 쓰게 하는 저장소에서 그런 절을 빈 절처럼 뺀다(REPORT_DECISIONS_NONE, 이슈 #39)
def noneonly($none): (sub("^[-*][ \t]+"; "") | sub("\\.+$"; "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $b
  | $none | split("|") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | any(. != "" and . == $b);
($ARGS.named.heading // "") as $heading   # REPORT_DECISIONS_HEADING — --arg heading 이 없으면(지난 호출 꼴) 비움
| ($ARGS.named.none // "") as $none       # REPORT_DECISIONS_NONE — --arg none 이 없으면(지난 호출 꼴) 빈 절만 뺀다
| ($issues | sort_by(order, .number) | map(. as $i
  | ($recs | map(select(.issue == $i.number)) | sort_by(.finished)) as $rs | ($rs | last) as $r
  | ($prefix + ($i.number | tostring)) as $b
  | ($prs | map(select(.headRefName == $b or (.headRefName | startswith($b + "-"))))
     | (map(select(.state == "MERGED")) + .) | (map(select(.number == $r.pr)) + .) | first) as $pr
  # 루프가 멈춘 뒤 루프 밖(사람)에서 병합된 티켓 — 마지막 기록이 stopped이고 PR이 그 뒤에 병합됐다. 루프가 병합하고 나서 멈췄으면 병합이 먼저다
  | (if $pr.state == "MERGED" and $r.result == "stopped" then (($pr.mergedAt | epoch) // 0) - (($r.finished | epoch) // 0) else 0 end) as $gap
  | {issue: $i, pr: $pr, rec: $r, attempts: ($rs | length), stop_gap: $gap,
     status: (if $pr.state == "MERGED" then (if $gap > 0 then "merged-after-stop" else "merged" end) elif $i.state == "closed" then "closed-without-pr"
              elif $pr.state == "OPEN" then "pr-open" elif $r.result == "stopped" then "stopped"
              elif ($i.assignees // 0) > 0 then "in-progress" else "pending" end),
     wall: (if $r.wall_sec != null then {sec: $r.wall_sec, src: "loop"}
            elif $pr.mergedAt != null then {sec: (($pr.mergedAt | epoch) - ($pr.createdAt | epoch)), src: "pr"} else null end),
     # 경과 시간 나누기 — 0.9.8부터 기록에 단계별 시간이 있다(record_ticket·phase). 그 전 기록은 어림한다: 구현은 PR 생성 시각 − 시작(수리
     # 시간은 모른다), CI는 마지막 회차(ci_sec), 병합 뒤 검증은 결과 문자열의 초를 더한 값. PR 없이 멈춘 기록은 경과 전부가 구현이다
     t: (if $r == null then null
         elif ($r | has("impl_sec")) then
           {impl: (($r.impl_sec // 0) + ($r.repair_sec // 0) | pos), repair: ($r.repair_sec | pos),
            ci: (if $r.ci_sec == -1 then -1 else ($r.ci_wait_sec | pos) end), post: ($r.post_merge_sec | pos), est: false}
         else
           {impl: (if $r.pr == null and $r.result == "stopped" then ($r.wall_sec | pos)
                   else (($pr.createdAt | epoch) as $c | ($r.started | epoch) as $s
                         | if $c == null or $s == null or $c < $s then null else ([$c - $s, $r.wall_sec // ($c - $s)] | min | pos) end) end),
            repair: null, ci: (if $r.ci_sec == -1 then -1 else ($r.ci_sec | pos) end),
            post: ($r.post_merge // "" | post | [scan(" in ([0-9]+)s") | .[0] | tonumber] | add | pos), est: true} end),
     # 토큰 — 기록의 tokens(0.9.8부터), 없으면 write_spec_report가 세션 기록에서 메운 값. total은 네 값의 합
     tk: ($r.tokens | if type == "object" then . + {total: ((.input // 0) + (.output // 0) + (.cache_write // 0) + (.cache_read // 0))} else null end),
     model: ($r.model // "not recorded"),
     # 그 PR 본문의 REPORT_DECISIONS_HEADING 절(없거나 비었거나 없음 표시뿐이면 null) — 머리 목록과 행 표시가 쓴다
     dec: ($pr.body // "" | section($heading) | if . != null and noneonly($none) then null else . end)})) as $rows
| ($rows | map(select(.dec != null))) as $decs
| ($rows | map(select(.status == "merged" or .status == "merged-after-stop")) | length) as $merged
| ($rows | map(select(.issue.state == "closed")) | length) as $closed
| ($rows | map(select(.wall.src == "loop") | .wall.sec) | add // 0) as $total
| ([$rows[].tk.total | pos] | add) as $tok_total | ([$rows[].tk.output | pos] | add) as $tok_out
| ([$rows[].t.impl | pos] | add) as $impl_total | ([$rows[].t.ci | pos] | add) as $ci_total | ([$rows[].t.post | pos] | add) as $post_total
| ($rows | map(.model) | map(select(. != "not recorded")) | unique | join(", ")) as $models
| "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  + @html "<title>#\($spec.number) \($spec.title) — Loop report</title>"
  + "<style>:root{--ink:#1c1f24;--muted:#5b6270;--line:#d9dde3;--soft:#f4f6f8;--bg:#fff;--accent:#2457c5;--ok:#1f7a4d;--ok-soft:#e6f4ec;--warn:#9a6700;--warn-soft:#fff6d6;--bad:#b4441c;--bad-soft:#fbeee8}"
  + "@media (prefers-color-scheme:dark){:root{--ink:#e6e8eb;--muted:#9aa3ad;--line:#3a4047;--soft:#22262b;--bg:#15181b;--accent:#7ea2ff;--ok:#5fcf8f;--ok-soft:#1c3327;--warn:#e3b341;--warn-soft:#3a3012;--bad:#ff8a65;--bad-soft:#3b2219}}"
  + "*{box-sizing:border-box}body{margin:0;padding:24px 16px 48px;color:var(--ink);background:var(--bg);font-family:system-ui,-apple-system,\"Segoe UI\",\"Apple SD Gothic Neo\",\"Noto Sans KR\",sans-serif;font-size:14px;line-height:1.55}"
  + "main{max-width:1360px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}a{color:var(--accent);text-decoration:none}.kicker{color:var(--accent);font-weight:700;font-size:12px;letter-spacing:.06em}"
  + ".meta{color:var(--muted);font-size:13px;margin:0 0 18px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin:0 0 20px}"
  + ".kpi{background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:10px 12px}.kpi .v{font-size:20px;font-weight:700}.kpi .l{color:var(--muted);font-size:12px}"
  + ".wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{border:1px solid var(--line);padding:8px 10px;vertical-align:top;text-align:left}th{background:var(--soft);white-space:nowrap}"
  + "td.nw{white-space:nowrap}.bits{margin-top:4px;color:var(--muted);font-size:12px}.reason{margin-top:4px;color:var(--bad);font-size:12px}.muted{color:var(--muted)}.small{font-size:12px}"
  + ".badge{display:inline-block;font-size:12px;font-weight:700;border-radius:10px;padding:0 8px;border:1px solid var(--line);white-space:nowrap}.badge.ok{color:var(--ok);background:var(--ok-soft)}"
  + ".badge.warn{color:var(--warn);background:var(--warn-soft)}.badge.bad{color:var(--bad);background:var(--bad-soft)}.badge.muted{color:var(--muted);background:var(--soft)}footer{margin-top:20px;color:var(--muted);font-size:12px}"
  + ".bar{display:flex;height:6px;min-width:96px;margin-top:6px;border-radius:3px;overflow:hidden;background:var(--line)}.bar i{display:block;height:100%}"
  + ".dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px}.s-impl{background:var(--accent)}th.tm{white-space:normal}th.tm .k{white-space:nowrap}td.tk{min-width:130px}td.br{min-width:220px}.s-ci{background:var(--warn)}.s-post{background:var(--ok)}"
  + ".dec{margin:0 0 20px;padding:12px 14px;border:1px solid var(--warn);border-left-width:4px;border-radius:8px;background:var(--warn-soft)}.dec h2{font-size:15px;margin:0 0 8px}.dec .item{margin-top:10px}.dec .item:first-of-type{margin-top:0}.dec .who{font-weight:700;font-size:13px}.dec .md{margin:4px 0 0;white-space:pre-wrap;font-size:13px}"
  + ".flag{margin-top:4px;font-size:12px}.flag a{color:var(--warn);font-weight:700}</style></head>"
  + "<body><main><div class=\"kicker\">Unattended ticket loop · Spec report</div>"
  + @html "<h1><a href=\"\($spec.url)\">#\($spec.number)</a> \($spec.title)</h1>"
  + "<p class=\"meta\">Spec " + (if ($rows | length) > 0 and $closed == ($rows | length) then "complete (all sub-tickets closed)" else "in progress (\($closed)/\($rows | length) closed)" end)
  + " · generated \($now) · spec issue " + (if $spec.state == "CLOSED" then "closed" else "open" end) + "</p>"
  + "<div class=\"kpis\"><div class=\"kpi\"><div class=\"v\">\($rows | length)</div><div class=\"l\">Tickets</div></div><div class=\"kpi\"><div class=\"v\">\($merged)</div><div class=\"l\">Merged</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($total | dur)</div><div class=\"l\">Total loop wall-clock (recorded tickets)</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($impl_total | dur)</div><div class=\"l\"><span class=\"dot s-impl\"></span>Implementation</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($ci_total | dur)</div><div class=\"l\"><span class=\"dot s-ci\"></span>CI</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($post_total | dur)</div><div class=\"l\"><span class=\"dot s-post\"></span>Post-merge check</div></div>"
  + "<div class=\"kpi\"><div class=\"v\">\($tok_total | tok)</div><div class=\"l\">Tokens (output \($tok_out | tok))</div></div>"
  + @html "<div class=\"kpi\"><div class=\"v\">\(if $models == "" then "not recorded" else $models end)</div><div class=\"l\">Models used</div></div>"
  + (if $heading == "" then "" else @html "<div class=\"kpi\"><div class=\"v\">\($decs | length)</div><div class=\"l\">\($heading)</div></div>" end) + "</div>"
  # 사람이 봐야 할 절 모음 — 설정한 제목의 절이 있는 PR만, 티켓·PR 링크와 절 본문 그대로(마크다운 원문, 줄 바꿈 유지). 하나도 없으면 블록도 없다.
  # data-count는 write_spec_report가 로그 한 줄에 건수를 적을 때 읽는다
  + (if ($decs | length) == 0 then "" else
       "<section class=\"dec\" id=\"decisions\" data-count=\"\($decs | length)\">"
       + @html "<h2>\($heading) <span class=\"muted\">— \($decs | length) PR\(if ($decs | length) == 1 then "" else "s" end)</span></h2>"
       + ($decs | map(@html "<div class=\"item\"><div class=\"who\"><a href=\"\(.issue.url)\">#\(.issue.number)</a> \(.issue.title) · <a href=\"\(.pr.url)\">PR #\(.pr.number)</a></div><div class=\"md\">\(.dec)</div></div>") | join(""))
       + "</section>" end)
  + "<div class=\"wrap\"><table><thead><tr><th>Issue</th><th>Ticket</th><th>Status</th><th>Result brief</th><th class=\"tm\"><span class=\"k\"><span class=\"dot s-impl\"></span>Implementation</span></th><th class=\"tm\"><span class=\"k\"><span class=\"dot s-ci\"></span>CI</span></th><th class=\"tm\"><span class=\"k\"><span class=\"dot s-post\"></span>Post-merge</span> check</th><th>Elapsed</th><th>Tokens</th><th>Model</th><th>Finished</th></tr></thead><tbody>"
  + ($rows | map(
      @html "<tr><td class=\"nw\"><a href=\"\(.issue.url)\">#\(.issue.number)</a></td><td class=\"tk\">\(.issue.title)</td>"
      + "<td><span class=\"badge \(.status | badge | .[1])\">\(.status | badge | .[0])</span></td><td class=\"br\">"
      + (if .pr then @html "<div><a href=\"\(.pr.url)\">PR #\(.pr.number)</a> \(.pr.title)</div>"
                      + ((.pr.body // "" | checks) | if .total > 0 then "<div>Acceptance criteria \(.checked)/\(.total)</div>" else "" end)
                      + (if .dec != null then @html "<div class=\"flag\"><a href=\"#decisions\">⚑ \($heading)</a></div>" else "" end)
         elif .rec == null then "<span class=\"muted\">no record</span>" else "" end)
      + (if .rec.result == "stopped" then @html "<div class=\"reason\">Stop reason: \(.rec.reason // "—")</div>" else "" end)
      + (if .rec then "<div class=\"bits\">" + ([
            "\(.rec.repairs // 0) repair\(if (.rec.repairs // 0) == 1 then "" else "s" end)",
            # 0.9.6까지는 병합 전에 멈춘 기록에도 "skipped"가 남았다 — 멈춘 기록의 skipped는 그리지 않는다. 걸린 시간은 열에 있으니 결과만
            (if .rec.post_merge and (.rec.result != "stopped" or .rec.post_merge != "skipped") then @html "post-merge check \(.rec.post_merge | post | gsub(" in [0-9]+s"; ""))\(.rec | pmenv)" else empty end),
            (if .status == "merged-after-stop" then "merged outside the loop \(.stop_gap | dur) after the stop" else empty end),
            (if .rec.triage then @html "triage \(.rec.triage)" else empty end),
            (if .attempts > 1 then "\(.attempts) attempts" else empty end)] | join(" · ")) + "</div>" else "" end)
      + "</td>"
      + (.t as $t | .rec as $r
         | tcell($t.impl; if $t.impl == null then "" elif $t.est then (if ($r.repairs // 0) > 0 then "excl. repairs" else "" end)
                          elif $t.repair then "incl. repair \($t.repair | dur)" else "" end)
         + tcell($t.ci; if $t.ci == -1 then "path excluded" elif $t.ci and $t.est and ($r.repairs // 0) > 0 then "last run only" else "" end)
         + tcell($t.post; ""))
      + "<td class=\"nw\">" + (if .wall == null then "—" else (.wall.sec | dur)
          + (if .wall.src == "pr" then "<div class=\"muted small\">PR created→merged</div>"
             elif .status == "merged-after-stop" then "<div class=\"muted small\">loop, until the stop</div>" else "" end)
          + (if .t == null or .wall.sec <= 0 then "" else
               (.t.impl // 0) as $i | ([.t.ci, 0] | max) as $c | (.t.post // 0) as $p | ([.wall.sec, $i + $c + $p] | max) as $den
               | (.wall.sec - $i - $c - $p) as $o
               | ([if $i > 0 then "implementation \($i | dur)" else empty end, if $c > 0 then "CI \($c | dur)" else empty end,
                   if $p > 0 then "post-merge check \($p | dur)" else empty end, if $o > 0 then "other \($o | dur)" else empty end] | join(" · ")) as $tip
               | "<div class=\"bar\" title=\"\($tip)\">"
                 + seg($i; "s-impl"; $den) + seg($c; "s-ci"; $den) + seg($p; "s-post"; $den) + "</div>"
                 + (if $o >= 60 then "<div class=\"muted small\">other \($o | dur)</div>" else "" end) end) end) + "</td>"
      + "<td class=\"nw\">" + (if .tk == null then "—" else
          "<span title=\"input \(.tk.input // 0) · cache write \(.tk.cache_write // 0) · cache read \(.tk.cache_read // 0) · output \(.tk.output // 0)\">\(.tk.total | tok)</span>"
          + "<div class=\"muted small\">out \(.tk.output // 0 | tok)<br>new in \((.tk.input // 0) + (.tk.cache_write // 0) | tok)<br>cached \(.tk.cache_read // 0 | tok)</div>" end) + "</td>"
      + @html "<td class=\"nw\">\(.model)</td>"
      + "<td class=\"nw\">" + (if .status == "merged-after-stop" or .rec == null and .pr.mergedAt then (.pr.mergedAt | when) elif .rec then (.rec.finished | when) else "—" end | sub(" "; "<br>")) + "</td></tr>") | join("\n"))
  + "</tbody></table></div><footer>Elapsed is wall-clock time from when the loop created the worktree to when merge and cleanup finished. The bar under it splits that time by the three columns before it: Implementation runs from the agent's start to the PR, plus the worker's repair rounds; CI runs from the PR to the CI result (after a repair, from when the loop looked again), over every round; Post-merge check is the time its command ran, retry and bisect included; when one check covers several merged tickets (POST_MERGE_EVERY, default 4), its time is on the ticket after which it ran and the tickets before it say \"post-merge check deferred\". The grey rest (\"other\") is worktree setup, noticing the PR, merge, cleanup, port waits and triage. Records from before kit 0.9.8 have no phase times, so they are estimated: Implementation is the PR's creation time minus the start, without repairs; CI is the last run only; Post-merge check is read from the result text. Tokens are the agent's usage from its Claude Code session logs, subagents and triage sessions included: out is output, new in is input not served from the prompt cache (cache writes included), cached is input served from it. Codex workers are not counted yet. Tickets with no loop record use PR created→merged time instead. For a ticket merged outside the loop after a stop, it is the loop's time until the stop, and Finished is the merge time.</footer></main></body></html>"
JQ

# 리포트를 기본 브라우저로 연다 — 리포트는 사람이 보라고 만든 것이라 경로를 찾아 여는 한 단계를 줄인다. REPORT_OPEN=0이면 끔.
# 화면이 없는 곳(SSH 세션, DISPLAY 없는 Linux)에서는 열지 않고, 열기 실패는 루프 결과를 바꾸지 않는다(notify와 같은 태도).
open_report() {
  [[ "$REPORT_OPEN" == 1 && -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] || return 0
  if [[ "$(uname -s)" == Darwin ]] && command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || true
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# 기록에 tokens가 없는 티켓(0.9.7 이하, 또는 기록할 때 세션 기록을 못 찾음)은 리포트를 그릴 때 세션 기록에서 다시 센다(그 기록의 시작~끝
# 시각). cmux·tmux의 워크트리 자리(WORKTREE_DIR)로 찾으므로 Orca로 돈 지난 티켓은 비어 있다. 기록 파일은 고치지 않는다. Claude Code는
# 오래된 세션 기록을 지운다(cleanupPeriodDays, 기본 30일) — 그래서 새 티켓은 끝날 때 기록에 남긴다. stdin 기록 배열 → stdout 같은 배열
report_tokens() {
  local recs i n since upto t
  recs="$(cat)"
  if [[ -n "${WORKTREE_DIR:-}" ]]; then
    while IFS=$'\t' read -r i n since upto; do
      t="$(ticket_session_dirs "$n" | session_tokens "$since" "$upto")"
      [[ -z "$t" ]] || recs="$(jq -c --argjson i "$i" --argjson t "$t" '.[$i].tokens = $t' <<<"$recs")"
    done < <(jq -r 'to_entries[] | select(.value.tokens == null and (.value.agent // "claude") == "claude")
                    | [.key, .value.issue, (.value.started // ""), (.value.finished // "")] | @tsv' <<<"$recs")
  fi
  printf '%s\n' "$recs"
}

# --parent 실행이 정상 종료하면 스펙 리포트 HTML을 쓰고 브라우저로 연다. 생성 실패는 루프 결과를 바꾸지 않는다(로그만).
# 리포트는 커밋하지 않는다 — 사람이 보고 PR로 올린다(루프가 도는 동안 기본 브랜치 직접 커밋 금지).
REPORT_DECISIONS=""   # 마지막으로 쓴 리포트의 "사람 확인 필요" 건수(REPORT_DECISIONS_HEADING이 있을 때) — suggest_retro가 안내 줄에 적는다
write_spec_report() {
  [[ -n "$PARENT" ]] || return 0
  local out="$REPORT_DIR/spec-${PARENT}.html" records="$RECORDS_FILE" spec issues prs recs   # 둘 다 시작 때 절대 경로로 굳혔다
  # 목록 셋은 인자가 아니라 표준 입력으로 넘긴다 — PR 본문이 쌓인 저장소에서는 PR 목록이 인자 한도를 넘는다(#37).
  # 리포트 옆 임시 파일에 써서 성공해야 옮긴다(같은 폴더라 mv가 한 번에 바꾼다) — 생성이 실패해도 이전 리포트가 남는다
  if spec="$(gh issue view "$PARENT" --json number,title,state,url)" \
    && issues="$(gh api "repos/${OWNER_REPO}/issues/${PARENT}/sub_issues?per_page=100" --paginate \
         --jq '.[] | {number, title, state, url: .html_url, assignees: (.assignees | length)}' | jq -s '.')" \
    && prs="$(gh pr list --state all --limit 300 --json number,title,body,state,url,createdAt,mergedAt,headRefName)" \
    && recs="$( { [[ -f "$records" ]] && grep '^{' "$records" || true; } | jq -s --argjson spec "$PARENT" 'map(select(.spec == $spec))' | report_tokens)" \
    && mkdir -p "$(dirname "$out")" \
    && jq -rn --argjson spec "$spec" --arg prefix "$BRANCH_PREFIX" --arg now "$(date '+%Y-%m-%d %H:%M')" --arg heading "$REPORT_DECISIONS_HEADING" \
         --arg none "$REPORT_DECISIONS_NONE" "input as \$issues | input as \$prs | input as \$recs | $REPORT_JQ" <<<"$issues $prs $recs" > "$out.tmp" \
    && mv -f "$out.tmp" "$out"; then
    # 사람이 봐야 할 절의 건수(REPORT_DECISIONS_HEADING) — 리포트 블록의 data-count에서 읽는다. 블록이 없으면 0
    REPORT_DECISIONS="$(sed -n 's/.*id="decisions" data-count="\([0-9]*\)".*/\1/p' "$out" | head -n1)"; [[ -n "$REPORT_DECISIONS" ]] || REPORT_DECISIONS=0
    log ok "spec #${PARENT} report: ${out#"$ROOT"/}$([[ -z "$REPORT_DECISIONS_HEADING" ]] || echo " — '${REPORT_DECISIONS_HEADING}': ${REPORT_DECISIONS} PR$([[ "$REPORT_DECISIONS" == 1 ]] || echo s)") — review it, then commit it via a PR"
    open_report "$out"
  else
    rm -f "$out.tmp"
    log warn "spec #${PARENT}: report generation failed — rerun ticket-loop.sh --parent ${PARENT} to regenerate it"
  fi
}

# ---------- 티켓 하나 ----------

run_ticket() {
  local n="$1" title="$2"
  local deadline=$(( $(date +%s) + TICKET_TIMEOUT_SEC )) started_at ci_sec=0 ci_started
  started_at="$(date +%s)"
  IDLE_FP_FILE="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-idle-${n}.XXXXXX")"   # idle 오판 한 번에 한 줄(idle_fp_count)
  # 병합 뒤 검증 결과는 병합한 뒤에야 정한다 — 0.9.6까지는 "skipped"로 시작해, 병합 전에 멈춘 티켓의 기록이 "검증을 건너뜀"으로 남았다
  POST_MERGE_RESULT=""; POST_MERGE_LOG=""; POST_MERGE_RETRY_LOG=""; POST_MERGE_WHY=""; POST_MERGE_SPEC_COMPLETE=""
  log title "=== #${n} ${title} ==="
  CUR_N="$n"; CUR_TITLE="$title"; CUR_STARTED="$started_at"; CUR_STARTED_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; STOP_ISSUE="$n"
  CUR_PR=""; CUR_MODEL=""; CUR_CI_SEC=""; CUR_PICKUP_SEC=""; CUR_ROUND=0; CUR_AGENT_PATHS=""
  PH_NAME=""; PH_AT="$started_at"; PH_IMPL=0; PH_REPAIR=0; PH_CI=0; PH_POST=0
  STOP_KIND=""; STOP_RECORD=""; TRIAGE_RESULT=""

  git -C "$ROOT" fetch -q origin "$BASE_BRANCH"

  local wt wt_path orca_branch handle
  WT=""; WT_PATH=""; WT_BRANCH=""; HANDLE=""
  backend_worktree_create "${n}" "$(worker_prompt "${n}")"
  wt="$WT"; wt_path="$WT_PATH"; orca_branch="$WT_BRANCH"; handle="$HANDLE"
  CUR_AGENT_PATHS+="${wt_path}"$'\n'
  backend_set_status "${wt}" in-progress || true
  log step "#${n}: worktree ${wt} (${wt_path}) / terminal ${handle}"
  ensure_agent_started "${n}" "${handle}"
  phase impl
  CUR_MODEL="$(detect_model "${handle}")"

  local pr rc=0 model_now prfile reason
  progress_reset "${wt_path}"
  prfile="$(mktemp "${TMPDIR:-/tmp}/ticket-loop-pr-${n}.XXXXXX")"
  wait_stop_reset   # 대기가 화면 분류로 멈추면 종류·사유가 여기로 온다(서브셸을 넘어)
  bg_wait wait_for_pr "${n}" "${handle}" "$deadline" > "$prfile" || rc=$?   # 신호에 바로 깨도록(bg_wait)
  pr="$(cat "$prfile")"; rm -f "$prfile"
  if [[ $rc -ne 0 ]]; then
    phase ""   # 구현은 여기까지 — 무인 수습 시간은 세지 않는다
    log warn "#${n}: worker output tail ---"; terminal_tail "${handle}" | dim_lines || true
    backend_set_status "${wt}" todo "" "루프 중단: PR 없이 멈춤 — 확인 필요" || true
    [[ $rc -ne 2 ]] || die "#${n}: ticket timed out (${TICKET_TIMEOUT_SEC}s)"
    [[ $rc -ne 3 ]] || die "#${n}: cannot reach ${BACKEND_NAME} terminal ${handle} (${BACKEND_NAME} app closed?). The worktree is still on disk."
    screen_stop_check "${n}"   # 사용량 한도(usage_limit — 수습 없음)·확인 창(worker_no_pr)에 멈춘 워커면 여기서 멈춘다. 아니면 전처럼 idle strike
    reason="#${n}: worker stopped without a PR (a question or a failure?). Check the ${BRANCH_PREFIX}${n} worktree in ${BACKEND_NAME}."
    STOP_KIND=worker_no_pr
    triage worker_no_pr "$reason" || true   # 진단만 — 요약을 사유에 붙여 멈춘다
    die "${reason}${TRIAGE_NOTE}"
  fi
  # PR을 알아채기까지(PR 생성 → 루프가 다음 단계로) — 늘어지면 그만큼 CI·병합이 늦다(0.9.1의 PR 뒤 10분 대기를 손으로 대조해 찾았다)
  local created pickup=""
  created="$(pr_created_epoch "${pr}")"
  if [[ -n "$created" ]]; then pickup=$(( $(date +%s) - created )); [[ $pickup -ge 0 ]] || pickup=0; fi
  CUR_PICKUP_SEC="$pickup"
  phase "" "$created"   # 구현은 PR이 열린 때까지(GitHub 시각)
  log step "#${n}: PR #${pr} opened${pickup:+ (created $(fmt_epoch "$created"), picked up after ${pickup}s)}"
  progress_sync
  CUR_PR="$pr"; model_now="$(detect_model "${handle}")"; [[ -z "$model_now" ]] || CUR_MODEL="$model_now"
  backend_set_status "${wt}" in-review "${pr}" "PR #${pr} — CI 대기" || true

  # 수리를 다 쓰면 멈추기 전에 무인 수습을 한 번 띄운다(ci_failed) — 수습 세션이 PR 브랜치에 고쳐 push하면 이 고리의 처음(충돌·CI 확인)부터
  # 이어 간다. 그래도 실패하면 수습 횟수를 이미 써서 그대로 멈춘다
  local round=0 state ci_from="$created"
  while :; do
    state="$(mergeable_state "${pr}")"
    if [[ "$state" == "CONFLICTING" ]]; then
      if [[ ${round} -ge $REPAIR_ROUNDS ]]; then
        reason="#${n}: PR #${pr} conflicts with ${BASE_BRANCH} (${REPAIR_ROUNDS} repair round(s) used up)"
        STOP_KIND=ci_failed; triage ci_failed "$reason" && continue
        die "${reason}${TRIAGE_NOTE}"
      fi
      round=$((round + 1)); CUR_ROUND=$round; log warn "#${n}: conflict → asking the worker to repair (${round})"
      phase repair
      repair "${handle}" "PR #${pr} 이 ${BASE_BRANCH}과 충돌한다. \`git fetch origin && git merge origin/${BASE_BRANCH}\`으로 충돌을 해결하고 테스트·lint를 다시 돌린 뒤 같은 브랜치에 push해라. 질문하지 말고 끝까지 해라." "$deadline" "${pr}" \
        || die "#${n}: timed out while repairing the conflict"
      phase ""
      screen_stop_check "${n}" " while repairing PR #${pr}"   # 수리 중 사용량 한도·확인 창이면 여기서 멈춘다
      continue
    fi
    if ! ci_expected "${pr}"; then
      log step "#${n}: PR excluded by the repository CI path filter (${CI_SKIP_CMD:+CI_SKIP_CMD}${CI_SKIP_CMD:-CI_SKIP_REGEX}) — merging without checks (PR #${pr})"
      ci_sec=-1
      break
    fi
    log step "#${n}: waiting for CI (PR #${pr})"
    ci_started="$(date +%s)"
    phase ci "$ci_from"; ci_from=""   # 첫 회는 PR이 열린 때부터(PR을 알아채기 전에도 CI는 돈다)
    if ci_passed "${pr}"; then
      phase ""
      ci_sec="$(ci_run_sec "${pr}")"; [[ -n "$ci_sec" ]] || ci_sec=$(( $(date +%s) - ci_started ))
      break
    fi
    phase ""
    if [[ ${round} -ge $REPAIR_ROUNDS ]]; then
      reason="#${n}: PR #${pr} CI failed (${REPAIR_ROUNDS} repair round(s) used up). See gh pr checks ${pr}."
      STOP_KIND=ci_failed; triage ci_failed "$reason" && continue
      die "${reason}${TRIAGE_NOTE}"
    fi
    round=$((round + 1)); CUR_ROUND=$round; log warn "#${n}: CI failed → asking the worker to repair (${round})"
    if ! repair_ci "${n}" "${pr}" "${handle}" "$deadline"; then
      reason="#${n}: no new commit was pushed after the repair, and CI still fails"
      STOP_KIND=ci_failed; triage ci_failed "$reason" && continue
      die "${reason}${TRIAGE_NOTE}"
    fi
  done
  log ok "#${n}: CI passed"
  CUR_CI_SEC="$ci_sec"

  if [[ $NO_MERGE -eq 1 ]]; then
    log step "#${n}: --no-merge — merge PR #${pr} yourself. The worktree is kept (${wt})."
    record_ticket "no-merge"; CUR_N=""; STOP_ISSUE=""; rm -f "$IDLE_FP_FILE"
    return 0
  fi

  # 일시 장애가 아닌 거절(필수 리뷰 같은 브랜치 보호)은 사람에게 넘기는 자리라 무인 수습을 띄우지 않는다(종류만 merge_failed)
  if ! merge_pr "${pr}"; then
    STOP_KIND=merge_failed
    die "#${n}: failed to merge PR #${pr} after CI passed${MERGE_ERR:+ (${MERGE_ERR})}. Check gh pr view ${pr} — if it is mergeable, merge it and rerun."
  fi
  log ok "#${n}: PR #${pr} merged"
  sleep 5
  if [[ "$(gh issue view "${n}" --json state -q .state)" != "CLOSED" ]]; then
    gh issue close "${n}" --comment "PR #${pr} 병합으로 완료 (ticket-loop)" || true
  fi
  gh issue edit "${n}" --remove-label "$IN_REVIEW_LABEL" >/dev/null 2>&1 || true
  gh issue edit "${n}" --remove-label "$STOPPED_LABEL" >/dev/null 2>&1 || true   # 지난 실행이 멈추며 붙인 라벨(코멘트는 기록으로 남는다)
  local spec; spec="$(spec_of_ticket "${n}")"
  close_spec_if_done "$spec"

  # 병합된 기본 브랜치로 무거운 검증 — CI가 안 붙는 문서 PR은 창에 넣지 않는다. 단 스펙을 끝낸 문서 PR은 넣는다 — 창이 비어 있어도
  # (POST_MERGE_EVERY=1) 스펙 끝의 검증이 TICKET_LOOP_POST_MERGE_SPEC_COMPLETE를 달고 돌게(#32). 창이 찼거나(POST_MERGE_EVERY, 기본 4) 스펙·실행이
  # 끝날 때만 돌리고 나머지는 미룬다(pm_due). 실패하면 기본 브랜치가 깨진 것이므로 다음 티켓을 쌓지 않고 멈춘다(워커
  # 워크트리는 이미 병합됐으니 정리하고, 검증 워크트리와 로그를 남긴다).
  local post_rc=0
  if [[ $POST_MERGE -eq 1 ]]; then
    if [[ $ci_sec -ge 0 ]] || spec_closed_this_run "$spec"; then
      git -C "$ROOT" fetch -q origin "$BASE_BRANCH" || true   # 병합 커밋의 부모(창의 시작)를 읽으려고
      pm_add "${n}" "${pr}" "$(gh pr view "${pr}" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null || true)"
    fi
    pm_spec_closed "$spec"   # 이 병합이 스펙을 끝냈으면 창에 — 창을 덮는 검증이 TICKET_LOOP_POST_MERGE_SPEC_COMPLETE로 받는다
    if pm_due "${n}" "$spec"; then
      run_post_merge "${n}" || post_rc=$?
    elif [[ $ci_sec -lt 0 ]]; then
      POST_MERGE_RESULT="skipped"
    else
      POST_MERGE_RESULT="deferred ($(pm_of) pending)"
      log step "#${n}: post-merge check deferred — $(pm_of) merged tickets waiting ($(pm_list))$([[ $POST_MERGE_EVERY -ne 0 ]] || echo ", until the spec or the run ends")"
    fi
  else
    POST_MERGE_RESULT="skipped"
  fi

  # 이미 병합됐다 — 조회가 실패해도 멈추지 않고 브랜치 삭제만 건너뛴다
  local branch; branch="$(gh pr view "${pr}" --json headRefName -q .headRefName || true)"
  [[ -n "$branch" ]] || log warn "#${n}: could not read the head branch of PR #${pr} — delete it yourself (local and origin)"
  backend_set_status "${wt}" completed "${pr}" "PR #${pr} 병합 완료" || true
  backend_worktree_remove "${wt}" "${wt_path}" || log warn "#${n}: failed to remove the worktree — clean up manually (${wt}, ${wt_path})"
  git -C "$ROOT" worktree prune || true
  [[ -z "$branch" ]] || git -C "$ROOT" branch -D "${branch}" >/dev/null 2>&1 || true
  if [[ -n "$orca_branch" && "$orca_branch" != "HEAD" && "$orca_branch" != "$BASE_BRANCH" ]]; then
    git -C "$ROOT" branch -D "${orca_branch}" >/dev/null 2>&1 || true
  fi
  [[ -z "$branch" ]] || git -C "$ROOT" push -q origin --delete "${branch}" >/dev/null 2>&1 || true
  # 병합 뒤 검증이 실패했으면 멈추기 전에 무인 수습을 띄운다(post_merge_recover). 이 티켓은 이미 병합됐으므로 수습 결과와 무관하게
  # 기록은 merged다 — 멈추면 die가 알린다
  if [[ $post_rc -ne 0 ]]; then
    post_rc=0; post_merge_recover "${n}" || post_rc=$?
    reason="$PM_REASON"
  fi
  log ok "#${n} summary: wall-clock $(( ($(date +%s) - started_at) / 60 ))m, PR #${pr}${CUR_PICKUP_SEC:+ (picked up after ${CUR_PICKUP_SEC}s)}, CI $([[ $ci_sec -ge 0 ]] && echo "${ci_sec}s" || echo "none (path excluded from CI)"), repairs ${round}, idle false positives $(idle_fp_count), post-merge check ${POST_MERGE_RESULT}${TRIAGE_RESULT:+, triage ${TRIAGE_RESULT%%: *}}"
  record_ticket "merged"; CUR_N=""; rm -f "$IDLE_FP_FILE"
  [[ $post_rc -eq 0 ]] || die "$reason"
  notify "Ticket done" "#${n} ${title} — PR #${pr}, $(( ($(date +%s) - started_at) / 60 ))m" done
  STOP_ISSUE=""
}

# ---------- 메인 ----------

KIT_VERSION="$(kit_version)"
kit_banner "ticket-loop-kit ${KIT_VERSION}"
backend_check
pm_load
# 시작 전에는 사람이 앞에 있다 — 조회가 실패하면 바로 멈추고, 후보 0행(2)은 재확인 없이 빈 목록 그대로다(재확인은 티켓 사이 — pick_next_targets)
pick_rc=0; targets="$(pick_targets)" || pick_rc=$?
[[ $pick_rc -ne 1 ]] || die "could not list tickets (GitHub)"
log "repository ${OWNER_REPO} / backend ${BACKEND_NAME} / base branch ${BASE_BRANCH} / label ${READY_LABEL}${SCOPE_LABEL:+ + ${SCOPE_LABEL}}${PARENT:+ / sub-issues of spec #${PARENT}}"
log "post-merge check: $([[ $POST_MERGE -eq 1 ]] && echo "on$(case "$POST_MERGE_EVERY" in 1) ;; 0) echo ", when a spec or the run ends" ;; *) echo ", every ${POST_MERGE_EVERY} merged tickets and when a spec or the run ends" ;; esac) — ${POST_MERGE_CMD}${POST_MERGE_RETRY_CMD:+ (retry once on failure: ${POST_MERGE_RETRY_CMD})}" || echo "off")"
if [[ -n "$PM_PENDING" ]]; then
  log warn "post-merge check: $(pm_count) merged ticket$([[ "$(pm_count)" -eq 1 ]] || echo s) from an earlier run not checked yet ($(pm_list)) — $([[ $POST_MERGE -eq 1 ]] && echo "the next check covers them" || echo "left for a run with the check on")"
elif [[ -n "$PM_SPEC_COMPLETE" ]]; then   # 지난 실행의 스펙 끝 검증이 실패해 멈춤(#34) — 대상이 없어도 루프 끝에 돈다
  log warn "post-merge check: spec $(pm_spec_list) completed in an earlier run, not covered by a passed check yet — $([[ $POST_MERGE -eq 1 ]] && echo "the next check covers it" || echo "left for a run with the check on")"
fi
log "notifications: desktop$([[ -z "$SLACK_WEBHOOK_URL" ]] || echo " + Slack")"
log "triage on stop: $([[ "$LOOP_TRIAGE" == 1 ]] && echo "on — up to ${TRIAGE_MAX} per run, $((TRIAGE_TIMEOUT_SEC / 60))m each" || echo "off")"
if [[ "$LOOP_TRIAGE" == 1 ]] && ! triage_skill_on_base; then
  log warn "note: the loop-triage skill is not on origin/${BASE_BRANCH} — stops are not triaged until the kit install is merged"
fi
if [[ -f "$LOOP_ENV" ]] && grep -q 'hooks\.slack\.com' "$LOOP_ENV"; then
  log warn "note: a Slack webhook URL is in .ticket-loop/loop.env, which is committed — move SLACK_WEBHOOK_URL to ${USER_LOOP_ENV} (anyone with the URL can post to the channel)"
fi
if [[ $POST_MERGE -eq 1 && -n "$POST_MERGE_PORT" ]] && port_in_use "$POST_MERGE_PORT"; then
  log warn "note: port ${POST_MERGE_PORT} in use ($(port_holder "$POST_MERGE_PORT" || true)) — keep it free while the loop runs. Otherwise each merge waits up to $((PORT_WAIT_SEC / 60))m for it (or use --skip-post-merge)"
fi
# 티켓이 더 없어도 --parent면 스펙 닫기·리포트는 다시 한다(사람이 마지막 티켓을 닫은 스펙, 끝난 스펙의 리포트를 다시 뽑는 길)
[[ -n "$targets" ]] || { log "No tickets to process."; [[ $DRY_RUN -eq 1 ]] || { close_spec_if_done "$PARENT"; pm_spec_closed "$PARENT"; pm_flush_end; write_spec_report; suggest_retro; }; exit 0; }
log "targets (all blocking issues currently closed):"; printf '%s\n' "$targets" | dim_lines "  #"
[[ $DRY_RUN -eq 0 ]] || exit 0
target_count="$(grep -c . <<<"$targets")"
slack_post "Ticket loop started" "${target_count} ticket$([[ $target_count -eq 1 ]] || echo s) · backend ${BACKEND_NAME} · agent ${AGENT}$([[ $MAX -eq 0 ]] || echo " · max ${MAX}") · kit ${KIT_VERSION}
$(head -n 10 <<<"$targets" | awk -F'\t' '{print "#" $1 " " $2}')$([[ $target_count -le 10 ]] || printf '\n+%d more' $((target_count - 10)))" start

# 목록을 stdin으로 물리지 않는다 — 루프 안의 gh·백엔드 CLI·git이 stdin을 읽으면 다음 티켓이 사라진다.
# 자동 선택이면 티켓 하나가 끝날 때마다 대상을 다시 계산해, 막 풀린 선행 관계를 반영한다.
done_count=0
PROCESSED=""
while :; do
  if [[ ${#TICKETS[@]} -gt 0 ]]; then
    [[ $done_count -lt ${#TICKETS[@]} ]] || break
    n="${TICKETS[$done_count]}"; title="$(issue_title "${n}")"
    blocked="$(blocked_by "${n}")" || die "#${n}: could not check blocking issues (GitHub)"   # 조회 실패를 통과시키지 않는다
    [[ "$blocked" == "0" ]] || die "#${n}: blocked by an open issue"
    pr="$(open_pr_for "${n}")" || die "#${n}: could not check for an open PR (GitHub)"
    [[ -z "$pr" ]] || die "#${n}: a PR is already open"
  else
    if [[ $NEXT_TARGETS_SET -eq 1 ]]; then targets="$NEXT_TARGETS"; NEXT_TARGETS_SET=0   # 병합 뒤 검증을 미룰 때 pm_due가 계산해 둔 것
    elif [[ $done_count -ne 0 ]]; then
      # 목록 조회가 gh 재시도까지 실패하거나(GitHub 장애가 길다, 1), 재확인까지 빈 목록인데 스펙에 열린 하위 이슈가 남으면(성공한 빈 응답, 2 — #22)
      # PICK_RETRY_SEC 동안 PICK_RETRY_EVERY_SEC마다 다시 해 보고(2면 한 바퀴에 재확인 PICK_RECHECK_SEC가 더 든다), 그래도 안 되면 그 사유로
      # 멈춘다 — 조용히 "No more tickets"로 끝내지 않는다.
      # 처리 중인 티켓이 없으므로(CUR_N·STOP_ISSUE 비어 있음) 이슈 코멘트·무인 수습 없이 알림과 멈춤 기록(other)만 남는다
      pick_deadline=$(( $(date +%s) + PICK_RETRY_SEC ))
      while :; do
        pick_rc=0; targets="$(pick_next_targets </dev/null)" || pick_rc=$?
        [[ $pick_rc -ne 0 ]] || break
        if [[ $pick_rc -eq 2 ]]; then pick_why="ticket list empty but spec #${PARENT} has open sub-issues"; else pick_why="could not list tickets (GitHub)"; fi
        [[ $(date +%s) -lt $pick_deadline ]] || { STOP_KIND=""; die "$pick_why"; }
        log warn "${pick_why} — retrying in ${PICK_RETRY_EVERY_SEC}s (for up to $((PICK_RETRY_SEC / 60))m)"
        sleep "$PICK_RETRY_EVERY_SEC"
      done
    fi
    # 이번 실행에서 이미 처리한 티켓은 다시 집지 않는다(이슈 닫힘 반영이 늦는 경우 대비)
    n=""
    while IFS=$'\t' read -r cand ctitle; do
      [[ -n "${cand}" && " ${PROCESSED} " != *" ${cand} "* ]] || continue
      n="${cand}"; title="${ctitle}"; break
    done <<<"$targets"
    [[ -n "${n}" ]] || { log "No more tickets to process."; break; }
  fi
  run_ticket "${n}" "${title}" </dev/null
  PROCESSED="${PROCESSED} ${n}"
  done_count=$((done_count + 1))
  [[ $MAX -eq 0 || $done_count -lt $MAX ]] || { log "--max $MAX reached"; break; }
done

# 스펙을 닫은 뒤 남은 창을 검증한다 — 여기서 처음 닫히는 스펙(사람이 마지막 티켓을 닫음·하위 이슈 반영 지연)도 그 검증이 SPEC_COMPLETE로 받게.
# 창이 비었어도(POST_MERGE_EVERY=1) 그 스펙 번호를 싣고 통과한 검증이 이번 실행에 없었으면 그 번호로 한 번 돈다(#34)
close_spec_if_done "$PARENT"; pm_spec_closed "$PARENT"
pm_flush_end
write_spec_report
suggest_retro
log ok "done: ${done_count} ticket$([[ $done_count -eq 1 ]] || echo s)"
notify "Ticket loop finished" "${done_count} done$([[ $TRIAGE_USED -eq 0 ]] || echo " · ${TRIAGE_USED} triaged")$([[ -z "${CLOSED_SPECS// /}" ]] || echo " · spec${CLOSED_SPECS// / #} complete — consider /retro")" finish
