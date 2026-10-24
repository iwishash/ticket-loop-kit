# 검증 상태

[README](../README.ko.md) · [English](verification.md)

백엔드마다 실제 티켓 1건으로 확인했다(자세한 기록은 [CHANGELOG.md](../CHANGELOG.md)):

| 백엔드 | 티켓 | 벽시계 | 수리 |
|---|---|---|---|
| Orca 1.4.x | iwishash/boiler-webapp #34 → PR #38 (2026-10-12) | 10분 | 0회 |
| cmux 0.65 | iwishash/boiler-webapp #39 → PR #40 (2026-10-12) | 7분 | 0회 |
| tmux 3.8 | iwishash/ticket-loop-dummy #1 → PR #2 (2026-10-13) | 4분 | 0회 |

무인 수습(0.9.0, iwishash/ticket-loop-dummy·tmux, 2026-10-17)은 이어 갈 수 있는 멈춤마다 한 번씩 돌렸다. 실패는 모두 티켓이 도는 사이 병합한 다른 PR에서 나왔다 — 워커가 미리 볼 수 없게:

| 멈출 일 | 티켓 | 수습 세션 | 벽시계 |
|---|---|---|---|
| 병합 뒤 검증 실패 | #12 → PR #13 | 수정 PR #14(코드) 병합, 검증 다시 통과 | 6분 |
| 워크트리 준비 실패 | #17 → PR #19 | 수정 PR #18(준비 스크립트) 병합, 워크트리를 당겨 준비 통과 | 7분 |
| 수리를 다 쓴 CI 실패(`REPAIR_ROUNDS=0`) | #21 → PR #22 | 티켓 브랜치에 `main`을 병합하고 고쳐 push | 6분 |
| 워커가 PR 없이 멈춤 | #23 | 진단만, `halt (needs-human)` — 루프는 요약을 붙여 멈춤 | 멈춤 |

준비 실패 실측에서 0.9.1이 고친 버그가 나왔다: 수정 PR 제목 `fix: #17 …`이 병합되며 아직 열려 있어야 할 티켓을 닫았다. #23의 멈춤에 사람이 `/loop-triage <id>`를 부른 경로(헤드리스, 읽기 도구만)도 기록을 찾고 앞선 판정을 그대로 두며 다시 실행할 명령과 워크트리 정리를 안내했다(정리는 묻고 한다).

그 밖에 확인한 것: 멈춤 보고(0.8.8) — iwishash/ticket-loop-dummy #3을 cmux로 두 번 멈추고(SIGHUP·SIGTERM → 이슈 코멘트·`loop-stopped` 라벨·Slack) 세 번째에 PR #4로 병합(3분, 라벨 떼기), `tests/smoke.sh`, 저장소(당시 비공개)를 실제로 받는 npx 껍질, 0.2 설치본 마이그레이션(스모크 테스트만).

아직 확인하지 않은 것:

- 실제 루프에서의 묶음 검증(`POST_MERGE_EVERY`가 1이 아닐 때)과 묶음 실패의 이분 탐색(`tests/smoke.sh`가 실제 git 저장소와 가짜 명령으로 다룬다).
- 실제 티켓에서의 `POST_MERGE_PORT`·`POST_MERGE_RETRY_CMD`·`CI_SKIP_CMD`·`CI_SKIP_REGEX`와 수리 프롬프트(`POST_MERGE_CMD`는 위 수습 실측에서 돌았다. 모든 실측이 수리 0회). rental-portal(PR #82)에 설정돼 있다.
- `install.sh`의 라벨 생성·Orca 등록 단계(시험에서 껐다).
- boiler-webapp 1회 이후의 `/setup-ticket-loop`.
- Linux와 WSL. Linux 분기는 한 번도 실행되지 않았다. WSL 안의 tmux 백엔드부터 시도할 것. WSL에서 `orca-ide`로 Orca를 조종하는 건 미해결(Windows 앱이냐 WSLg의 Linux AppImage냐, 경로 대응).
- 무인 수습의 플레이크 판정, 루프 버그 판정과 키트 버그 보고서, 판정 없음(시간 초과·idle), CI 실패가 아닌 충돌. `tests/smoke.sh`가 가짜 백엔드·`gh`로 다룬다.
- Codex 워커. 프리셋·프롬프트·스킬 배치·`AGENTS.md`·`.codex/rules/ticket-loop.rules`·`--agent codex`는 갖춰졌지만 Codex가 설치된 컴퓨터에서 돌린 적이 없다: idle 판정, `$implement`가 스킬을 집는지, 수리 프롬프트, 규칙 파일이 `--dangerously-bypass-approvals-and-sandbox` 아래에서도 로드되는지.
- 출처 저장소 rsrehab/rental-portal은 아직 자체 `scripts/orca-ticket-loop.sh`를 쓴다.
- 멈춤 보고 중 실제로 거친 것은 신호 두 가지(SIGHUP·SIGTERM)와 `die`(위 수습의 `halt`)다. `set -e`·Ctrl-C·SIGPIPE 경로는 smoke(가짜 `gh`·`curl`)와 pty·`tee` 실험으로만 확인했다.
