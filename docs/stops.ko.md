# 루프가 멈출 때

[README](../README.ko.md) · [English](stops.md)

## 알림: Slack과 GitHub 멈춤 기록

자리를 비운 사이 루프가 끊겨도 밖에서 알 수 있게 두 갈래로 남긴다.

- **Slack(알림)**: `SLACK_WEBHOOK_URL`이 있으면 루프 시작, 티켓 완료, 멈춤, 루프 종료를 채널에 올린다. 멈춤에는 사유와 로그 끝 12줄(워커 화면 꼬리 포함)이 붙고, `SLACK_MENTION`이 있으면 그 멘션이 앞에 붙는다(Ctrl-C로 멈춘 것은 빼고).
- **GitHub(기록)**: 티켓 처리 중 멈추면 그 이슈에 코멘트(사유, 머신, PR, 워크트리, 루프 자신의 로그 끝 30줄)를 달고 `loop-stopped` 라벨(`STOPPED_LABEL`)을 붙인다. 루프는 본인 계정으로 쓰므로 GitHub는 본인에게 알리지 않는다. 알림이 아니라 기록이다. 대상 선택은 이 라벨을 보지 않고, 루프가 그 티켓을 병합하면 뗀다. 워커 화면은 공개 저장소에 올리지 않으려고 코멘트에서 뺀다.

멈춤은 어떻게 끝나든 한 번 보고된다: 멈추는 조건(PR 없이 멈춤, 타임아웃, 수리 소진 등), 터미널 창 닫힘, Ctrl-C, `kill`, `set -e`에 걸린 명령(네트워크가 끊겨 `git fetch`·`gh`가 실패하는 등). `kill -9`, 전원 꺼짐, 잠자기는 스크립트가 아무것도 보내지 못해 잡지 못한다.

Slack 설정(컴퓨터마다 한 번):

1. <https://api.slack.com/apps> → **Create New App** → **Blank app**(예전 화면의 From scratch) → 이름(예 `ticket-loop`)과 워크스페이스.
2. 이어지는 마법사에서 **Bot scopes**에 `incoming-webhook` 하나만 넣고(User scopes·이벤트는 비운다) **Create and Install** → 웹후크를 위한 채널(예 미리 만든 비공개 `#ticket-loop`, 본인이 들어가 있어야 목록에 보인다) → **허용**. **Go to App Settings** → 왼쪽 **Incoming Webhooks**의 "Webhook URLs for Your Workspace"에서 URL을 복사한다(Slack CLI 안내는 필요 없다). 예전 화면이면 **Incoming Webhooks** → **Activate Incoming Webhooks** → **Add New Webhook**으로 같은 URL을 만든다. 워크스페이스가 앱 설치를 제한하면 관리자 승인이 필요하다.
3. 나온 URL을 커밋하지 않는 기계별 설정 파일에 둔다. 저장소 `loop.env`는 커밋되므로 쓰지 않는다(거기 있으면 시작할 때 경고한다). URL만 있으면 누구나 그 채널에 글을 쓸 수 있다.
   ```bash
   mkdir -p ~/.config/ticket-loop
   cat >> ~/.config/ticket-loop/loop.env <<'EOF'
   SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/T…/B…/…}"
   SLACK_MENTION="${SLACK_MENTION:-<@U012AB3CD>}"   # 선택: Slack 프로필 → ⋮ → Copy member ID
   EOF
   chmod 600 ~/.config/ticket-loop/loop.env
   ```
   이 파일은 그 컴퓨터의 모든 저장소에 적용되고(`XDG_CONFIG_HOME`을 따른다), 저장소 `loop.env`보다 먼저 읽혀 이긴다.
4. 폰 알림: 채널 알림을 "모든 새 메시지"로 두거나, "멘션만"으로 두고 `SLACK_MENTION`으로 멈출 때만 울리게 한다.
5. 확인: 루프 시작 줄에 `notifications: desktop + Slack`이 보이고 채널에 "Ticket loop started"가 올라온다. `--dry-run`은 보내지 않는다.

## 무인 수습: 루프가 멈춘 이유를 먼저 고쳐 본다

멈춤을 알아채고 붙기까지가 고치는 시간보다 길다. rental-portal spec #96에서 병합 뒤 검증이 15:43에 실패했고, 고친 것은 테스트 기대값 3줄이었는데 루프가 다시 돈 것은 19:08이었다. 그래서 `LOOP_TRIAGE=1`(기본)이면 아래 네 경우에 바로 멈추지 않는다. 멈춤 기록을 쓰고, **수습 세션**(워커와 같은 길로 새 워크트리 `loop-triage-N-<시각>`에 띄운 에이전트)에 `/loop-triage <기록>`을 시킨 뒤, 잠금을 쥔 채 판정 파일(`resume` 또는 `halt`)을 기다린다. Slack에는 "수습 시작"과 결과가 간다.

| 멈출 일 | 수습 세션 | `resume`이면 루프가 |
|---|---|---|
| 병합 뒤 검증 실패(재실행 포함) | 실패를 병합된 PR의 diff와 대조해 테스트 기대값이나 코드를 고치고, 실패한 테스트 파일만 돌린 뒤 기본 브랜치로 수정 PR. 무관한 시간 초과면 다시 돌려 보고 플레이크로 판정 | 수정 PR에 `loop-triage` 라벨을 붙이고 CI 뒤 병합, 병합된 브랜치로 검증을 다시 돌려(`post-merge-N-after-triage.log`) 통과하면 이어 감 |
| 수리를 다 쓴 CI 실패·충돌, 새 커밋 없이 끝난 수리 뒤에도 CI 실패 | 티켓 PR의 브랜치에 고쳐 push. 번들 크기 천장 같은 임계값은 티켓 변경으로 정당하게 늘어난 경우에만 근거를 PR 코멘트로 남기고 올린다. CI 인프라 오류면 `gh run rerun --failed` | 그 PR의 충돌·CI 확인부터 이어 감 |
| `WORKTREE_SETUP_CMD` 실패(cmux·tmux) | 준비를 재현하고 저장소 스크립트·lockfile을 고쳐 수정 PR, 일시 장애면 수정 없이 | 수정 PR을 병합하고 워커 워크트리(메인 체크아웃도 기본 브랜치면 — 로컬 변경을 덮는 merge는 git이 거부한다)를 fast-forward한 뒤 준비를 다시 돌림 |
| 워커가 PR 없이 멈춤 | 진단만: 무엇에 막혔는지 요약한다. 워커의 질문에 답하지 않는다 | (언제나 멈춤) |

처음부터 다시 실행하지 않고 멈춘 자리에서 이어 간다 — 새로 실행하면 PR이 열렸거나 담당자가 붙은 티켓을 건너뛰기 때문이다. `halt`, 판정 없음(시간 초과·idle), 수정 PR 실패, 이어 간 뒤 같은 멈춤이면 판정 요약을 사유 끝에 붙여 멈추고(Slack 멘션) 수습 워크트리는 남긴다. 한 실행에 `TRIAGE_MAX`번(기본 1), 같은 멈춤에는 한 번. `TRIAGE_TIMEOUT_SEC`(기본 3600)이 세션 하나의 상한이다.

수습 세션은 기본 브랜치에 커밋된 `loop-triage` 스킬을 쓰므로 키트 설치 PR이 병합되기 전에는 띄우지 않는다(시작 줄에 적는다). 메인 체크아웃과 키트 소유 파일은 고치지 않는다: 루프 버그는 멈춤 기록 옆에 키트 버그 보고서(`<id>.kit-bug.md`)를 쓰고 멈춘다 — 이 저장소의 로그·코드가 (공개) 키트 저장소로 저절로 나가지 않게, 올리는 건 사람이 한다. 병합된 PR에서 인용한 근거 없이 테스트를 약하게 만들지 않고, 병합하지 않으며, 이 머신의 프로세스·운영 환경·비밀 값을 건드리지 않는다. 그 밖의 멈춤(티켓 타임아웃, 터미널 끊김, 에이전트 기동 실패, 병합 실패, 신호, `set -e`)은 수습하지 않는다 — 안전하게 이어 갈 수 있는 자리가 아니다.

수습했든 안 했든 멈출 때마다 `.ticket-loop/stops/<id>.json`(사유, 이슈, PR, 로그 경로, 워크트리, 다시 실행할 명령)이 남고 이슈 코멘트에 그 id가 적힌다. 직접 이어받으려면 그 저장소의 에이전트 세션에서 `/loop-triage <id>`(Codex는 `$loop-triage`)를 부른다. 기록과 앞선 판정을 읽고, 병합 전에는 묻는다.
