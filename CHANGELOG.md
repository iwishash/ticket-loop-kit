# Changelog

## 0.9.19 — 2026-10-27

스펙 리포트 결함 하나(#37)를 PR #38로 고쳤다. 리포트 생성만 바뀌고 루프 판정에는 닿지 않는다.

- **PR 목록이 인자 한도를 넘어도 스펙 리포트를 쓴다(#37).** `write_spec_report`는 PR 목록(`gh pr list --state all --limit 300`, 본문 포함)을 `jq --argjson`으로 명령 인자에 실었다. PR 본문이 쌓여 이 JSON이 인자 한도를 넘으면 jq가 `Argument list too long`으로 실행되지 않았다. PR 목록은 다시 돌려도 그대로라, 한 번 넘은 저장소는 그 뒤 모든 스펙의 리포트가 실패했다. 실측(rsrehab/rental-portal 스펙 #396, 0.9.17, macOS): PR 272건이 1.29MB, `ARG_MAX`는 1MB. Linux는 인자 하나에 128KB 한도가 따로 있어 더 일찍 걸린다.
  - 이슈·PR·기록 목록 셋을 표준 입력(here-string)으로 넘긴다. `REPORT_JQ` 본문은 그대로이고 앞에 `input as $issues | input as $prs | input as $recs |`가 붙었다. 같은 자료로 그린 리포트는 전과 바이트 단위로 같다.
  - 이슈가 제안한 `printf … | jq` 파이프는 쓰지 않았다. jq가 마지막 값을 읽고 먼저 끝나면 `printf`가 남은 줄바꿈을 쓰다 EPIPE를 맞을 수 있고, `pipefail` 아래서는 써진 리포트가 실패로 잡힌다.
- **생성이 실패해도 이전 리포트가 남는다(#37).** `> "$out"` 리다이렉션이 jq보다 먼저 파일을 비워, 다시 만들다 실패하면 0바이트 `spec-N.html`이 남았다. 이제 리포트 옆 `spec-N.html.tmp`에 쓰고 성공했을 때만 옮기며, 실패하면 임시 파일만 지운다. jq가 도는 중에 루프가 신호로 죽으면 `.tmp`가 남을 수 있다(전에는 반쯤 쓴 리포트가 남았다).
  - 스모크로 확인한 것: 가짜 `gh`로 1.35MB PR 목록의 리포트, jq에서 실패할 때 이전 리포트가 남고 임시 파일이 없음. 둘 다 0.9.18 코드에서는 실패한다. CI(Linux)도 통과했다.
  - 문서: 가이드북 7장(실패해도 이전 리포트가 남는다)·부록 D.
- 이미 설치된 저장소: 키트를 올리면 바로 적용된다. 리포트가 실패했던 스펙은 `--parent <스펙>`을 다시 돌리면 리포트가 생긴다. PDF 재빌드.

## 0.9.18 — 2026-10-25

0.9.17의 스펙 끝 검증에서 빠지던 경우 하나(#34)를 PR #36으로 막았다. 또 `/setup-ticket-loop`가 그 env로 평소 검증과 스펙 끝 검증을 나누는 배선을 묻게 했다(PR #35). #34는 루프 판정에 닿는다 — 병합이 모두 검증을 거친 뒤에 스펙이 닫히면 루프 끝에 검증이 한 번 는다. PR #35는 스킬 문서만 바꾼다.

- **병합이 모두 검증을 거친 뒤에 닫힌 스펙도 스펙 끝 검증을 받는다(#34).** `POST_MERGE_EVERY=1`이면 병합마다 검증이 통과해 창이 빈다. 그래서 루프 끝에서 처음 닫히는 스펙(사람이 마지막 티켓을 닫음, 하위 이슈 상태 반영 지연)은 그 번호를 받는 검증 없이 끝났다. `pm_spec_closed`와 `pm_flush_end`가 빈 창에서는 아무것도 하지 않았기 때문이다. 스펙 끝에만 무거운 쪽을 돌리는 저장소(rsrehab/rental-portal ADR 0010)라면 그 스위트가 조용히 빠졌다.
  - 이번 실행이 닫은 스펙은 창이 비어도 적는다. 이번 실행에서 그 번호를 싣고 통과한 검증이 이미 있었으면 적지 않는다(`PM_SPEC_COVERED`, 저장하지 않는다).
  - 루프 끝(메인 끝, `No tickets to process.`)에서 창에 병합 없이 스펙 완료만 있으면 기본 브랜치 끝에서 검증이 한 번 돈다. env는 `TICKET_LOOP_POST_MERGE_WHY=spec_end`와 그 스펙 번호이고, 로그는 `.ticket-loop/post-merge-<스펙>-end.log`, 로그 줄은 `post-merge check for the completed spec #40 — no passed check has covered it yet`이다. `POST_MERGE_EVERY`가 1보다 커도 마침 창이 비어 있었으면 같다.
  - 실패하면 무인 수습을 거쳐 (마지막) 스펙 이슈로 멈춘다(PR 없음). 멈춤 사유에 `(spec-end check for spec #40 — no merge was left unchecked)`가 붙고, 멈춤 기록의 `post_merge_window`는 `{"pending":[],"spec_complete":[40]}`이다. 스펙 번호는 `.git/ticket-loop-post-merge.json`에 남으므로 다시 실행하면 같은 번호로 돈다. 시작 줄이 그렇다고 알린다.
  - 검증이 꺼진 실행(`--skip-post-merge`, `POST_MERGE_CMD` 없음)은 전과 같다. 사람이 스펙 이슈까지 직접 닫은 경우는 범위 밖이다. 루프가 그 스펙을 닫지 않았으니 알아채지 못한다.
  - 알려진 한계 둘:
    - 실패하면 이미 닫힌 스펙 이슈에 `loop-stopped` 라벨이 붙고, 재실행이 통과해도 남는다. 기존 루프 끝 검증의 실패와 같다.
    - 지난 실행이 남긴 스펙 완료를 다음 실행에서 다른 티켓의 검증이 받으면, 그 티켓 기록의 `post_merge_spec_complete`에 실린다. 0.9.17이 남은 창을 넘기는 방식과 같다.
  - 스모크로 확인한 것:
    - 빈 창에서 닫힌 스펙의 루프 끝 검증.
    - 그 번호를 싣고 통과한 검증이 이미 있으면 다시 돌지 않음.
    - 실패: 수습, 멈춤 이슈, 상태 파일, 멈춤 기록의 창.
    - 실패 뒤 재실행, 검증이 꺼진 실행.
  - 문서: 가이드북 7장 6단계·부록 D, `docs/loop*.md`, loop-triage·setup-ticket-loop 스킬. loop-triage는 창이 빈 스펙 끝 검증이 실패하면 그 스펙의 병합 PR 전부를 원인 후보로 본다.
- **`/setup-ticket-loop`가 스펙 끝에만 더 무겁게 돌릴 것이 있는지 묻는다(PR #35).** 0.9.17의 env는 결정 표의 `POST_MERGE_CMD` 행에 설명만 있었다. 그래서 사용자가 따로 말하지 않으면 "평소엔 가볍게, 스펙 끝에만 무겁게" 배선이 빠졌다.
  - 결정 표에 "스펙 끝 분기" 행이 생겼다. 무거운 스위트(공유·클라우드 DB, 넓은 스위트, E2E)가 있을 때만 묻고, 없으면 "없음"이다.
  - 새 절은 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`로 고르게 한다. `WHY`로 고르지 않는 것은 `POST_MERGE_EVERY=1`이면 스펙 끝 검증도 `every`이기 때문이다.
    - 고르는 부분은 `scripts/post-merge-env.sh` 하나에 둔다. 첫 실행·재실행 스크립트가 둘 다 이 파일을 source하므로 재실행도 같은 쪽으로 돈다.
    - `POST_MERGE_EVERY`는 가벼운 쪽 길이에 맞추고, 비밀 값은 `POST_MERGE_COPY` env 파일에서 읽는다.
  - 검증 절: 고르는 부분을 빈 값과 `1`로 source해 각각 가벼운 쪽과 무거운 쪽을 고르는지 본다(스위트는 돌리지 않는다).
  - 운영 문서·사람이 할 일: 어느 쪽이 돌았는지 보는 곳(검증 로그 첫 두 줄, 리포트의 `(…, spec #N complete)`)과, 기계마다 두는 무거운 쪽 비밀 값.
- 이미 설치된 저장소:
  - 키트를 올리면 #34는 바로 켜진다. 병합이 모두 검증을 거친 뒤에 스펙이 닫히면 루프 끝에 검증이 한 번 는다. 스펙 끝에만 무거운 쪽을 돌리는 저장소라면 그 무거운 쪽이 돈다(rental-portal이면 약 1시간).
  - 0.9.17의 상태 파일은 그대로 읽힌다. 되돌려도 0.9.17이 남은 스펙 번호를 읽는다.
  - PR #35는 앞으로 `/setup-ticket-loop`를 돌리는 저장소에만 닿는다.
  - PDF 재빌드.

## 0.9.17 — 2026-10-25

병합 뒤 검증 기능 하나(#32)를 PR #33으로 넣었다. 검증 명령이 받는 env가 늘었다. 루프 판정은 두 군데 바뀐다. 스펙을 끝낸 문서 PR은 이제 검증 창에 들어가고, 루프 끝에서는 스펙을 닫은 뒤 남은 창을 검증한다.

- **병합 뒤 검증 명령이 왜 도는지와 스펙 완료 여부를 env로 받는다(#32).** 저장소가 평소에는 가벼운 검증을, 스펙이 끝날 때만 무거운 검증을 돌리고 싶을 때가 있는데, `POST_MERGE_CMD`는 지금 왜 도는지 알 수 없었다. `run_post_merge`가 이유(`PM_WHY`)를 로그에만 적었기 때문이다. 쓰임: rsrehab/rental-portal ADR 0010 — 통합 테스트를 평소에는 로컬 Postgres로 약 4분, 스펙 끝에만 공유 클라우드 DB로 약 1시간.
  - `POST_MERGE_CMD`·`POST_MERGE_RETRY_CMD`가 env 둘을 받는다.
    - `TICKET_LOOP_POST_MERGE_WHY`: `every`(병합 `POST_MERGE_EVERY`개), `spec_end`(스펙 끝), `run_end`(이번 실행의 마지막 티켓·남은 티켓 없음·루프 끝) 중 하나.
    - `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`: 이 검증이 덮는 병합 가운데 스펙(`--parent` 또는 티켓의 부모)을 끝낸 것이 있으면 그 스펙 번호(드물게 여럿이면 공백 구분), 없으면 빈 값.
  - 재실행·이분 탐색·수습 뒤 재검증은 첫 실행과 같은 값을 받는다 — 실패한 검증과 같은 조건(같은 DB 등)으로 다시 돈다. 그래서 이슈가 제안한 `after_triage`·`bisect` 이유 값은 두지 않았고, 실행 종류를 따로 넘기는 env도 넣지 않았다.
  - 스펙 완료는 이유와 따로 본다. 루프가 창이 찼는지를 먼저 보므로, `POST_MERGE_EVERY=1`이면 스펙의 마지막 병합 뒤 검증도 이유가 `every`다. 스펙 완료는 아직 검증하지 않은 병합과 함께 `.git/ticket-loop-post-merge.json`(`spec_complete`)에 남는다. 그래서 스펙 끝 검증이 실패해 멈춘 뒤 다시 실행한 루프의 검증도 같은 스펙 번호를 받는다. 검증이 통과하면 비운다. 멈춤 기록의 `post_merge_window`에도 실린다.
  - **스펙을 끝낸 문서 PR은 창에 넣는다.** CI가 붙지 않는 문서 PR은 전처럼 창에서 빼지만, 그 PR이 스펙을 끝냈으면 넣는다. 전에는 창이 비어 있으면(`POST_MERGE_EVERY=1`에서 흔하다) 그 스펙에는 스펙 끝 검증이 없었다.
  - **루프 끝에서 스펙을 먼저 닫는다.** 순서가 `close_spec_if_done "$PARENT"` → 남은 창 검증이 됐다(전에는 반대). 그래서 거기서 처음 닫히는 스펙(사람이 마지막 티켓을 닫음, 하위 이슈 상태 반영 지연)도 그 검증이 스펙 번호를 받는다. 대신 그 마지막 검증이 실패해도 스펙 이슈는 이미 닫혀 있다 — 티켓 하나 쪽은 전부터 검증 전에 닫았다.
  - 받은 값은 검증 로그마다 첫 줄(`# ticket-loop: TICKET_LOOP_POST_MERGE_WHY="…" TICKET_LOOP_POST_MERGE_SPEC_COMPLETE="…"`)에 남는다. 티켓 기록에는 `post_merge_why`·`post_merge_spec_complete`로 남고, 스펙 리포트는 결과 뒤 괄호에 적는다(예: `post-merge check passed, covering #61 #62 (every, spec #60 complete)`). 루프 끝 검증은 어느 티켓 기록에도 들지 않으므로 로그 첫 줄에만 남는다.
  - 스모크로 확인한 것:
    - 첫 실행·재실행·이분 탐색이 같은 env를 받고 로그 첫 줄에 남기는지.
    - `pm_due`의 이유 키.
    - 창의 스펙 완료: 저장·읽기·통과, 빈 창, 검증이 꺼진 실행, 0.9.16 상태 파일.
    - 루프 끝 검증과 수습 뒤 재검증이 받는 값.
    - 기록 필드, 리포트 표시, `run_ticket`·메인 끝의 배선.
  - 문서: 가이드북 설정 표·7장 6단계(예시 포함), `docs/loop*.md`, setup-ticket-loop·loop-triage 스킬. loop-triage는 실패를 재현할 때 로그 첫 줄의 값을 그대로 주고 돌린다.
- 이미 설치된 저장소: 키트를 올리면 env는 바로 넘어간다. 검증 명령이 그 값을 읽어야 쓸모가 있다(rental-portal은 `POST_MERGE_EVERY=1`로 두고, `POST_MERGE_CMD`가 `TICKET_LOOP_POST_MERGE_SPEC_COMPLETE`가 비어 있지 않을 때만 클라우드 DB를 고르게 한다). 검증 로그 첫 줄이 하나 늘므로, 첫 실행 로그를 읽는 재실행 스크립트가 맨 윗줄을 테스트 출력으로 다루면 확인한다. 0.9.16의 상태 파일은 그대로 읽힌다. PDF 재빌드.

## 0.9.16 — 2026-10-23

0.9.12 실측에서 나온 결함 하나(#24)와 리포트 기능 하나(#25)를 PR #28 #29로 넣었다. #24는 루프의 판정에 닿는다 — CI 대기가 빈 체크 목록을 읽을 때. #25는 리포트 생성만 바꾼다(설정이 비어 있으면 전과 같다).

- **CI 대기: 빈 체크 목록은 실패가 아니라 재등록 중으로 본다(#24).** `ci_passed`가 `gh pr checks --watch --fail-fast`의 비0 종료 뒤 체크 상태(bucket)를 다시 읽을 때 목록이 비어 있으면 실패로 읽고 워커에게 CI 수리를 보냈다. GitHub가 job을 다시 큐에 넣는 순간(재시도·장애 복구)에는 PR의 체크 목록이 잠깐 비고 `--watch`가 "no checks reported"로 끝난다. 실측(rental-portal #316, 2026-10-23): run은 이미 success였고 check-run 하나가 GitHub 장애로 `in_progress`에 굳었다가 27분 뒤 attempt 2로 다시 돌았는데, 그 빈 목록을 실패로 읽어 할 일 없는 수리 1회를 보냈다.
  - 빈 목록·못 읽음이면 `CI watch ended with an empty check list (checks being re-registered?) — waiting for them to reappear (n/N)`을 남기고 `wait_checks_appear`(`CI_APPEAR_TIMEOUT_SEC`, 15분)를 다시 거친 뒤 다시 본다(`GH_TRIES`번까지). 그 안에 나타나지 않거나(`the checks did not reappear within Ns`) `GH_TRIES`번째도 비어 있으면(`the check list was empty after N CI watches — treating it as a failure`) 전처럼 실패다.
  - `--watch`의 stderr를 버린다 — 타임스탬프 없는 줄이 루프 로그에 그대로 섞였고, 결과는 어차피 bucket으로 다시 읽는다.
  - 이슈의 세 번째 제안(run 결론은 success인데 check-run 하나가 `in_progress`로 오래 남으면 경고)은 넣지 않았다.
  - 스모크: 가짜 `gh`가 체크 개수를 차례로 내고 "no checks reported" stderr 줄을 찍는다 — 빈 목록 뒤 체크가 다시 나타나면 통과, 끝내 비면 `GH_TRIES`번 뒤 실패, 다시 나타나지 않으면 실패, 처음부터 없으면 실패, 모든 사례에서 stderr 줄 0.
  - 비용: 빈 목록이 났을 때 재등록 대기(최대 15분)가 수리 대신 든다. 체크가 정말 없어진 PR은 15분 뒤 전처럼 실패한다.
- **스펙 리포트가 PR 본문의 '사람 확인 필요' 절을 모아 보인다(#25).** 워커는 스펙과 다르게 정했거나 스펙이 사람에게 남긴 결정을 내린 것을 PR 본문에 적는데, 리포트에는 인수 조건 체크 수만 보여 병합된 PR을 하나씩 열어야 했다(rental-portal 스펙 #313: 14개 PR의 "남은 판단 사항" 116줄 가운데 사람이 정할 것은 두 건).
  - 새 설정 `REPORT_DECISIONS_HEADING`(기본 비움 = 전과 같다): PR 본문 절의 마크다운 제목(글자 그대로, 예: `사람 확인 필요`). 저장소마다 절 이름이 다르므로 키트는 이름만 받는다. 키트의 `pr` 스킬 템플릿은 그대로다 — 그 "Remaining judgement calls"는 기록용이라 기본으로 모으지 않는다. 사람이 정할 것만 적는 절을 `pr` 스킬에 따로 두고 그 이름을 적는다.
  - 지정하면 리포트가 각 티켓 PR 본문에서 그 절(다음 같은·상위 수준 제목 앞까지, 하위 절 포함)을 뽑아 머리에 "<제목> — N PRs" 블록으로 모은다(티켓·PR 링크, 절 본문 원문 — 이스케이프·줄 바꿈 유지). KPI에 건수, 절이 있는 행의 Result brief에 ⚑ 표시와 링크. 절이 없거나 빈 PR은 나오지 않고, 하나도 없으면 블록도 없다.
  - 리포트 로그 줄에 `'사람 확인 필요': N PRs`, 회고 안내 줄에 `(its '사람 확인 필요' list collects N PRs for a human)`이 붙는다(리포트를 쓴 스펙만).
  - 스모크: 절 있음(하위 절·`<>` 글자)·빈 절·제목 아닌 글자의 세 PR, 제목 없는 렌더에 블록·표시·타일 없음, `write_spec_report`(가짜 `gh`)의 로그 줄과 `REPORT_DECISIONS`, `suggest_retro` 안내. 가이드북 설정 표·7장 9단계, loop-reports README 템플릿.
- 이미 설치된 저장소: 키트를 올리면 #24는 바로 켜진다. #25는 `loop.env`에 `REPORT_DECISIONS_HEADING`을 적어야 켜진다(rental-portal은 `pr` 스킬에 그 절을 둔 뒤). 열린 이슈 #3·#12는 사람 실측이 먼저라 그대로다. PDF 재빌드.

## 0.9.15 — 2026-10-23

설치기 기본값 하나(#26)를 PR #27로 바꿨다. 루프 판정에 영향을 주는 변경은 없다. 새 설치에서 기획 스킬(workflow 묶음)은 늘 꺼져 있었고, `mattpocock-skills` 플러그인이 켜진 저장소에서는 체크리스트가 "Disable plugin"을 기본 켜짐으로 띄웠다 — 두 토글이 독립이라 플러그인을 끄면 기획 스킬이 이 저장소에서 사라지는데 벤더링은 꺼진 채라 사용자가 빈손이 됐고, 플러그인이 없는 새 설치는 `--workflow-skills`를 기억해야 스펙 → 티켓 → 회고 흐름을 쓸 수 있었다.

- **새 설치의 workflow 기본값을 플러그인 유무로 정한다(#26).** 명시 플래그 > 지난 매니페스트 > 새 설치: `mattpocock-skills` 플러그인이 이 저장소에 켜져 있으면(enabledPlugins, user < project < local) 끔 — 기획 스킬은 이 머신에서 플러그인이 주고, core(`tdd`·`ticket-review`)는 implement가 부르고 이름을 바꾸고 커밋에 고정해야 하니 그래도 들인다. 플러그인이 없으면 켬. `--agent codex`는 플러그인 개념이 없으니 켬. upstream 26개 전부를 들이는 길은 두지 않았다(0.6 결정 유지). 규칙은 `sync-mattpocock-skills.sh`의 `auto`에 있고, npx 껍질은 같은 규칙으로 체크리스트 기본값을 정한다(플래그 없이 `--check`를 불러 스크립트 판정과 어긋나지 않게). 동기화 요약에 `planning skills: vendored|not vendored — <근거>` 한 줄이 붙는다(명시 플래그면 없음).
- **plugin finding은 알림(info)이다.** 경고가 아니다 — core는 어차피 들이고 선택기에 `/tdd`와 `/mattpocock-skills:tdd`가 나란히 보일 뿐 루프는 벤더링한 쪽을 돈다. 플러그인만 켜진 저장소의 `--check`는 종료 0이고, `install.sh`가 "Skill conflicts found"를 내지 않는다. fix 명령(`claude plugin disable … --scope project`)은 그대로 두되 "켜면 기획 스킬도 벤더링하라"를 덧붙였다.
- **npx 체크리스트**: "Also vendor the planning skills" 노트에 기본값의 근거(플러그인이 준다 / 플러그인 없음 / 지난 설치 유지). "Disable plugin … for this repo"는 **기본 꺼짐**, 노트에 결합 관계(끄면 위 항목도 켜라). `--yes`는 플러그인을 건드리지 않는다.
- 주의: 플러그인은 사람·머신 단위이고 벤더링은 저장소 단위다. 플러그인에 맡기는 기본값은 다른 clone·클라우드 세션엔 기획 스킬이 없다는 뜻이라 요약과 노트에 적었다. 팀이 함께 쓰려면 `--workflow-skills`.
- 스모크: 새 설치 플러그인 없음 → 9개와 근거 줄, `--no-workflow` 뒤 재실행은 지난 선택(끔) 유지, 플러그인 켜짐 → `--check` 0·2개·근거 줄, `--workflow`가 덮고 재실행이 유지, codex 새 설치는 플러그인이 있어도 9개, npx `--yes`(없음 9 · 켜짐 2, 플러그인은 그대로)와 `install.sh`(켜짐 2, 충돌 경고 없음). 기존 첫 동기화 검사는 `--no-workflow`를 명시한다.
- 이미 설치된 저장소: 매니페스트가 있으니 지난 선택이 그대로 이어진다. 바뀌는 것은 없다. README 영·한의 표 두 줄과 가이드북 3장 문장을 고쳤다. PDF는 재빌드하지 않았다.

## 0.9.14 — 2026-10-23

스킬 동기화 결함 하나(#20)를 PR #21로 고쳤다. 루프 판정에 영향을 주는 변경은 없다. rental-portal에서 0.9.10 → 0.9.12 `init --yes`를 돌리자 손으로 검사 셋을 더해 둔 `.agents/skills/ticket-review/SKILL.md`가 upstream `code-review` 그대로로 되돌아갔다 — `PROJECT_OWNED=(implement pr)`가 키트 관리 파일인 sync 스크립트 안에 고정돼 있어 저장소가 다른 스킬을 소유로 표시할 길이 없었고, 설치기 출력에도 덮어쓴 흔적이 없었다.

- **`sync-mattpocock-skills.sh`가 매니페스트의 `project_owned`를 읽는다(#20).** `.agents/skills/.mattpocock.json`의 `project_owned`를 `PROJECT_OWNED`에 더한다. 저장소에 놓이는 이름(`ticket-review`)으로 적고, `code-review`라고 적으면 `ticket-review`로 읽는다(그대로 두면 skip한 뒤 "not in this kit's skill set"으로 지웠다). 소유 스킬은 이름을 바꾼 뒤에 검사하고, 매니페스트 `skills`에 싣지 않으며, `--check`의 `foreign`으로 알리지 않고, 링크만 챙긴다. 다음 매니페스트에도 남는다. 요약의 `project-owned (update by hand)`에 함께 보인다.
- **덮어쓴 로컬 수정을 알린다.** 덮어쓰기 전에 지난 동기화의 upstream 커밋(매니페스트 `commit`, 임시 클론의 worktree) 사본에 같은 치환을 한 것과 비교한다. 다르면 로컬 수정(커밋 여부 무관)으로 보고 덮어쓴 뒤 요약에 `overwrote local edits: <이름>`을 낸다 — git에서 되돌리고 `project_owned`에 적으라는 안내와 함께. 지난 `skills`에 없던 디렉터리(방금 소유를 푼 것, foreign)도 같은 잣대. `.DS_Store`는 무시. 그 커밋을 받지 못하면 `note    could not compare with the previous sync's upstream commit (…)` 한 줄을 내고 조용히 넘어가지 않는다.
- 치환 루프를 `rename_refs()`로, 복사·링크·치환을 `vendor()`로 뽑았고 `path_in()`을 현재·지난 plugin.json이 같이 쓴다. kept 스킬도 같은 길을 탄다. `loop.env` 변수 대안은 만들지 않았다(매니페스트에 이미 필드가 있다). README 두 벌에 `project_owned`와 덮어쓴 안내를 적었다.
- 스모크: 가짜 upstream을 한 커밋 더 올려 "upstream 변경"과 "로컬 수정"을 가른다 — 소유 스킬 보존·요약 표시·`--check` 침묵, `tdd` 갱신(치환 포함)과 `overwrote` 없음, 커밋된 로컬 수정 덮어쓰기와 `overwrote local edits: grilling`, 매니페스트 `project_owned`·`skills`, 재동기화 무안내, 소유 해제 뒤 다시 들임과 안내, `code-review` 별칭, 모르는 커밋의 `could not compare`.
- 이미 설치된 저장소: 키트를 올린 뒤 손으로 고쳐 쓰는 들인 스킬 이름을 `.agents/skills/.mattpocock.json`의 `project_owned`에 적는다(rental-portal은 `ticket-review`). 0.9.12 설치로 되돌아간 파일은 git에서 되돌린다. 가이드북·PDF는 바뀐 것이 없다.

## 0.9.13 — 2026-10-23

0.9.12 실측에서 나온 결함 하나(#22)를 PR #23으로 고쳤다. 루프의 판정에 닿는다 — 티켓 사이의 다음 대상 조회가 *성공하면서* 빈 목록을 줄 때.

- **티켓 사이의 빈 대상 목록은 한 번 더 확인하고, `--parent`면 스펙과 맞춰 본 뒤에야 "남은 티켓 없음"으로 읽는다(#22).** #8은 조회 *실패*만 막았다. 실측(`--parent 313`, 2026-10-23): #315 병합 직후 `pm_due`가 `skip` 줄 하나 없이 "no more tickets"를 내 열린 ready 하위 이슈 12건을 두고 병합 뒤 검증을 앞당겼다(창 4 대신 2, 통합 테스트 55분 추가). 같은 빈 응답이 메인 고리에서 났다면 12건을 남기고 "No more tickets to process."로 정상 종료하고 finished 알림을 보냈을 것이다. `gh issue list`와 `sub_issues` 중 어느 쪽이 빈 값을 줬는지는 남은 기록으로 알 수 없다.
  - `pick_targets`: 조회가 성공했는데 후보가 0행이면 `ticket lookup returned 0 candidates` 한 줄을 남기고 2로 끝난다(목록은 비어 있다). 후보가 있었지만 담당자·스펙·막힘·PR로 모두 걸러진 빈 목록은 전처럼 0이고 skip 줄이 남아 구분된다.
  - 새 `pick_next_targets`(`pm_due`와 메인 고리 — 시작 전 첫 계산은 `pick_targets` 그대로): 0행이면 `empty ticket list — re-checking in 30s`(새 상수 `PICK_RECHECK_SEC`) 뒤 한 번 더 조회한다. 두 번째가 목록을 주면 그 목록, 두 번째도 0행이면 `--parent`가 없을 때 빈 목록으로 확정한다.
  - `--parent`면 새 `spec_empty_list_check`가 스펙과 맞춰 본다: 스펙 요약(`issues/N`의 `sub_issues_summary` — 목록과 다른 끝점)에 열린 하위 이슈가 없으면 빈 목록이 맞다. 있으면 `sub_issues`가 요약의 `total`보다 적게 돌려줬거나(빈·부분 응답), 돌려준 것 가운데 열려 있고 `READY_LABEL`(+`SCOPE_LABEL`)이 붙고 `IN_REVIEW_LABEL`이 없는 것이 있으면(그것은 `issue list`에 있었어야 한다) 믿지 않는다. 열린 하위 이슈가 전부 ready 라벨이 없거나(needs-info·ready-for-human …) in-review면 빈 목록이 맞다. 이슈 #22가 제안한 "요약의 `total − completed > 0`이면 불신"은 코드 리뷰에서 결함으로 드러나 이렇게 바꿨다 — 그대로 하면 그런 하위 이슈가 하나라도 남은 스펙은 끝마다 5분 뒤 멈춤으로 끝나고 루프 끝 검증(`pm_flush_end`)을 건너뛴다. `candidates`의 하위 이슈 조회도 같은 `spec_sub_issues`(번호·상태·라벨)를 쓴다.
  - `pm_due`: 조회 실패(1)와 불신(2) 둘 다 검증을 미룬다 — 메인 고리가 다시 계산하고, 정말 없으면 루프 끝 검증이 덮는다. 메인 고리: 불신이면 #8의 조회 실패와 같은 방식으로 `PICK_RETRY_SEC` 동안 다시 해 보고(한 바퀴에 재확인 30초가 더 든다), 그래도 같으면 `ticket list empty but spec #N has open sub-issues`로 멈춘다 — 처리 중인 티켓이 없으므로 이슈 코멘트·무인 수습 없이 stopped 알림과 멈춤 기록(`other`)만 남는다. 두 번째 0행 뒤 스펙 조회가 실패하면 조회 실패(1)로 간다.
  - 비용: 실행 끝마다 재확인 30초가 한두 번(`pm_due`의 미리 계산 + 메인 고리) 더 든다. 스펙 끝에서 요약의 `completed`가 이슈 닫힘을 늦게 반영하면 메인 고리가 최대 5분 재시도 뒤 멈춤으로 끝날 수 있다 — 실측 전.
- 스모크: 가짜 `gh`가 호출 차례로 성공한 빈 응답을 넣고(`LIST_EMPTY_FROM/TO`, `KIDS_EMPTY_FROM/TO`), 스펙 요약(`SPEC_SUMMARY`)과 상태·라벨이 든 하위 이슈(`kids`)를 준다. 이슈의 네 사례를 함수·`pm_due`·메인 고리 세 심에서, 그리고 needs-info·in-review만 남는 경우와 `--label` 범위 밖을 본다. `pm_due` 하네스의 `log`가 실제처럼 stderr로 쓰게 고쳤다(명령 치환에 섞여 대상 목록을 오염시키던 것). 부록 D·PDF 재빌드.
- 이미 설치된 저장소: 키트를 올리면 바로 켜진다. `loop.env`에 새로 적을 것은 없다(`PICK_RECHECK_SEC`는 덮어쓸 수 있다).

## 0.9.12 — 2026-10-22

트리아지에서 ready-for-agent로 분류한 나머지 셋(#8 #11 #10)을 PR #18 #17 #19로 고쳤다. 셋 다 루프의 판정에 닿는다 — 티켓 고르기의 GitHub 조회 실패, idle 오판, 그리고 사용량 한도·확인 창 감지.

- **다음 티켓 고르기가 GitHub 조회 실패를 빈 목록·"막히지 않음"·"PR 없음"으로 읽지 않는다(#8).** `blocked_by`·`sub_issue_count`·`open_pr_for`·`candidates`는 `gh`가 재시도(`GH_TRIES`)까지 실패하면 출력 없이 비0으로 끝나고, `pick_targets`는 목록 조회가 실패하면 비0, 후보 하나의 검사가 실패하면 그 티켓만 `could not check (GitHub)`로 건너뛴다. 시작 전 첫 계산이 실패하면 바로 멈추고, 티켓 사이의 재계산이 실패하면 5분(`PICK_RETRY_SEC`, 1분 간격 `PICK_RETRY_EVERY_SEC`) 다시 해 본 뒤 `could not list tickets (GitHub)`로 멈춘다 — 처리 중인 티켓이 없으므로 이슈 코멘트·무인 수습 없이 알림과 멈춤 기록(`other`)만 남는다. 번호를 직접 준 실행은 사전 검사의 조회가 실패하면 멈춘다. 전에는 장애가 45초를 넘기면 "No more tickets to process."로 정상 종료하고 finished 알림을 보내거나, 막힌 티켓·PR이 열린 티켓을 시작할 수 있었다. 0.9.9의 `pm_due` "조회 실패 → 미룸" 분기도 이제 실제로 닿는다. 단, `blocked_by`가 일시 장애가 아닌 404(Not Found)를 받으면 이슈 의존성 API가 없는 환경(옛 GHES)으로 보고 "막힘 없음"(0)으로 읽는다 — `dependencies API not available (HTTP 404) — treating tickets as not blocked` 경고를 실행당 한 번 남긴다.
- **idle 판정 가드(#11):** 백엔드가 idle을 돌려주고 화면이 지난 idle 때와 같으면 PR 대기·수리 대기·수습 대기가 strike를 하나 셌는데, cmux에서 백그라운드 작업 알림으로 시작되는 턴 전후에 lifecycle이 잠깐 idle로 보이는 것으로 추정된다 — rental-portal #266에서 strike 3회 중 앞의 2회는 워커가 도구를 7번 호출하던 중이었다. 새 헬퍼 `session_active_recently <작업 폴더>`: `AGENT=claude`일 때 `claude_project_dir`(토큰 집계와 같은 변환)로 세션 기록 폴더를 찾아 `*.jsonl`(하위 `subagents/` 포함) 중 가장 최근 것이 `SESSION_LOG_FRESH_SEC`(새 상수, 기본 30초) 안에 갱신됐으면 아직 일하는 중으로 본다. 세 대기는 strike를 세기 직전에 이를 보고, 활성이면 strike를 세지 않고 연속 횟수를 0으로 되돌리며(앞의 strike는 오판 집계에 더한다) `idle reported, but the session log was written Ns ago — still working` 한 줄을 연속된 idle에서 한 번만 남긴다. claude가 아니거나 폴더·파일이 없거나 창 밖이면 전과 같다 — strike를 줄이기만 하고 늘리지 않는다. mtime은 `stat`(macOS `-f %m`, Linux `-c %Y`)로 읽는다. Codex 세션 기록은 아직 보지 않는다.
- **화면 분류(#10, #3의 화면 감지 부분 포함):** 실측 둘. rental-portal #262에서 워커가 `You've reached your … limit`로 멈추자 루프가 일반 idle로 보고 strike 셋 뒤 `worker_no_pr`로 멈춰 무인 수습 세션을 띄웠는데 그 세션도 같은 한도에 걸려 헛돌았다. #3(0.9.2, tmux)에서는 bypass 모드의 워커(서브에이전트의 Bash)가 `Do you want to proceed?`에 27분 멈춰 있는 동안 idle 신호가 비어 루프 로그가 한 줄도 없었다.
  - `screen_kind`: 세 대기(PR·수리·수습)가 #11의 가드 뒤, strike 직전에 화면 끝 25줄을 `usage_limit` · `permission_prompt` · 빈 값으로 가른다. 문구는 프리셋 변수 `USAGE_LIMIT_REGEX`(claude `reached your .* limit|usage limit`)·`PERMISSION_PROMPT_REGEX`(claude `Do you want to proceed\?`)이고 `loop.env`로 덮어쓴다. codex·그 외는 실측 전이라 빈 값 = 감지하지 않는다.
  - `usage_limit`(새 멈춤 종류): strike 없이 바로 멈춘다. 사유 `worker hit the usage limit: <그 줄>`에 화면의 재설정 시각 문구(`resets at …`, `try again at …`)가 있으면 붙인다. 무인 수습은 띄우지 않고(같은 한도에 걸린다), 알림 제목은 `Ticket loop stopped — worker hit the usage limit`, 이슈 코멘트·Slack·멈춤 기록은 `worker_no_pr`과 같은 길이다. 수습 세션 자체가 한도에 걸려도 `usage_limit`로 끝낸다. `loop-triage` 스킬의 종류 표에 더했다. 폴백 모델로 자동 전환은 #12(실측 뒤).
  - 확인 창 체류(`PROMPT_STALL_SEC`, 기본 300): 확인 창 문구가 든 화면이 그 시간 동안 글자 그대로면 idle 신호와 무관하게 `worker_no_pr`(진단만 하는 수습)로 멈춘다. 사유 `worker is waiting at a confirmation prompt: <그 줄> (screen unchanged for Ns)`. 백엔드 idle 대기가 타임아웃으로 돌아온 바퀴마다 보므로 idle 신호가 전혀 없어도 닿는다. 화면이 바뀌면 다시 세고, idle 신호가 살아 있어 strike가 먼저 차면 전과 같다. 루프는 확인 창에 답하지 않는다.
  - 대기 함수는 종류·사유를 `WAIT_STOP_FILE`로 호출부에 넘기고(bg_wait 서브셸), 호출부 세 곳이 `screen_stop_check`로 종류대로 멈춘다. `tickets.jsonl`에 새 필드는 없다. 한도 문구는 idle로 확인된 화면에서만 분류하므로 idle 신호가 아예 없는 상태(#2)에서 한도에 걸리면 여전히 타임아웃까지 간다.
- 스모크: 세 변경 각각에 가짜 `gh`·가짜 백엔드·가짜 시계로 수용 기준 전부와 결함 주입을 본다. 부록 D·PDF 재빌드.
- 이미 설치된 저장소: 키트를 올리면 claude 프리셋의 두 정규식과 세션 기록 가드가 바로 켜진다. codex나 문구가 다른 설치본은 실측 뒤 `loop.env`에 `USAGE_LIMIT_REGEX="${USAGE_LIMIT_REGEX:-…}"` 꼴로 적는다.

## 0.9.11 — 2026-10-22

이슈 트리아지에서 ready-for-agent로 분류한 작은 결함 셋(#5 #4 #6)을 고쳤다. 저장소에 CI가 없어 PR에 체크가 붙지 않던 것도 이번에 넣었다. 루프 판정에 영향을 주는 변경은 없다.

- **CI(#13):** `.github/workflows/smoke.yml` — PR과 main push에서 `bash tests/smoke.sh`를 돌린다. GitHub 러너는 SIGPIPE를 무시한 채로 단계를 시작하고 bash는 시작 때 무시된 신호를 trap할 수 없어 루프의 SIGPIPE 멈춤 검사가 종료 코드 0으로 실패했다. 워크플로가 python3로 SIGPIPE 처리를 기본값으로 되돌린 뒤 bash를 exec한다.
- **`implement` 템플릿 주석(#5):** 머리 주석의 `__PLACEHOLDERS__`라는 낱말이 `setup-ticket-loop` 5절의 `grep -rn '__[A-Z_]*__' …` 검사에 걸려, 자리표를 다 채운 설치본에서도 한 줄이 늘 남았다. "filled in the placeholders"로 바꿨다(검사가 옳고 템플릿이 틀린 것이라 정규식은 그대로). 스모크: 첫 설치본에서 `setup-ticket-loop` 스킬의 자리표 표에 적힌 이름을 모두 임의 값으로 채운 뒤 5절 검사를 그대로 돌려 결과가 비어야 통과한다. 이미 설치된 저장소: `implement` 스킬은 프로젝트 소유라 키트를 올려도 주석은 바뀌지 않는다. 5절 검사에 그 줄만 남으면 낱말을 손으로 고치면 된다.
- **`init` 기본값(#4):** `--backend`/`--agent` 없이 돌면 기존 `.ticket-loop/loop.env`를 무시하고 orca/claude를 기본값으로 잡아, tmux 설치본에 키트를 올릴 때마다 Orca 등록 실패 경고와 Orca 안내가 나왔다. 이제 플래그가 없을 때의 기본값은 `loop.env`의 `BACKEND`·`AGENT` → 없으면 orca/claude이고, `--yes`의 값과 대화형 선택의 미리 골라진 항목 둘 다에 적용한다. 명시한 플래그는 그대로 이기고 값이 다를 때만 전처럼 "Keeping …" 경고가 난다. `loop.env`의 값이 모르는 이름이거나 쓸 수 없는 백엔드면 `Ignoring BACKEND=… ; defaulting to orca.` 한 줄을 내고 기본값으로 간다. 배너에 `Backend: tmux (from .ticket-loop/loop.env)`처럼 출처를 표시한다. 스모크: tmux 설치본 `init --yes`(가짜 `ORCA_CLI` 호출 없음·Orca 안내 없음·"Keeping" 없음), `--backend orca`가 이김, `AGENT=codex` 기본, `loop.env` 없음, 모르는 값.
- **진행 로그(#6):** 워커가 `git fetch origin && git checkout -b issue-N-<slug> origin/<base>`를 했을 때 기본 브랜치가 그 사이 앞서 있었으면, 그 사이 병합된 남의 커밋이 `PROG_HEAD..HEAD` 범위에 들어 워커 커밋처럼 `commit` 줄로 찍혔다(판정에는 영향 없음). `progress_check`는 `origin/<BASE_BRANCH>`에서 닿는 커밋을 빼고(`--not`), HEAD가 기본 브랜치 안에서만 옮겨 갔으면 `#N: base moved to <sha>` 한 줄을 찍는다. 범위가 비어 HEAD 하나를 찍던 대체 경로도 이때는 찍지 않는다. 원격 추적 ref가 없으면 전과 글자까지 같다. 루프가 fetch를 더 하지는 않는다. 스모크: bare origin + 클론으로 "base A → origin/main이 두 커밋 앞섬 → 워커가 거기서 브랜치 → D 커밋 → amend"에서 `base moved to` 한 줄과 `commit D` 한 줄만 나오는지 본다.
- 부록 D·PDF 재빌드.

## 0.9.10 — 2026-10-22

문서만 바뀌었다. 0.9.9의 묶음 검증은 실패하면 원인 병합을 찾으려고 `POST_MERGE_RETRY_CMD`를 지난 커밋에서 돌린다. 그 사이 의존성이 바뀌었으면 재실행 명령이 먼저 설치해야 하는데, `/setup-ticket-loop`가 따라 쓰는 예시 줄은 스크립트만 불렀다.

- `setup-ticket-loop` 스킬, README 두 벌, 가이드북 7장 6단계: vitest 예시를 `POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-pnpm install --frozen-lockfile --prefer-offline && bash scripts/post-merge-retry.sh}"`로 바꾸고, 바뀐 게 없으면 설치는 몇 초라는 것과 왜 붙이는지를 적었다. 스킬에는 설치 명령을 그 저장소의 패키지 매니저 것으로 바꾸라고 적었다.
- 스킬의 `POST_MERGE_RETRY_CMD` 항목: "`POST_MERGE_EVERY`가 1보다 크면"을 "1이 아니면(기본 4)"으로 고쳤다(0.9.9에서 기본값이 4가 됐다).
- PDF 재빌드.
- 이미 설치된 저장소: 키트를 올려도 `loop.env`는 바뀌지 않는다. 재실행 명령이 설치된 의존성에 기대면 손으로 앞에 설치를 붙인다.

## 0.9.9 — 2026-10-21

병합 뒤 검증(`POST_MERGE_CMD`)이 티켓마다 돌아 루프 시간의 큰 몫을 차지했다. rental-portal 스펙 #248(0.9.5, cmux)에서 통합 테스트가 티켓마다 47~52분이었고, 12티켓에서 9.8시간이었다. 같은 기간 구현은 10시간 남짓이었다. 테스트 파일이 티켓마다 늘어 1회 시간은 10/16의 37분에서 52분으로 계속 길어지고 있다. 4개 스펙의 37회 가운데 진짜 회귀를 잡은 것은 한 번(10/16, #108 — 계약 CSV에 열을 더하고 통합 테스트 기대값을 안 고침)이다. 그 직후 회고로 워커가 PR 전에 관련 통합 테스트(`test:integration:related`)를 돌리기 시작했고, 그 뒤 34회는 모두 통과했다. 루프는 한 번에 한 티켓이라 병합 직전 기본 브랜치는 워커가 테스트한 그 상태다. 그래서 병합마다 도는 전체 스위트가 더해 주는 것은 "관련 테스트 선별이 놓친 테스트"뿐이었다.

고친 것:

- `POST_MERGE_EVERY`(새 변수, 기본 4): 병합 뒤 검증을 병합 N개마다 돌린다. 1이면 전처럼 병합마다, 0이면 개수로는 돌리지 않는다. 그 전이라도(0이면 이때만) 다음 둘 중 하나면 그 티켓의 병합 뒤에 돌린다 — 티켓 세 개짜리 스펙은 세 번째 티켓 뒤에 한 번 돈다.
  - 티켓의 스펙이 끝났다(루프가 스펙 이슈를 닫음).
  - 이번 실행의 마지막 티켓이다(`--max`, 번호 지정, 자동 선택이면 다음 대상이 없음).
  - 그 밖의 티켓은 요약·기록에 `deferred (k/N pending)`(0이면 `deferred (k pending)`)로 남는다. CI가 붙지 않는 문서 PR은 세지 않는다.

  기본 브랜치 끝에서 도는 검증은 그 전의 병합을 모두 덮으므로 검증을 거치지 않는 병합은 없다. 잃는 것은 "어느 병합이 깨뜨렸나"다.
- `pm_due`(새 함수): 언제 돌릴지 정한다. 자동 선택에서 마지막 티켓인지 보려고 다음 대상을 미리 계산하고, 미룰 때는 그 목록을 메인 고리가 그대로 쓴다(같은 조회를 두 번 하지 않는다). 조회가 실패하면 미룬다 — 대상 없이 끝나면 루프 끝 검증이 덮는다.
- 창(아직 검증하지 않은 병합): `pm_add`·`pm_passed`·`pm_save`·`pm_load`(새 함수).
  - 병합 순서의 이슈·PR·병합 커밋과 마지막으로 통과한 커밋을 `.git/ticket-loop-post-merge.json`에 남긴다. 잠금처럼 `.git` 안이라 커밋되지 않는다.
  - 루프가 멈췄다 다시 실행돼도 창이 이어지고, 시작 줄에 "not checked yet"으로 알린다. 통과한 커밋이 기본 브랜치에 없으면(강제 push) 그 시작만 버린다.
  - 검증이 다른 병합까지 덮었으면 결과에 `, covering #a #b …`를 붙인다.
- `pm_bisect`·`pm_probe`·`pm_describe`(새 함수): 묶음 검증이 재실행까지 실패하면 처음 실패하는 병합을 찾는다.
  - 같은 검증 워크트리에서 `POST_MERGE_RETRY_CMD`(실패한 테스트만)를 마지막으로 통과한 커밋에서 한 번 돌린다. 거기서 통과해야 탐색이 성립한다.
  - 그 뒤의 첫 부모 커밋들을 이분 탐색한다(병합 넷이면 세 번). 사람이 병합한 커밋도 범위에 든다.
  - 결과(`first failing merge: #13 (PR #23, commit …)`)는 결과 문자열·멈춤 사유와 멈춤 기록의 `post_merge_window`에 싣는다. 로그는 `post-merge-N-bisect-<커밋>.log`이고, 다시 돌린 시간은 병합 뒤 검증 시간에 든다.
  - 시작 커밋에서도 실패하면 "not found"로 적는다(플레이크·환경, 또는 재실행 명령이 테스트를 못 고름). 포트가 끝내 안 비거나 커밋으로 옮기지 못해도 거기서 그친다.
  - 재실행 명령이 없으면 탐색하지 않는다. 전체 스위트로 탐색하면 묶어서 아낀 시간을 도로 쓴다.
- `post_merge_recover`(새 함수): `run_ticket`에 있던 병합 뒤 검증 실패 뒤처리(무인 수습 → 수습 뒤 다시 검증)를 옮겼다. 묶음이면 사유에 `(merges checked together: … — first failing merge: …)`를 붙인다. 한 티켓 창의 사유는 전과 글자까지 같다.
- `pm_flush_end`(새 함수): 루프가 끝날 때(티켓이 없어 바로 끝나는 실행 포함) 창에 병합이 남았으면 한 번 더 검증한다(`post-merge-N-end.log`). 어느 티켓의 기록에도 들지 않고 로그에만 남는다. 실패하면 창의 마지막 티켓으로 멈춘다. 멈춤 기록·GitHub 기록의 PR·제목은 그 병합의 것으로 채우고, 앞 티켓의 시작 시각·워크트리는 싣지 않는다.
- 멈춤 기록에 `post_merge_window`(창의 시작·병합·탐색 결과)를 싣는다. GitHub 멈춤 코멘트에는 "아직 병합 뒤 검증을 통과하지 않은 병합" 한 줄을 붙인다. `loop-triage` 스킬은 묶음이면 원인 후보를 그 병합 전부로 보고 탐색 결과부터 확인한다.
- 스펙 리포트: 검증 시간은 그 검증을 돌린 티켓에 든다. 미룬 티켓의 결과 브리프에는 "post-merge check deferred (k/N pending)"가 나온다. 꼬리말에 한 문장을 더했다.
- 시작 줄: `post-merge check: on, every N merged tickets and when a spec or the run ends — …`(0이면 `on, when a spec or the run ends`, 1이면 전과 같은 `on`). 값이 0이나 양의 정수가 아니면 시작하자마자 종료 코드 2로 끝난다.
- `setup-ticket-loop` 스킬:
  - 결정 표에 `POST_MERGE_EVERY` 행을 더했다. 기본 4이고, 검증이 짧으면(몇 분) 사용자에게 묻고 1을 권한다.
  - `POST_MERGE_RETRY_CMD` 행에 이분 탐색에도 쓰인다는 것(설치된 의존성에 기대면 설치를 앞에)을 더했다.
  - `WORKTREE_SETUP_CMD` 행에 "운영 값이 섞인 env 파일은 통째로 복사하지 않는다"를 더했다. `orca.yaml` 단계에만 있던 조건이다.
- `tests/smoke.sh`:
  - 실제 git 저장소에 병합 커밋 넷(셋째가 테스트를 깨뜨림)을 쌓아 다음을 본다.
    - 창 저장·읽기·닫기.
    - 언제 돌리나: 창이 참, 스펙 끝, `--max`·번호 지정·자동 선택의 마지막, 다음 대상 미리 계산, 0이면 스펙 끝·실행의 마지막에만.
    - 묶음 통과·재실행 통과.
    - 이분 탐색: 다시 돌린 커밋이 시작·#12·#13뿐인지, 워크트리를 끝으로 되돌리는지, 시간, 창 밖 커밋, PR을 모르는 빈 칸, 시작에서도 실패, 포트, 재실행 명령 없음, 한 티켓 창.
    - 앞 검증의 탐색 결과가 섞이지 않는지.
    - 멈춤 사유, 수습 뒤 다시 검증, 루프 끝 검증과 그 실패(멈춤 기록에 싣는 PR·제목은 창의 마지막 병합).
    - 다음 대상 조회가 실패하면 미루는지.
    - 멈춤 기록의 창, 리포트, `run_ticket`·메인 연결, 값 검사(0 허용, `-1`·`04`·빈 값 거부), 기본값 4, 시작 줄의 주기 표시.
  - 기존 검사 하나(`skipped`는 병합 뒤에만)를 새 구조에 맞췄다.
  - 넣은 결함 스물일곱 개에서 각각 해당 검사가 실패하는 것을 확인했다. 넣은 결함은 다음과 같다.
    - 창: 시작을 안 잡음, 꼬리를 늘 붙임, 기본 브랜치에 없는 시작을 그대로 씀, 통과·재실행 통과 뒤 창을 안 닫음.
    - 언제 돌리나: 창이 차도 안 돌림(`-gt`), 처리한 티켓을 다음 대상으로 셈, 스펙 끝을 안 봄, 대상 조회 실패를 "남은 티켓 없음"으로 읽음.
    - 이분 탐색: 시작 커밋을 안 돌림, 경계 하나 어긋남, 워크트리를 안 되돌림, 다시 돌린 시간을 안 셈, 앞 검증의 결과가 남음, PR 빈 칸을 탭 `read`로 읽음.
    - 기본값·0: 기본값이 1, 0인데 개수로 돌림, 0인데 "2/0"으로 표시, 0을 거부, 시작 줄에 0의 뜻이 없음.
    - 그 밖: 사유에 묶음이 없음, 루프 끝 검증 없음(본 고리·티켓 없는 실행), 루프 끝 멈춤 기록에 앞 티켓의 PR이 남음, 문서 PR을 창에 넣음, 값 검사 없음, 리포트 꼬리말.
- README 두 벌, 가이드북 6장 변수 표, 7장 6·9단계, R10, 무거운 테스트 장, 부록 D 재생성, 부록 E 한 행. PDF 재빌드.
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.9 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. **설정하지 않으면 병합 4개마다 묶인다**(0.9.8까지는 병합마다). 검증이 짧은 저장소(pms-postgres처럼 1분)는 `.ticket-loop/loop.env`에 `POST_MERGE_EVERY="${POST_MERGE_EVERY:-1}"`을 더해 병합마다 돌린다. `POST_MERGE_RETRY_CMD`가 설치된 의존성에 기대면 설치 명령을 앞에 붙인다(rental-portal의 `scripts/post-merge-retry.sh`가 그렇다).

## 0.9.8 — 2026-10-21

스펙 리포트는 티켓마다 경과 시간 하나만 보여 줬다. rental-portal 스펙 #248(0.9.5, cmux)에서 티켓 하나는 1시간 20분~2시간이 걸렸다. 그중 병합 뒤 검증(통합 테스트)만 46~51분이었지만, 리포트로는 구현에 든 시간과 CI·통합 테스트를 기다린 시간을 나눠 볼 수 없었다. 기록에도 시간은 두 가지뿐이었다. 하나는 통과한 마지막 CI 회차(`ci_sec`)이고, 다른 하나는 병합 뒤 검증 결과 문자열("passed in 2831s")이다. 수리 시간과 실패한 CI 회차는 어디에도 없었다. 티켓당 에이전트 토큰도 리포트에 없었다.

고친 것:

- `phase`(새 함수), `run_ticket`·`repair_ci`·`run_post_merge`: 티켓 시간을 단계별로 센다.
  - 구현: 에이전트가 뜬 때부터 PR이 열린 때까지(GitHub 시각).
  - 수리: 충돌·CI 수리 프롬프트부터 수리 끝까지. 재실행만 한 수리 뒤 CI를 다시 기다리는 동안은 CI로 센다.
  - CI: 첫 회차는 PR이 열린 때부터 결과까지다. 루프가 PR을 알아채기 전에도 CI는 돌기 때문이다. 수리 뒤 회차는 루프가 다시 보기 시작한 때부터 센다.
  - 병합 뒤 검증: 명령이 돈 시간. 재실행과 수습 뒤 재검증을 포함하고, 포트 대기는 뺀다.

  워크트리 준비, PR을 알아채기, 병합·정리, 포트 대기, 무인 수습은 어느 단계에도 넣지 않는다. 지금 단계가 시작된 때보다 이른 시각으로 바꾸면 그 시각으로 당겨, 같은 시간을 두 단계에 넣지 않는다.
- `record_ticket`: 기록에 `impl_sec`·`repair_sec`·`ci_wait_sec`·`post_merge_sec`를 늘 남긴다. 멈춘 티켓은 열린 단계를 기록하는 시각에 닫는다. `ci_sec`는 그대로 통과한 마지막 회차의 GitHub 체크 시간이다.
- 스펙 리포트:
  - Implementation·CI·Post-merge check 열을 더했다. 구현 열에는 수리 몫을 "incl. repair …"로 적는다.
  - 경과 시간 아래 막대가 세 몫과 나머지(회색)를 보인다. 나머지가 1분 이상이면 "other …"라고 적는다. 머리에 세 시간의 합계 KPI를 붙였다.
  - 결과 브리프에서는 걸린 시간을 빼고 결과만 적는다("CI 7m"는 지우고, "post-merge check passed in 2831s"는 "post-merge check passed"로).
  - 0.9.7 이하 기록은 어림한다. 구현은 PR 생성 시각 − 시작으로 잡고 수리가 있었으면 "excl. repairs"를 붙인다. CI는 `ci_sec`이고 수리가 있었으면 "last run only"를 붙인다. 병합 뒤 검증은 결과 문자열의 초를 더한다. PR 없이 멈춘 기록은 경과 전부를 구현으로 본다.
  - 열이 늘어 페이지 최대 폭을 1360px로 넓혔다.
  - rental-portal #248의 실제 기록 12건(전부 0.9.5)으로 그려 보았다. 벽시계 합 20h 8m 가운데 구현 10h 18m, CI 31m, 병합 뒤 검증 8h 55m였다.
- 티켓 토큰:
  - `claude_project_dir`·`ticket_session_dirs`·`session_tokens`(새 함수): 워커와 그 티켓의 무인 수습 세션이 남긴 Claude Code 세션 기록(`~/.claude/projects/<작업 폴더>/`, 서브에이전트 `subagents/` 포함)에서 응답마다 남는 usage를 더한다. 한 응답이 내용 블록마다 줄로 나뉘어 같은 usage가 되풀이되므로 `message.id`로 한 번만 센다(rental-portal #250: 394줄 → 응답 210개). 티켓 시작 시각 앞의 응답(같은 경로를 쓴 앞선 시도)은 뺀다.
  - `record_ticket`: 기록에 `tokens`(`input`·`output`·`cache_write`·`cache_read`)를 남긴다. 작업 폴더는 `CUR_AGENT_PATHS`(워커·수습 세션)와 `WORKTREE_DIR`에서 찾는다. 세션 기록이 없거나 Codex 워커면 남기지 않는다(Codex는 세션 기록 형식이 달라 아직 세지 않는다).
  - `report_tokens`(새 함수)·`write_spec_report`: 기록에 `tokens`가 없는 티켓은 리포트를 그릴 때 그 기록의 시작~끝 시각으로 다시 센다. 기록 파일은 고치지 않는다. `WORKTREE_DIR`로 찾으므로 Orca로 돈 지난 티켓은 비고, Claude Code가 지운 세션 기록(기본 30일)도 비어 "—"로 나온다.
  - 리포트에 Tokens 열을 더했다. 첫 줄은 네 값의 합이고, 그 아래에 out·new in(캐시 밖 입력 + 캐시 쓰기)·cached를 적는다. 정확한 값은 title로 보인다. 머리에 토큰 합계(출력 토큰) KPI를 붙였다. 마친 시각은 날짜와 시각을 두 줄로 나눠 표 폭을 줄였다.
  - rental-portal #248의 0.9.5 기록 12건을 이 PC의 세션 기록으로 메웠다. 합 456.4M, 출력 2.0M이었다. 티켓당 12.1M~84.3M이고, 대부분 캐시 읽기다.
- `tests/smoke.sh`:
  - `phase` 단계 계산(PR 생성 시각으로 닫기, 이른 시각 당기기, 빈 단계).
  - 기록의 네 값과 열린 단계 닫기, `run_ticket`·`record_ticket`의 전환 자리.
  - `repair_ci`의 단계 순서.
  - 병합 뒤 검증 시간(재실행 더하기, 명령 전에 끝나면 0, 두 명령을 감싸는지).
  - 리포트의 열·막대·나머지·KPI 합계, 지난 기록 어림, 결과 브리프에 시간이 남지 않는지.
  - 토큰: 가짜 `CLAUDE_CONFIG_DIR`의 세션 기록으로 워커·서브에이전트·수습 세션 합, 같은 응답 중복, 시작 앞·끝 뒤 제외, 다른 티켓(`issue-70`, `loop-triage-70-…`) 제외, 깨진 줄, `WORKTREE_DIR` 밖 작업 폴더(Orca), 기록의 `tokens`(Codex·세션 기록 없음은 빠짐), 리포트 메우기(있는 값·Codex는 그대로), 리포트의 토큰 열·KPI.

  단계별 시간에 넣은 결함 열세 개와 토큰에 넣은 결함 열두 개에서, 각각 해당 검사가 실패하는 것을 확인했다.
- 가이드북 6장 `RECORDS_FILE` 행, 7장 7·9단계, 12장, 부록 D 재생성, 부록 E 한 행. PDF 재빌드.
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.8 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다. 끝난 스펙의 리포트는 `ticket-loop.sh --parent <N>`으로 다시 뽑으면 지난 기록은 어림한 값으로 채워진다. 토큰도 세션 기록이 남아 있으면(루프를 돌린 PC에서, 30일 안) 채워진다.

## 0.9.7 — 2026-10-21

멈췄다가 이어 간 스펙에서 회고 안내와 리포트가 끊긴 뒤의 실행만 반영했다. rental-portal 스펙 #248(0.9.5, cmux)에서 10/20에 시작한 실행이 #258(CI 수리 뒤 새 커밋 없음)에서 멈췄고, 사람이 PR #280을 병합한 뒤 10/21에 이어 갔다. 스펙 리포트의 행 자체는 하위 이슈 전체와 실행 간에 이어지는 `tickets.jsonl`에서 만들어 빠지지 않았다(재시작한 실행이 #187 한 건만 처리하고 만든 spec-141.html에도 16행이 다 있다). 문제는 두 곳이었다.

- 회고 안내(`suggest_retro`)가 이번 실행의 로그(`LOG_FILE`)만 적었다. 로그는 실행을 시작한 날짜의 파일(`loop-MMDD.log`)이라 #250~#258과 멈춘 경위는 `loop-1020.log`에 있는데, 안내는 `loop-1021.log`만 가리켰다 — 그대로 `/retro`에 넘기면 끊긴 지점부터만 읽는다
- 루프가 멈춘 뒤 루프 밖에서 병합된 티켓(#258)이 리포트에 멈춘 흔적 없이 `Merged`로 나왔다. 상태가 병합이면 중단 사유를 숨겼고, 경과·마친 시각은 멈춘 때까지였고, "post-merge check skipped"가 붙었다 — 병합 뒤 검증을 건너뛴 게 아니라 루프가 병합하지 않았다. 티켓 시작 때 `POST_MERGE_RESULT`를 "skipped"로 채워 두어, 병합 전에 멈춘 기록에 그 값이 남았다

고친 것:

- `record_ticket`: 기록에 그 티켓을 처리한 실행의 로그 파일(`log`, 저장소 루트 기준)을 남긴다
- `spec_logs`(새 함수)·`suggest_retro`: 끝난 스펙의 기록이 지나간 로그를 기록 순서대로 모두 적는다(`material to read: logs .ticket-loop/loop-1020.log, .ticket-loop/loop-1021.log, …`). `log`가 없는 0.9.6 이하 기록은 로그 디렉터리의 `loop-*.log`에서 그 티켓의 머리줄(`=== #N`)을 찾는다. 이번 실행의 로그는 늘 넣고, 지워진 로그와 다른 스펙의 로그는 뺀다. 로그가 하나면 전과 같은 `log …`. rental-portal 실제 기록으로 #248 → `loop-1020.log, loop-1021.log`, #141 → `loop-1017.log, loop-1018.log`를 확인했다
- 스펙 리포트: 마지막 기록이 `stopped`이고 PR 병합이 그보다 늦으면 `Merged after stop`(주의 배지)으로 그린다. 중단 사유를 보이고, 결과 요약에 "merged outside the loop 1h 43m after the stop", 경과 아래 "loop, until the stop", 마친 시각은 PR 병합 시각. 루프가 병합한 뒤 멈춘 티켓(병합이 먼저)은 전처럼 `Merged`지만 이제 중단 사유가 보인다. KPI의 병합 수에는 둘 다 센다. 꼬리말에 한 문장
- `POST_MERGE_RESULT`: 티켓 시작 때 비우고, 병합 뒤 검증을 하지 않기로 할 때만 "skipped". `run_post_merge`가 검증 명령 전에 끝나면(검증 워크트리 실패, 포트가 끝내 안 빔) "did not start" — 전에는 이것도 "skipped"였다. 리포트는 0.9.6 이하 기록의 멈춘 티켓에 남은 "skipped"를 그리지 않는다
- `tests/smoke.sh`: 이어 간 스펙의 회고 안내(기록의 `log`, `log` 없는 기록의 머리줄 찾기, 지워진 로그·다른 스펙 제외, 깨진 줄 건너뛰기, 이번 실행 로그, 로그 끔), 기록의 `log`와 병합 전 `post_merge` 없음, 검증 명령 전에 끝난 `did not start`, `POST_MERGE_RESULT` 초기값, 리포트의 멈춘 뒤 병합(배지·사유·걸린 시간·경과 표시·마친 시각·skipped 안 그림)과 병합 뒤 멈춤(`Merged` + 사유). 넣은 결함 열 개(기록을 안 읽음 — 0.9.6, 머리줄 찾기 없음, 지워진 로그를 안 뺌, 기록에 `log` 없음, 시작 때 skipped — 0.9.6, did not start 없음, 멈춘 뒤 병합을 `Merged`로 — 0.9.6, 병합된 행의 사유 숨김 — 0.9.6, 마친 시각이 멈춘 시각, 멈춘 기록의 skipped를 그림)에서 각각 해당 검사가 실패하는 것을 확인했다
- 가이드북 6장 `RECORDS_FILE` 행, 7장 7·8·9단계, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.7 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다. 끝난 스펙의 리포트는 `ticket-loop.sh --parent <N>`으로 다시 뽑으면 새 표시로 그려진다

## 0.9.6 — 2026-10-21

루프가 시작할 때 키트 이름과 버전을 보여 주지 않았다. 로그는 날짜별 한 파일(`loop-MMDD.log`)에 실행이 이어 붙는데, 어디서 새 실행이 시작하는지도, 그 실행을 어느 키트 버전이 돌렸는지도 줄에 없었다. 0.9.1~0.9.5처럼 루프 버그를 고친 릴리스가 잇따른 뒤로는 `/retro`나 멈춤 진단에서 "고치기 전 버전이 낸 줄인가"를 가를 수 있어야 한다. 버전은 멈춤 기록(`kit` 필드)에만 남아 있었다.

- `ticket-loop.sh` `kit_banner`: 메인의 첫 출력으로 `━━ ticket-loop-kit 0.9.6 (435e70e) ━━…` 한 줄을 찍는다(앞에 빈 줄, 56칸 고정 — 좁은 워커 창에서도 접히지 않게). 터미널에서는 굵은 256색 주황(`C_BANNER`, 208)이다 — 16색에는 주황이 없고, 기존 단계 색(티켓 제목 자주·단계 청록·성공 초록·주의 노랑·오류 빨강) 어느 것과도 겹치지 않는다. 테마 팔레트가 아니라 고정 색이라 테마가 바뀌어도 같은 주황이다. `NO_COLOR`·파이프·로그 파일에서는 맨글자다. `backend_check`보다 앞이라 백엔드 점검에서 바로 멈춰도 버전이 남는다. `--dry-run`에도 찍는다
- `kit_version`: 버전·커밋을 설치기가 쓴 `.ticket-loop/kit.json`에서 읽는다(멈춤 기록과 같은 출처). 없거나 못 읽으면 `unknown`, 커밋이 없으면 버전만
- Slack 시작 알림 본문 끝에 `· kit 0.9.6 (435e70e)`
- npx 설치기(`bin/ticket-loop-kit.js`): 첫 줄을 같은 머리줄로 바꿨다(같은 모양·색, 루프의 `kit_banner`와 글자까지 같다). 저장소 경로는 다음 줄 `▸ Repository: …`로 옮겼다. `install.sh`의 `▸ ticket-loop-kit … → …` 줄은 그대로 둔다 — npx 설치기가 install.sh를 부르므로 머리줄로 바꾸면 npx 경로에서 두 번 찍힌다
- `tests/smoke.sh`: 머리줄 모양(색 없음·폭을 넘는 긴 이름·`C_BANNER`로 감싸기), `C_BANNER`가 256색 208인지, `kit_version` 다섯 경우(버전·커밋, 커밋 없음, 깨진 JSON, 파일 없음, install.sh가 쓴 실제 kit.json), 메인에서 `backend_check` 앞인지, Slack 시작 알림의 버전, npx 설치기 첫 줄이 `kit_banner`와 같은지. 넣은 결함 여섯 개(보라로 바꿈, `backend_check` 뒤로 옮김, 커밋을 빼먹음, Slack에서 버전 뺌, npx 폭이 다름, 긴 이름에서 꼬리 ━ 없음)에서 각각 해당 검사가 실패하는 것을 확인했다
- 가이드북 6장 `LOG_FILE`·`SLACK_WEBHOOK_URL` 행, 9장 점검 출력 예, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.6 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다

## 0.9.5 — 2026-10-21

CI 수리가 코드 변경 없이 녹색이 됐는데 루프가 "no new commit was pushed after the repair"로 멈췄다(이슈 #9, 0.9.2 설치본, cmux, rental-portal #258 → PR #280). CI 실패의 원인은 코드가 아니라 러너 인프라였다 — 같은 HOME을 나눠 쓰는 self-hosted 러너 둘이 `pnpm/action-setup`의 `~/setup-pnpm`을 동시에 지우고 설치했고(`ENOTEMPTY`·`ENOENT`), 같은 커밋의 세 번째 job은 통과했다. 워커는 올바르게 `gh run rerun <id> --failed`만 했고 재실행은 1분 뒤 통과했다. 이번 멈춤은 수리 요청 2초 뒤였는데, 그쪽은 0.9.3이 고친 묵은 idle이다. 이 이슈는 그 뒤에도 남는 판정 문제다. 같은 실행에서 #251이 무인 수습을 먼저 써서(`TRIAGE_MAX=1`) 수습도 뜨지 않았다.

- 원인: CI 수리 결과를 PR head 비교만으로 갈랐다. 재실행형 수리는 push할 커밋이 없으니, 0.9.3 이후로도 `repair`가 새 커밋 없는 idle을 세 번 본 뒤(약 1분) 똑같이 멈춘다. 무인 수습이 남아 있으면 `loop-triage` 스킬의 "인프라 장애면 `gh run rerun --failed`만 하고 `resume`"이 살려 주지만, 그건 워커가 이미 한 일을 한 번 더 하는 것이다
- `ticket-loop.sh` `repair_ci`: CI 수리를 함수로 뺐다. 수리 뒤 head가 그대로면 바로 멈추지 않고 "no new commit after the repair — checking CI again (a re-run needs no commit)" 한 줄을 남긴 뒤 `ci_passed`로 CI를 한 번 더 본다(0.9.4의 `--json bucket` 재확인 포함, 재실행이 도는 중이면 끝까지 본다). 통과면 충돌·CI 확인부터 다시 돌아 병합으로 간다(다음 바퀴의 `ci_passed`가 통과를 확정하고 CI 소요도 거기서 잰다). 새 커밋도 없고 CI도 그대로 실패일 때만 멈춘다 — 사유는 "no new commit was pushed after the repair, and CI still fails", 멈춤 종류는 전처럼 `ci_failed`(무인 수습 대상). 재실행만 한 수리도 수리 횟수 1로 센다
- 수리 프롬프트에 한 줄: "같은 커밋의 다른 job은 통과했고 실패가 러너·네트워크 오류처럼 코드와 무관하면 코드를 바꾸지 말고 `gh run rerun <run-id> --failed` 로 실패한 job만 다시 돌려라(push할 커밋이 없어도 된다)". 프롬프트가 "같은 브랜치에 push해라"로 끝나 워커가 CI를 통과시키려고 불필요한 커밋(테스트 시간 한도 올리기 같은)을 만들 수 있었다
- 이슈의 선택 항목 3(`repair`가 체크 재실행 시작도 진행으로 보기)은 넣지 않았다. 새 커밋 없는 idle을 세 번 보는 약 1분은 GitHub에서 재실행이 도는 시간과 겹친다 — 재실행이 1분보다 길면(이번 #258이 약 1분) 줄어드는 시간이 거의 없고, 그 사이 판정만 하나 더 생긴다
- `tests/smoke.sh`: `repair_ci` 네 경우(새 커밋 → CI를 다시 보지 않고 0, 새 커밋 없음 + CI 통과 → 0과 경고 한 줄, 새 커밋 없음 + CI 실패 → 1, 수리 제한 시간 → 멈춤), 호출부가 `repair_ci`의 1에서만 멈추고 `run_ticket`에 head 비교가 남지 않았는지, 프롬프트의 재실행 안내. 넣은 결함 다섯 개(head가 그대로면 CI를 보지 않고 멈춤 — 0.9.4, 새 커밋이 있어도 CI를 봄, CI 결과를 무시, 프롬프트 줄 없음, 호출부가 head 비교로 멈춤)에서 각각 해당 검사가 실패하는 것을 확인했다
- 가이드북 6장 내부 상수(`IDLE_STRIKES`), 7장 4단계, 10.6 표 한 칸, 부록 D 재생성, 부록 E 한 행. README 두 벌의 수습 표 한 칸. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.5 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다

## 0.9.4 — 2026-10-21

CI가 통과한 티켓 PR을 병합하는 순간 GitHub API가 `502 Bad Gateway`를 한 번 돌려줬고, 루프가 그 자리에서 멈췄다(이슈 #7, 0.9.2, cmux). 앞뒤의 `gh` 호출은 모두 정상이었고 PR은 충돌 없이 병합 가능한 채로 열려 있었다 — GitHub 상태 페이지에 공지가 없는 짧은 502였다. 멈춤 종류가 `other`라 무인 수습도 뜨지 않아, 사람이 직접 병합하고 워커 워크트리를 지운 뒤 다시 실행했다.

- 원인: 병합 호출 `gh pr merge … || die`에 재시도가 없었다. 루프의 다른 `gh` 호출을 훑어보니 같은 부류가 더 있었다. 하나는 `set -e`로 멈추는 곳이다(병합 뒤 브랜치 이름 조회, CI 수리 전 PR head 조회). 다른 하나는 멈추지 않고 틀린 값으로 읽는 곳이다. 대상 고르기는 명령 치환 안이라 실패가 빈 목록이 되어 "No more tickets"로 끝날 수 있었고, `gh pr checks --watch`는 API 오류 한 번에도 체크 실패와 같은 1로 끝나 워커에게 할 일 없는 수리를 보낼 수 있었다
- `ticket-loop.sh` `gh` 함수: 루프 안의 `gh`를 감싸, 조회 호출(`pr view|list|diff`, `--watch` 없는 `pr checks`, `issue view|list`, `repo view`, 메서드·필드 없는 REST `api`, mutation이 아닌 GraphQL)이 GitHub 일시 장애(`GH_TRANSIENT_RE` — `status code: 5xx`·`HTTP 5xx`, bad gateway·service unavailable·timeout, "Something went wrong while executing your query", 연결 오류)로 실패하면 `GH_RETRY_SEC`×회차(15초·30초) 쉬고 `GH_TRIES`(3)번까지 다시 한다. 출력·종료 코드·stderr는 그대로 넘긴다. 쓰기(코멘트·라벨·이슈 닫기·병합)는 다시 하지 않는다 — 응답만 실패하고 서버는 처리했을 수 있어 두 번 들어간다. 도구 검사(`command -v gh`) 뒤에 정의한다(먼저 있으면 gh가 없어도 검사를 통과한다)
- `merge_pr`: 병합이 실패하면 먼저 `gh pr view --json state`로 이미 병합됐는지 본다(서버는 병합을 끝냈는데 응답만 502였을 수 있다 — 그대로 다시 부르면 "already merged"로 또 실패한다). 병합됐으면 성공이다. 아니면 일시 장애와 "Base branch was modified"일 때만 같은 간격으로 세 번까지 다시 한다. 그 밖의 거절(필수 리뷰 같은 브랜치 보호, 권한)은 전처럼 바로 멈춘다 — 가이드북 12장이 병합 전에 사람이 보는 방법으로 권하는 자리다. 수습 세션의 수정 PR 병합(`triage_merge_fix_pr`)도 이 함수를 쓴다
- 병합이 끝내 실패하면 멈춤 종류를 `merge_failed`로 남기고(전에는 `other`) 사유에 마지막 `gh` 오류 첫 줄과 "gh pr view N을 보고 병합 가능하면 병합한 뒤 다시 실행" 안내를 싣는다. 무인 수습 대상으로는 넣지 않았다(이슈의 선택 항목 3) — 일시 장애는 재시도가 받고, 남는 거절은 사람에게 넘기려고 켜 둔 것이라 수습 세션이 할 일이 없다. `loop-triage` 스킬의 사람 모드에 `merge_failed`를 가르는 법(`state`·`mergeStateStatus`: `MERGED`·`CLEAN`·`BLOCKED`·`BEHIND`·`DIRTY`)을 더했다
- `ci_passed`: `--watch`가 실패로 끝나면 체크 상태(`gh pr checks --json bucket`)를 다시 읽어 실패·취소한 체크가 있을 때만 실패다. 다 통과했으면 통과("CI watch failed but every check passed"), 아직 도는 체크가 있으면 `GH_TRIES`번까지 다시 본다. 못 읽으면 전처럼 실패
- 병합 뒤 브랜치 이름 조회가 실패해도 멈추지 않는다(티켓은 이미 병합됐다). 경고 한 줄을 남기고 브랜치 삭제만 건너뛴다
- `tests/smoke.sh`: `merge_pr` 여덟 경우(한 번에 병합·`--squash` 전달, 502 한 번 뒤 병합, 502가 이어지면 세 번 뒤 실패와 `MERGE_ERR`, 502지만 이미 병합됨, 다시 해 보니 "already merged", REST 503·DNS 오류, "Base branch was modified", 브랜치 보호 거절은 한 번에 실패). `gh` 함수 열세 경우(조회·GET api·GraphQL 조회는 다시 하고, 계속 실패하면 세 번 뒤 오류, 종료 코드 8·출력 그대로, 일시 장애가 아닌 오류·코멘트·병합·이슈 닫기·`--watch`·필드 있는 api·`-X PATCH`·mutation은 한 번)와 도구 검사보다 뒤에 정의됐는지. `ci_passed` 일곱 경우(통과, 실패·취소, watch는 1이지만 다 통과, 도는 체크면 다시 봄, 세 번 뒤 끝, 못 읽음). 티켓 PR·수정 PR 병합이 `merge_pr`를 거치는지, 멈춤 종류, 병합 뒤 브랜치 조회. 넣은 결함 일곱 개(병합 재시도 없음, 병합 여부 확인 없음, 일시 장애를 가리지 않고 병합 재시도, 조회 재시도 없음, 쓰기까지 재시도, `--watch` 결과를 다시 읽지 않음, 도는 체크를 통과로 봄)에서 각각 해당 검사가 실패하는 것을 확인했다. 감싼 `gh`를 실제 `gh` 2.97로 불러 조회 출력·GraphQL·`--json bucket --jq`·not found 오류(다시 하지 않음, 종료 코드 1)를 확인했다
- 가이드북 6장 내부 상수, 7장 4·5단계, 10.2, 10.6, R3, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.4 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다

## 0.9.3 — 2026-10-21

CI 수리 요청 5초 만에 루프가 "수리 뒤 새 커밋 없음"으로 멈췄다. rental-portal #251(0.9.2, cmux, 2026-10-20)에서 PR #269의 CI가 실패해 루프가 워커에게 수리를 보냈는데(23:44:21), 다음 줄이 "no new commit was pushed after the repair"(23:44:26)였다. 워커는 그 뒤에도 수리를 계속해 2분 뒤 커밋을 push했고, 그사이 뜬 수습 세션과 같은 PR 브랜치에 함께 push했다(수습 세션이 알아채 워커의 30초 한도 커밋을 되돌렸다). 수습 세션이 멈춤 기록 옆에 키트 버그 보고(`.kit-bug.md`)를 남겼다. rental-portal 로그에서 수리가 돈 것은 이번이 처음이다 — cmux 백엔드가 생긴 뒤로 숨어 있던 버그다.

- 원인: `cmux_send`는 `paste --submit`만 하고 돌아왔다(백엔드 계약은 "수락되지 않으면 비0" — Orca는 `--wait-submit`, tmux는 `sent`→running을 본다). 붙여 넣은 직후의 `lifecycle`은 cmux가 새 턴을 알기 전이라 직전 턴의 `idle`이고, `repair`가 바로 부른 `cmux_wait_idle`이 그 묵은 `idle`을 첫 폴링에서 받아 수리 끝으로 돌려줬다. 호출부는 PR head가 그대로라 멈췄다
- `ticket-loop.sh` `cmux_send`: 붙여 넣은 뒤 `SEND_ACCEPT_SEC`(15초) 동안 0.5초마다 `lifecycle`을 본다. `idle`·`needsInput`에서 벗어나면 수락이다(빈 값·`unknown`도 넘어간다 — `cmux_wait_idle`이 그 값을 idle로 읽지 않는다). 끝까지 `idle`이면 화면으로 가른다 — 붙여 넣기 전과 화면이 달라졌으면(프롬프트가 찍힘) 수락, 그대로면 비0이고 루프는 "Prompt was not accepted"로 멈춘다. 다시 보내지는 않는다 — 실제로는 들어갔는데 훅 보고만 늦은 경우 같은 지시가 두 번 들어간다. tmux의 15초도 같은 상수로 바꿨다
- `repair`: idle인데 PR에 새 커밋이 아직 없으면 바로 끝내지 않는다. 화면이 그대로인 idle을 `IDLE_STRIKES`(3)번 연달아(그 사이 `IDLE_RECHECK_SEC` 30초) 볼 때만 끝이고 호출부가 "새 커밋 없음"으로 멈춘다. 그 전에 커밋이 들어오면 끝, 화면이 바뀌거나 워커가 다시 일하면 처음부터 센다(`wait_for_pr`와 같은 규칙). 각 idle은 "worker idle after the repair prompt, no new commit on PR #N yet (k/3)"로 남는다. 위 묵은 idle이 남아도, 백그라운드 서브에이전트를 기다리는 동안의 idle(2.5절 `Stop` 훅)이어도 수리 끝으로 읽지 않는다. 정말 push 없이 멈춘 워커는 전보다 약 1분 늦게 멈춘다
- `tests/smoke.sh`: 가짜 cmux에 차례대로 바뀌는 `lifecycle`(`FAKE_LC_FILE`)·화면 파일·`paste`를 더해 `cmux_send` 다섯 경우(idle→running에서 수락하고 더 읽지 않음, 끝까지 idle·화면 그대로면 비0, 프롬프트가 화면에 찍히면 0, 빈 값이면 0, `paste` 거부면 비0). `repair` 세 경우를 더했다(idle이고 새 커밋 있음 → 바로 끝, 새 커밋 없는 idle 세 번 → 끝·경고 셋, 묵은 idle 뒤 커밋 → 끝·경고 하나, 화면이 바뀌면 처음부터 셈). 수락 확인을 뺀 사본, 화면 대체 신호를 뺀 사본, `repair`가 첫 idle에서 끝내는 사본(0.9.2), 화면이 바뀌어도 세는 사본에서 각각 실패하는 것을 확인했다
- 가이드북 2.5절 비교 표·주의(묵은 lifecycle, 실측 줄), 6장 내부 상수(`SEND_ACCEPT_SEC`, `IDLE_STRIKES`), 7장 4단계, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.3 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다

## 0.9.2 — 2026-10-18

PR을 찾은 뒤 루프가 10분을 놀았다(이슈 #2). rental-portal 스펙 #141(0.9.1, cmux, 13티켓)에서 #145·#152·#179가 "PR #N opened"를 PR 생성 636~656초 뒤에 찍었다. `wait_for_pr`가 PR을 찾은 뒤 "라벨·체크박스 정리까지 끝나도록" idle을 `IDLE_WAIT_MS`(10분)까지 한 번 더 기다리는데, cmux lifecycle이 빈 값으로 이어져(그날 로그에 `empty lifecycle` 126줄, 거의 모든 티켓) idle이 끝내 잡히지 않았다. CI는 그사이 끝나 있어 요약·기록·스펙 리포트에 2~3초로 찍혔다. CI 끝에서 루프가 알아채기까지 실제로 늦은 시간은 6분 26초·6분 28초·5분 12초(합 약 18분)다. 세 건 모두 `in-review` 라벨은 PR 생성 8~12초 뒤에 붙어 있었다(이슈 타임라인).

- `ticket-loop.sh` `pr_settle`: PR을 찾은 뒤 이슈에 `IN_REVIEW_LABEL`이 붙었거나(implement 스킬의 마지막 단계) 워커가 idle이면 바로, 아니면 `PR_SETTLE_SEC`(120초)에서 한 줄 남기고 넘어간다. 10초마다 라벨을 본다. 기다림 자체는 남겼다 — CI 경로 필터로 체크 없이 바로 병합하는 PR은 워커보다 먼저 병합·이슈 닫힘·라벨 제거가 일어난다. `IN_REVIEW_LABEL`을 바꾼 저장소는 implement 스킬의 라벨 이름도 같이 바꿔야 라벨로 끝난다(아니면 상한까지)
- CI 소요(`ci_run_sec`)는 PR head 체크들의 GitHub 시각 — 가장 이른 `startedAt`부터 가장 늦은 `completedAt`까지(시작 전 `0001-…`은 뺀다). 못 읽으면 전처럼 루프가 기다린 시간
- PR을 알아채기까지: "PR #N opened (created HH:MM:SS, picked up after Ns)", 요약 줄 "PR #N (picked up after Ns)", 기록 `pr_pickup_sec`. PR 생성부터 루프가 충돌·CI 확인으로 넘어가기까지다 — 이번 지연을 손으로 대조하지 않아도 보이게
- idle 오판(`idle_false_positives`)의 뜻을 바로잡았다: 일하던 워커를 idle로 본 횟수. 0.9.1까지는 "idle 뒤 다시 보니 PR이 열려 있음"을 다 셌는데, 대개 PR을 연 뒤 idle에 든 일을 마친 워커였다(폴링 순서의 부산물). 이제 PR이 idle보다 늦게 열렸을 때만 세고, PR 없이 센 "worker idle, no PR (k/3)" 뒤에 워커가 다시 일했으면(화면이 바뀜·idle이 풀림·PR을 엶) 그 idle들을 센다. idle 세 번으로 멈추면 그 연속 idle은 세지 않는다. 0.9.1까지의 기록에 남은 값은 다른 것을 센 값이다. 스펙 리포트는 이 필드를 쓰지 않는다
- 수리 끝 알아채기(`repair`): idle만 보던 것에 대체 신호를 더했다 — 수리 프롬프트 뒤 새 커밋이 push됐고 head가 `REPAIR_SETTLE_SEC`(300초) 그대로이며 워크트리에 커밋 안 된 변경이 없으면 끝난 것으로 본다. cmux lifecycle이 계속 비면 수리를 마쳐도 티켓 제한 시간(4시간)까지 기다린 뒤 "timed out while repairing"으로 멈출 자리였다(이번 스펙은 수리 0회라 드러나지 않았다)
- `tests/smoke.sh`: 진짜 `wait_for_pr`로 오판 여덟 경우(PR이 idle보다 먼저·나중·시각 모름, 오판 뒤 멈춤, 연속 idle로 멈춤, idle 뒤 PR, 화면이 바뀜, idle이 풀림), `pr_settle` 네 경우(라벨·idle·터미널 끊김·상한), `ci_run_sec`(PR #162의 실제 체크 시각 → 246초, gh 비0 종료, 시작 전 체크·소수 초, 못 읽음), `repair` 네 경우(새 커밋·커밋 없음·더러운 워크트리·idle), 기록의 `pr_pickup_sec`. 시각 비교를 뺀 사본, 라벨 확인을 뺀 사본, 대체 신호를 뺀 사본, 화면이 바뀔 때 세지 않는 사본에서 각각 실패하는 것을 확인했다
- 가이드북 6장 내부 상수 두 행, 7장 2·4·7단계, 9장 예시 로그, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.2 init`(또는 `install.sh`) 뒤 그 PR을 병합한다. 설정은 없다

## 0.9.1 — 2026-10-17

0.9.0 무인 수습을 실제 에이전트로 돌린 첫 실측에서, 준비 실패의 수정 PR이 병합되며 아직 구현 전인 티켓 이슈를 닫았다. 수습 세션은 스킬이 적어 둔 형식대로 수정 PR 제목을 `fix: #17 워크트리 준비 — …`로 붙였고, GitHub는 기본 브랜치에 들어온 커밋 메시지의 닫기 키워드(병합 커밋 본문에 PR 제목이 들어간다)로 #17을 닫았다(병합 2초 뒤). 워커가 알아채 다시 열고 구현을 계속했지만, 워커가 "이미 닫힌 이슈"로 보고 멈췄다면 PR 없이 멈춘 워커로 끝났을 것이다. 병합 뒤 검증 실패에서는 같은 꼴의 제목이어도 이슈가 이미 닫혀 있어 드러나지 않는다.

- `loop-triage` 스킬: 수정 PR 제목을 `fix: <요약> — #N 병합 뒤 검증`·`fix: <요약> — #N 워크트리 준비`로 바꾸고, 5절에 "제목·본문·커밋 메시지에서 닫기 키워드(close·fix·resolve와 변형, 콜론이 끼어도) 바로 뒤에 `#N`을 두지 않는다 — `Refs #N`으로 가리킨다"를 더했다. 7절에 루프의 다시 열기 한 줄
- `ticket-loop.sh`: 병합 뒤 검증 실패가 아닌 수습에서 수정 PR을 병합한 뒤 `triage_keep_issue_open`이 티켓 이슈를 `REOPEN_WATCH_SEC`(2초) 간격으로 다섯 번 보고, 닫혔으면 코멘트("수정 PR #M의 병합 커밋이 이 이슈를 닫아 다시 연다")와 함께 다시 연다. 스킬이 제목을 막아도 커밋 메시지까지 다 막는다는 보장이 없어서다. 병합 뒤 검증 실패는 그 티켓이 이미 병합돼 닫혀 있는 게 맞으므로 보지 않는다
- `tests/smoke.sh`: 가짜 `gh`의 `issue view`(`ISSUE_STATE`). 준비 실패 + 수정 PR + 닫힌 이슈면 호출 순서 `… pr merge,issue view,issue reopen,issue comment`·다시 열기 인자·로그 줄, 열린 이슈면 다섯 번 보고 다시 열지 않음, 병합 뒤 검증 실패는 보지 않음(기존 1번 케이스의 호출 순서). 다시 열기 호출을 뺀 사본과 종류를 가리지 않고 부르는 사본에서 각각 실패하는 것을 확인했다
- 0.9.0 실측(iwishash/ticket-loop-dummy, tmux 3.8, Claude Code Opus 5.5, 2026-10-17). 설치 PR #5에 무거운 테스트 자리(`tests/integration/`, CI 밖)와 `POST_MERGE_CMD="bash tests/integration/run.sh"`. 실패는 모두 티켓이 도는 사이 사람 역할로 병합한 다른 PR이 만들었다 — 각자는 CI를 통과하는 두 PR이 합쳐져 깨지는 꼴:
  - 실패 유도가 두 번 빗나갔다. #6 → PR #7(4분): 워커가 계약 테스트의 머리 주석("명령을 더하거나 빼면 기대 목록도 맞춘다")을 읽고 기대 목록까지 맞췄다. #9 → PR #10(4분): 워크트리 생성 7초 뒤 병합한 PR #8이 워커 브랜치에 들어 있었다 — 워커는 워크트리 생성 1분쯤 뒤 `git fetch origin && git checkout -b … origin/main`으로 가른다. 워커 브랜치가 생긴 뒤, 또는 PR이 열린 직후(열림→병합 약 6초, →병합 뒤 검증의 fetch 약 18초)에 병합해야 워커가 못 본다
  - 병합 뒤 검증 실패: #12(yo.sh 추가) → PR #13. PR이 열린 직후 PR #11(모든 명령에 `--help` + `test_help.sh`)을 병합 → `bin/yo.sh --help`가 `Yo, --help!` → 수습 세션이 1분 30초 만에 `resume (project)`, 수정 PR #14(+5줄, 원인을 두 PR의 병합 시각까지 짚음) → 라벨·CI·병합 → `post-merge-12-after-triage.log` 통과 → 이어 감, 벽시계 6분. 멈춤 기록의 `loop_from_byte`가 이 실행의 첫 줄을 가리키는 것, 판정 파일, 기록의 `triage`, 요약 줄, 이슈 "무인 수습 — 이어 감" 코멘트(`~` 경로, `loop-stopped` 없음), 수습 워크트리·원격 브랜치·tmux 정리를 확인했다
  - 워크트리 준비 실패: PR #15(준비 스크립트 `scripts/setup-worktree.sh` — `config/env.example`을 `.env`로) 뒤 PR #16(예시 파일을 `.env.example`로 옮기고 스크립트는 그대로) → #17 준비 실패 → 수습 세션의 워크트리도 같은 실패로 "starting the session anyway" → `resume (project)`, 수정 PR #18 → 병합, 메인 체크아웃 fast-forward, 워커 워크트리를 당겨 준비 통과 → PR #19, 벽시계 7분. 위 버그가 여기서 나왔다
  - 수리를 다 쓴 CI 실패(`REPAIR_ROUNDS=0`으로 워커 수리를 건너뜀): #21 워커가 브랜치를 가른 직후 PR #20(모든 명령에 `--version` + CI에서 도는 `tests/test_version.sh`) 병합 → PR #22의 CI(기본 브랜치와 합친 커밋)가 `bin/salut.sh`에서 실패 → 수습 세션이 티켓 브랜치를 PR 끝으로 맞추고 `origin/main`을 병합한 뒤 고쳐 push, PR에 원인·수정·검증 코멘트, `pushed_to_pr: true` → 루프가 PR의 충돌·CI 확인부터 이어 가 병합, 벽시계 6분. 이슈는 티켓 PR 병합으로만 닫혔다
  - PR 없이 멈춘 워커: 운영 DB 값을 요구하는 #23 → 워커가 규칙("운영 환경에는 어떤 경우에도 연결하지 않는다")대로 이슈에 코멘트를 남기고 멈춤 → idle 3번 → 수습 세션이 1분 만에 `halt (needs-human)`(무엇을 사람이 해야 하는지까지) → `die`: ERROR 줄과 기록 `stopped`의 사유 끝에 판정 요약, 이슈에 멈춤 코멘트(`/loop-triage 20261017-024237-23` 안내)와 `loop-stopped`, 워커·수습 워크트리와 tmux 창은 남김(`needs-attention`), 멈춤 기록은 다시 쓰지 않음. `die` 멈춤 보고가 실제 실행에서 처음 돌았다
  - 사람 모드: 더미 저장소 메인 체크아웃에서 `claude -p "/loop-triage 20261017-024237-23"`(읽기 도구만 허용) — id로 기록을 찾고, 같은 id의 판정 파일을 읽어 그대로 두고(무인 판정이 맞다고 다시 확인), 워커 워크트리 내용을 직접 본 뒤 8절대로 사람이 할 일·워크트리 정리 명령·다시 실행할 명령을 안내하고 정리는 물었다
  - 루프 실행 여섯 번(수습 네 번 포함) 모두 Slack·GitHub 전송 실패 경고 없음. idle 오판 수는 #6·#9·#17·#21에서 1, #12에서 0(그 티켓의 "worker idle (1/3)"은 오판이 아니라 연속 idle 횟수다)
- README 두 벌의 검증 상태(수습 실측 표, `POST_MERGE_CMD`·`die` 확인), 버전 고정 `#v0.9.1`. 가이드북 10.6 표 한 칸, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.1 init`(또는 `install.sh`) 뒤 그 PR을 병합한다(수습 세션은 기본 브랜치의 스킬을 쓴다). 설정은 없다

## 0.9.0 — 2026-10-17

멈춘 루프를 사람이 알아채고 붙기까지가 고치는 시간보다 길었다. 2026-10-16 rental-portal spec #96에서 #108의 병합 뒤 검증이 15:43에 실패해(재실행도 실패) 루프가 멈췄다. Slack 알림은 켜져 있었지만, 고친 PR #131(통합 테스트의 계약 CSV 헤더 기대값에 건강정보 동의 열 2개 — +3줄)이 올라온 건 19:01, 루프가 다시 돈 건 19:08이었다. 사용자 결정: 루프가 멈출 자리에서 먼저 고쳐 보게 하고, 이것을 기본으로 둔다(사람이 부르는 경로는 무인 수습이 미치지 못하는 곳의 비상구).

- `ticket-loop.sh` 무인 수습(`LOOP_TRIAGE`, 기본 1): 네 자리에서 바로 `die`하지 않고 `triage`를 부른다 — 병합 뒤 검증 실패(`post_merge_failed`), 수리를 다 쓴 CI 실패·충돌과 수리 뒤 새 커밋 없음(`ci_failed`), `WORKTREE_SETUP_CMD` 실패(`setup_failed`), PR 없이 멈춘 워커(`worker_no_pr`, 진단만). 멈춤 기록을 쓰고, 워커와 같은 길(`backend_worktree_create`)로 새 워크트리 `loop-triage-N-<시각>`에 에이전트를 띄워 `/loop-triage <기록>`을 보내고, 잠금을 쥔 채 판정 파일(`<id>.verdict.json` — `resume`|`halt`, 분류, 요약, `fix_pr`, `pushed_to_pr`, `kit_bug_report`)을 기다린다(`wait_for_verdict` — `wait_for_pr`와 같은 틀: idle 연속 3번이면 판정 없음, `TRIAGE_TIMEOUT_SEC` 기본 3600). 백엔드 함수의 `die`가 원래 멈춤 사유를 덮지 않도록, 세션 띄우기는 `bg_wait`로 백그라운드 서브셸에서 `die`를 바꿔 돌린다
- `resume`이면 멈춘 자리에서 이어 간다(처음부터 다시 실행하면 PR이 열렸거나 담당자가 붙은 진행 중 티켓을 자동 선택이 건너뛴다). 수정 PR은 기본 브랜치로 가는 열린 PR인지 보고 `TRIAGE_LABEL`(기본 `loop-triage`)을 붙여 CI 뒤 병합한다. 병합 뒤 검증 실패는 병합된 기본 브랜치로 검증을 다시 돌려(`post-merge-N-after-triage.log` — 앞 로그를 덮지 않는다) 통과해야 이어 가고, 결과는 `failed on retry …; after triage (fix PR #131): passed in Ns`로 요약·기록에 남는다. CI 실패는 수습 세션이 티켓 PR 브랜치에 push하면 그 PR의 충돌·CI 확인부터 다시 한다. 준비 실패는 워커 워크트리를 기본 브랜치로 fast-forward하고, 메인 체크아웃이 기본 브랜치에 있으면 그것도 fast-forward한 뒤 준비를 다시 돌린다(`WORKTREE_SETUP_CMD`가 메인 체크아웃의 스크립트를 부르는 저장소가 있다. git은 로컬 변경을 덮는 merge를 거부한다). 이슈에 "무인 수습 — 이어 감" 코멘트(멈춘 이유의 홈 경로는 `~`로), Slack `:recycle:`(멘션 없음)
- `halt`, 판정 없음, 수정 PR의 CI 실패·병합 실패·기본 브랜치가 아닌 PR, 이어 간 뒤 같은 곳에서 또 실패하면 판정 요약(`— triage (분류): 요약`, 루프 버그면 키트 버그 보고서 경로)을 사유에 붙여 멈춘다. 수습 워크트리는 남긴다. 한 실행에 `TRIAGE_MAX`(기본 1)번, 같은 멈춤(종류·이슈)에는 한 번. 기본 브랜치에 `loop-triage` 스킬이 아직 없으면(설치 PR 병합 전) 띄우지 않고 시작 줄에 적는다. 수습을 시작할 때 Slack `:hammer_and_wrench:` "Ticket loop stopped — triage started"(멘션 없음, 로그 끝)
- 수습하지 않는 멈춤: 티켓 타임아웃, 터미널 끊김, 에이전트 기동 실패, 병합 실패, 신호, `set -e` — 어디서든 안전하게 이어 갈 수 있는 자리가 아니다. 처음 제안은 "루프가 같은 인자로 자기 자신을 다시 실행"이었는데, 진행 중 티켓을 버리게 돼 멈춘 자리에서 이어 가는 쪽으로 바꿨다. 루프 버그는 고치지 않는다(키트 관리 파일이다 — 다음 설치 때 덮이고, 루프가 지금 그 파일을 실행 중이다)
- 멈춤 기록 `.ticket-loop/stops/<id>.json`(기계별): 수습하든 안 하든 멈출 때마다 한 번 쓴다(`write_stop_record` — 종류·사유·이슈·제목·스펙·PR·워커 워크트리·메인 체크아웃·루프 로그와 이 실행의 시작 바이트·병합 뒤 검증 로그와 워크트리·저장소 명령·다시 실행할 명령·판정 파일 경로·키트 버전). 신호는 `signal`, `set -e`는 `unexpected_exit`. 이슈의 멈춤 코멘트에 "멈춤 기록 … — 이어받으려면 `/loop-triage <id>`" 한 줄. 잠금을 못 잡은 실행은 쓰지 않는다
- 새 관리 스킬 `.agents/skills/loop-triage/`(+ `.claude/skills/` 링크, Codex `agents/openai.yaml`, 명시 호출 전용): 무인·사람 두 모드, 기록 찾기(경로·id·이슈 번호·가장 최근), 읽을 것, 분류(project·flake·environment·loop-bug·needs-human), 종류별 절차(병합 뒤 검증: 원인 PR diff와 대조해 기대값이나 코드를 고치고 실패한 파일만 검증해 `Refs #N` 수정 PR, 플레이크 판정 / CI: PR 브랜치에 `git push origin HEAD:<head>`, 임계값은 근거가 있을 때만, 인프라 오류는 `gh run rerun --failed` / 준비: 재현 뒤 수정 PR / 워커: 진단만), 하지 않는 것(메인 체크아웃·키트 관리 파일·근거 없는 테스트 약화·병합·운영 환경·로컬 프로세스·키트 저장소에 직접 이슈), 키트 버그 보고서(`<id>.kit-bug.md` — 공개 저장소로 로그가 저절로 나가지 않게 로컬에), 판정 파일 형식(임시 파일 뒤 `mv`), 사람 모드 마무리(병합 확인, `rerun`, 열린 PR·남은 워크트리 정리)
- 티켓 기록에 `triage`(예 `resumed (project, fix PR #131 merged): …`), 요약 줄 끝에 `, triage resumed (…)`, 스펙 리포트의 결과 브리프에 한 줄, 종료 알림에 "N triaged". `backend_worktree_create`·`loop_worktree_add`가 이름을 받고(수습 세션의 워크트리는 준비가 실패해도 띄운다), `ensure_agent_started`가 다시 띄울 프롬프트를, `run_post_merge`가 로그 이름 꼬리표를 받는다
- `install.sh`: `.gitignore`에 `/.ticket-loop/stops/`
- 실험: 실행 중인 bash 스크립트가 든 체크아웃을 `git merge --ff-only`로 바꿔도 git은 파일을 새 inode로 만들어, 실행 중인 프로세스는 옛 내용을 끝까지 읽는다 — 메인 체크아웃 fast-forward가 도는 루프를 깨지 않는다
- `tests/smoke.sh`: 멈춤 기록(die·set -e·신호의 종류, 내용, `set -u` 아래 빈 변수, 다시 실행할 명령의 인용, 잠금을 못 잡은 실행, 수습이 쓴 기록을 다시 쓰지 않음, 코멘트의 id 안내), 이어 감 기록(코멘트 하나·`~`·Slack). `triage`를 실제 git(bare origin에 스킬)과 가짜 백엔드·`gh`·CI로 — 수정 PR resume(호출 순서·라벨·병합 인자·워크트리 정리·기록·프롬프트·Slack 두 번), halt, 진단만 하는 종류, 한 실행 횟수·같은 멈춤, 띄우지 않는 경우 넷, 판정 없음·시간 초과·세션 기동 실패(원래 사유 유지, 멈춤 보고 없음), 수정 PR의 CI 실패·다른 기본 브랜치·병합 실패, PR 브랜치 push·티켓 PR 번호·코드 변경 없음, 키트 버그 보고서. 실제 git으로 `loop_worktree_add`의 준비 실패 → 수습 → fast-forward → 다시 준비, 수습이 halt면 die, 수습 세션 워크트리는 수습을 다시 부르지 않음. 네 자리의 연결과 수습 뒤 검증 로그 이름. 넣은 결함(세션 기동 중 die 바꾸기 없음, 횟수 검사 없음, 수습 기록 다시 쓰기, 진단만 하는 종류의 resume, 수습 뒤 fast-forward 없음)이 각각 실패하는 것을 확인했다
- 가이드북: 6장 변수 표 네 행, 10.2에 멈춤 기록, 10.6 "무인 수습" 새 절, 11장, 부록 D 재생성, 부록 E 한 행. README 두 벌에 "무인 수습" 절·배치 표·검증 상태, 버전 고정 `#v0.9.0`. `setup-ticket-loop` 스킬(결정 표, 운영 문서 안내, 링크 검증)과 npx 설치기의 `loop.env` 머리 주석. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.9.0 init`(또는 `install.sh`) 뒤 그 PR을 병합해야 수습이 켜진다(기본 브랜치의 스킬을 쓴다). 끄려면 `.ticket-loop/loop.env`에 `LOOP_TRIAGE="${LOOP_TRIAGE:-0}"`
- 실제 에이전트로 수습을 돌린 실측은 아직 없다

## 0.8.11 — 2026-10-16

병합 뒤 검증이 그 병합과 무관한 플레이크로 루프를 멈췄다. 2026-10-15 rental-portal 루프(0.8.6)가 #106 병합 뒤 44분짜리 통합 테스트(vitest, 2050건)에서 1건이 `Test timed out in 15000ms`로 실패해 멈췄다. 로그 7회분을 보면 실행마다 아무 테스트나 몇 개가 한 번에 8~13초씩 멈추고, 7회 중 2회(#101, #106)가 이렇게 실패했다. 두 번 모두 실패한 테스트만 다시 돌리면 통과할 성격이었다. 지금까지는 재시도 경로가 없었고, 멈춤 문구도 "수정 PR 뒤 재실행"이라 플레이크에는 맞지 않았다.

- `ticket-loop.sh`: 새 설정 `POST_MERGE_RETRY_CMD`(기본 비움). `POST_MERGE_CMD`가 실패하고 이 값이 있으면 포트 대기를 다시 지나(첫 실행이 띄운 서버가 포트를 늦게 놓을 수 있다) 같은 검증 워크트리에서 그 명령을 딱 한 번 `bg_wait`로 돌린다. 첫 실행 로그의 절대 경로를 `POST_MERGE_FAILED_LOG`로 넘기고, 출력은 같은 디렉터리의 `post-merge-N-retry.log`에 쓴다. 포트 대기는 `wait_post_merge_port`로 빼서 첫 실행과 재실행이 같이 쓴다
- 재실행이 통과하면 결과는 `passed on retry in Ns (first run failed in Ms)`(요약 줄·기록의 `post_merge`·스펙 리포트에 그대로 나온다 — 기록에 따로 필드를 두지 않고 이 문자열로 가린다), `log warn` 한 줄 뒤 계속 간다. 플레이크가 묻히지 않게 이슈에 한국어 코멘트("**ticket-loop 병합 뒤 검증 재시도 통과** — 플레이크 의심", 소요 시간, PR, 머신, 두 로그 파일 이름)를 달고 데스크톱과 Slack에 멘션 없이 알린다(새 알림 종류 `flaky`, 아이콘 `:warning:`). 로그 본문은 공개 저장소에 올리지 않고, `loop-stopped` 라벨은 붙이지 않는다
- 재실행도 실패하면 결과는 `failed on retry in Ns (first run failed in Ms)`이고, 멈춤 문구에 두 로그 경로를 적고 "If it looks like a flake, just rerun; otherwise rerun after a fix PR."로 바꿨다. 비워 두면 동작·문구가 전과 같다. 시작 줄에 재실행 설정을 함께 찍는다
- 키트는 테스트 도구에 묶이지 않는다 — 무엇을 다시 돌릴지는 저장소 스크립트가 정한다. 문서에 vitest 예(첫 실행 로그에서 ANSI 색을 `perl`로 지우고 `FAIL … .test.ts` 파일만 다시 돌림, 못 찾으면 재실행하지 않고 실패)를 넣었다. 실패한 파일을 못 찾을 때(설치·환경 점검 단계 실패) 실패로 끝내야 진짜 깨진 기본 브랜치가 재실행에 묻히지 않는다
- `tests/smoke.sh`: 실제 git 저장소에서 `run_post_merge`를 그대로 불러 — 재실행 설정 없음+실패는 rc 1·`failed in`·재실행 로그 없음(지금 동작), 실패+재실행 통과는 rc 0·`on retry`·같은 디렉터리의 `post-merge-7-retry.log`·검증 워크트리에서 `$POST_MERGE_FAILED_LOG`(절대 경로)로 첫 실행 출력을 읽음·플레이크 기록 호출, 실패+재실행 실패는 rc 1·기록 없음, 첫 실행 통과면 재실행 안 함, 첫 실행이 포트를 쥔 채 끝나면(`PORT_WAIT_SEC=0`) 재실행 없이 1. 플레이크 기록은 가짜 `gh`·`curl`로 — 코멘트 하나뿐(라벨 없음), 로컬 경로·로그 본문 없음, Slack은 `:warning:`·멘션 없음. 스펙 리포트에 새 결과 문자열이 그대로. 재실행 분기를 뺀 사본과 재실행 전 포트 대기를 뺀 사본에서 새 케이스가 실패하는 것을 확인했다. bash 3.2로도 통과한다
- 가이드북: 6장 변수 표 한 행, 7장 6단계에 재실행 문단과 vitest 예, R10에 "and again on retry" 대처, 부록 D 재생성, 부록 E 한 행. README 두 벌·`setup-ticket-loop` 스킬(결정 표·`loop.env`·운영 문서 안내·vitest 예)·npx 설치기의 `loop.env` 머리 주석에 새 설정. README 버전 고정 `#v0.8.11`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.11 init`(또는 `install.sh`). 설정하지 않으면 동작은 그대로다. 쓰려면 실패한 테스트만 다시 돌리는 스크립트를 커밋하고 `.ticket-loop/loop.env`에 `POST_MERGE_RETRY_CMD="${POST_MERGE_RETRY_CMD:-bash scripts/post-merge-retry.sh}"`

## 0.8.10 — 2026-10-16

티켓 요약 줄의 "idle false positives"와 기록(`RECORDS_FILE`)의 `idle_false_positives`가 처음부터 늘 0이었다. 오판(PR 대기 중 idle이 잡혔지만 잠깐 뒤 다시 보니 PR이 열려 있던 것 — PR을 연 직후 idle이 PR 조회보다 먼저 잡힌다)은 `wait_for_pr` 안에서 셌는데, 이 함수는 서브셸에서 돈다(0.8.7까지 커맨드 치환, 0.8.8부터 `bg_wait`). 서브셸에서 올린 변수는 부모에 돌아오지 않는다. 더미 저장소의 기록 4건도 모두 0이었다. 스펙 리포트는 이 값을 쓰지 않아 영향이 없다.

- `ticket-loop.sh`: 티켓마다 임시 파일(`IDLE_FP_FILE`)을 두고 오판 한 번에 한 줄을 쓴다. 요약 줄과 기록은 `idle_fp_count`(줄 수)를 쓴다. PR 없이 멈춘 티켓의 `stopped` 기록에도 그때까지의 수가 남는다. 변수 `IDLE_FALSE_POSITIVES`는 없앴다
- `tests/smoke.sh`: 진짜 `wait_for_pr`를 `bg_wait`로 돌려(가짜 `open_pr_for`·`terminal_idle`) 오판 한 번 뒤 PR을 찾은 경우 `0|77|1`, 오판 한 번 뒤 PR 없이 멈춘 경우 `1||1`, 파일이 없으면 0. 변수로 세던 방식으로 되돌린 사본에서 `0|77|0`으로 실패하는 것을 확인했다
- 가이드북: 부록 D 재생성, 부록 E 한 행. README 버전 고정 `#v0.8.10`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.10 init`(또는 `install.sh`). 설정은 없다. 이전 기록의 0은 실제 값이 아니다 — 회고(`/retro`)에서 그 수를 근거로 쓰지 않는다

## 0.8.9 — 2026-10-16

0.8.8의 멈춤 보고가 같은 날 앞 실행의 로그 줄을 섞어 실었다. 로그는 날짜별 한 파일(`loop-MMDD.log`)에 이어 쓰는데 "로그 끝 N줄"을 파일 끝에서 잘랐기 때문이다. 더미 저장소 실측에서 SIGTERM 멈춤의 Slack 알림 코드 블록에 바로 앞 실행(SIGHUP으로 멈춘 것)의 줄과 그 ERROR가 함께 나왔다 — 지금 멈춘 실행의 사유를 잘못 읽게 한다.

- `ticket-loop.sh`: 시작할 때 로그 파일 크기를 `LOG_START_BYTES`로 기억하고, 멈춤 보고(Slack의 로그 끝 12줄, GitHub 코멘트의 루프 로그 끝 30줄)는 그 뒤에 쓰인 부분(`run_log`)에서만 뽑는다. 로그 파일 자체와 다른 동작은 그대로다
- `tests/smoke.sh`: 앞 실행의 ERROR 줄을 깐 로그로 멈추게 해, Slack·GitHub 어디에도 실리지 않고 코멘트의 줄 수가 이 실행의 것만인지. 파일 전체를 읽던 동작으로 되돌린 사본에서 실패하는 것을 확인했다. 시작 때 크기를 기억하는지
- 가이드북: 부록 D 재생성, 부록 E 0.8.8 행에 한 줄. README 버전 고정 `#v0.8.9`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.9 init`(또는 `install.sh`). 설정은 없다

## 0.8.8 — 2026-10-15

자리를 비운 사이 루프가 끊기면 밖에서 알 길이 없었다. 알림은 데스크톱(macOS 알림 센터)뿐이었고, 그마저 `die`로 멈출 때만 갔다 — `set -e`에 걸린 명령(네트워크가 끊겨 `git fetch`·`gh`가 실패하는 등), 터미널 창 닫힘, Ctrl-C, `kill`로 끝나면 알림도 티켓 기록도 없었다. 알림은 Slack으로, GitHub는 기록으로 나눴다. GitHub 코멘트를 알림으로 쓰지 않는 이유: 루프는 사용자 계정(`gh auth`)으로 쓰고 GitHub는 본인 활동을 본인에게 알리지 않는다.

- `ticket-loop.sh`: 멈춤 보고(`stop_report`)를 한 곳으로 모으고 한 번만 한다. `die`, 새 `on_exit`(EXIT — `set -e`에 걸린 명령을 사유로, trap 안의 `BASH_COMMAND`), 새 `on_signal`(HUP·INT·TERM·PIPE)이 모두 여기로 온다. bash는 신호에도 EXIT trap을 돌리지만 그 안의 `$?`가 0이라(5.3·3.2 실험) 신호는 따로 잡는다. 보고 내용: 진행 중 티켓을 `stopped`로 기록(전과 같음, 이제 신호·`set -e`에도), 그 이슈에 GitHub 기록, 데스크톱과 Slack 알림. 종료 코드는 그대로다(`die` 1, `set -e`는 걸린 명령의 것, HUP 129·INT 130·PIPE 141·TERM 143)
- PIPE: 로그를 받던 `tee`만 먼저 죽은 상태에서 루프가 로그 한 줄을 쓰면 SIGPIPE(141)로 죽고 EXIT trap도 돌지 않아 보고 없이 잠금까지 남았다(실험 — 다음 실행이 "Another loop is running"으로 막힌다). PIPE도 잡아 보고하고, 보고하는 동안은 PIPE를 무시한다. trap은 자식에 이어지지 않으므로 파이프 안 명령의 SIGPIPE 동작은 그대로다. pty를 닫아 터미널 창 닫힘을 흉내 낸 실험에서는 `tee`가 살아 ERROR 줄까지 로그에 남았다
- Slack: `SLACK_WEBHOOK_URL`(Incoming Webhook)이 있으면 루프 시작(대상 목록 10개까지), 티켓 완료(PR·경과 분), 멈춤(사유 + 로그 끝 12줄 — 워커 화면 꼬리가 들어 있어 "왜 멈췄나"가 보인다), 루프 종료를 올린다. 본문의 `#N`은 이슈·PR 링크(`gh repo view`의 URL — GitHub Enterprise도 맞다), `&`·`<`·`>`는 Slack 규칙대로 이스케이프한다. `SLACK_MENTION`(예 `<@U012AB3CD>`)은 멈춤에만 앞에 붙고 Ctrl-C에는 붙지 않는다. 잠금을 잡은 실행만 보낸다 — `--dry-run`, 그리고 이미 도는 루프와 겹쳐 시작하자마자 멈춘 실행이 "루프가 멈췄다"고 알리지 않게. 보내기 실패는 경고 한 줄이고 루프 결과를 바꾸지 않는다. 시작 줄에 "notifications: desktop + Slack"
- GitHub 기록: 티켓 처리 중(`STOP_ISSUE` — 병합 뒤 검증 실패도 그 티켓) 멈추면 그 이슈에 코멘트(사유, 머신·백엔드·에이전트·모델, 티켓 시작→중단 시각, PR, 남겨 둔 워크트리(`~` 경로), 루프 로그 파일, 루프 자신의 로그 끝 30줄)를 달고 `STOPPED_LABEL`(기본 `loop-stopped`, 없으면 만든다)을 붙인다. 코멘트의 로그는 `[시각]`으로 시작하는 루프 자신의 줄뿐이다 — 들여 쓴 워커 화면·검증 로그는 공개 저장소에 올리지 않는다. 대상 선택은 이 라벨을 보지 않고, 루프가 그 티켓을 병합하면 뗀다
- 기계별 설정 파일 `~/.config/ticket-loop/loop.env`(`XDG_CONFIG_HOME`을 따른다): 저장소 `loop.env`보다 먼저 읽어 그쪽이 이긴다(환경변수는 둘 다 이긴다). Webhook URL 같은 비밀 값은 커밋하는 저장소 `loop.env`에 둘 수 없어서다. 저장소 `loop.env`에 `hooks.slack.com`이 있으면 시작할 때 경고한다
- 데스크톱 알림(macOS)이 문구를 AppleScript 소스에 끼우지 않고 인자로 넘긴다 — 티켓 제목이나 멈춤 사유(`set -e`의 명령)의 따옴표가 스크립트를 깨 알림이 조용히 사라지던 것
- 잠금: EXIT trap이 `on_exit` 하나가 되고, 잠금은 이 실행이 잡았을 때(`LOCK_HELD`)만 푼다. trap은 잠금 전에 건다
- 긴 대기는 신호에 바로 깬다(`bg_wait`): bash는 포그라운드 자식이 끝날 때까지 trap을 미룬다. 더미 저장소·cmux 실측에서 루프 pid에만 보낸 SIGHUP이 PR 대기(`wait_for_pr`, 커맨드 치환 서브셸)가 끝난 2분 뒤에야 처리됐다 — 다른 터미널의 `kill <루프 pid>`는 PR이 열릴 때까지 먹히지 않았을 것이다(trap을 걸기 전에는 기본 동작이라 바로 죽었다). 터미널 창 닫힘·Ctrl-C는 프로세스 그룹 전체에 가서 원래도 됐다. PR 대기, CI 대기(`gh pr checks --watch`), 수리 중 idle 대기, `POST_MERGE_CMD`, `WORKTREE_SETUP_CMD`를 백그라운드로 돌리고 `wait`로 기다린다 — `wait`는 신호에 바로 돌아오고 `on_signal`이 기다리던 자손까지 끝낸다(`kill_tree`). 백그라운드 쪽은 `set +e`로 돌아 커맨드 치환 때와 같다. 고친 뒤 같은 실측: SIGTERM을 보낸 그 초에 ERROR 줄, 보고를 마치고 6초 뒤 143, 남은 자식 없음
- `tests/smoke.sh`: `bg_wait`로 `sleep`을 기다리는 루프에 밖에서 TERM을 보내 8초 안에 143·보고 한 번·자식 없음, `bg_wait`의 종료 코드 전달과 `set +e`, 다섯 곳이 `bg_wait`를 쓰는 것(포그라운드로 되돌린 사본에서 33초 뒤에야 처리돼 실패하는 것을 확인). 알림·멈춤 보고 블록을 가짜 `gh`·`curl`·`osascript`로 그대로 부른다 — `die`·`set -e`·HUP·INT·TERM·PIPE·정상 종료 일곱 가지의 종료 코드·사유·보고 횟수(한 번)·잠금 해제, Slack 페이로드(아이콘·멘션은 멈춤만·Ctrl-C 제외·`#N` 링크·이스케이프·로그 꼬리), 데스크톱 알림 인자, GitHub 호출 순서(라벨 만들기·코멘트·라벨 붙이기)와 코멘트 내용(워커 화면 줄이 없을 것), 잠금을 못 잡은 실행(Slack·GitHub 없음, 남의 잠금 유지), 웹훅이 없을 때, 완료·시작 알림. 본 스크립트의 연결(사용자 설정 파일을 먼저 읽음, trap→잠금→`LOCK_HELD` 순서, EXIT trap 하나, `STOP_ISSUE`, 병합 뒤 라벨 떼기). 넣은 결함(Ctrl-C 멘션, 남의 잠금 지우기)을 잡는 것을 확인했고 bash 3.2로도 통과한다
- 실측(iwishash/ticket-loop-dummy #3, cmux, 2026-10-16): 루프 pid에 SIGHUP → 이슈 코멘트(사유·머신·모델·시각·워크트리 `~` 경로·루프 로그 7줄)와 `loop-stopped` 라벨(처음이라 만들어짐), 티켓 기록 `stopped`, Slack 멈춤 알림. 위의 2분 지연을 여기서 찾았다. 고친 뒤 SIGTERM으로 한 번 더(두 번째 코멘트), 그다음 같은 티켓을 끝까지 돌려 PR #4로 병합(벽시계 3분, 수리 0) — 병합 때 `loop-stopped`가 떨어지고 멈춤 코멘트 둘은 남았다. 세 실행 모두 Slack·GitHub 전송 실패 없음. PR 대기를 백그라운드로 옮긴 뒤에도 진행 로그(브랜치·첫 수정·커밋)가 그대로 찍혔다
- 손으로 확인한 것: 실제 `curl`을 로컬 HTTP 서버로 — `application/json`, 본문 그대로, 연결 실패 시 경고만. pty를 닫아 터미널 창 닫힘 흉내 — 129로 끝나며 기록·GitHub·Slack·잠금 해제. `tee`만 먼저 죽였을 때 — PIPE를 안 잡으면 141로 조용히 죽고 잠금이 남고, 잡으면 보고한다. 실제 Slack 워크스페이스(비공개 채널, 새 앱 마법사 Blank app → Bot scope `incoming-webhook` → Create and Install에서 채널 선택)에 `slack_post`로 네 종류를 보내 아이콘·`#N` 링크·로그 코드 블록이 그대로 그려지는 것을 봤다. 실제 루프 실행은 위 실측
- 잡지 못하는 것: `kill -9`, 전원 꺼짐, 잠자기 — 스크립트가 아무것도 보내지 못한다. 외부 데드맨 스위치(주기적 핑이 끊기면 알리는 서비스)가 필요한 몫이라 이번에는 넣지 않았다
- 가이드북: 6장 변수 표 세 행과 기계별 설정 파일 한 줄, 10.2 첫머리(멈춤 보고와 어디부터 볼지), 부록 D 재생성, 부록 E 한 행. README 두 벌에 "알림" 절(Slack 앱 만들기·설정 파일·폰 알림·확인)과 기계별 파일 한 줄, 버전 고정 `#v0.8.8`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.8 init`(또는 `install.sh`)으로 스크립트가 바뀐다. 설정 없이도 GitHub 기록은 켜진다(라벨은 첫 멈춤 때 만든다). Slack은 컴퓨터마다 `~/.config/ticket-loop/loop.env`에 `SLACK_WEBHOOK_URL`을 둔다

## 0.8.7 — 2026-10-15

루프가 터미널(과 로그 파일)에 찍는 문구를 영어로 바꿨다. 한국어 터미널 로그를 영어로 보고 싶다는 요구.

- `ticket-loop.sh`: `log`·`die`·`notify`로 나가는 문구 전부 — 시작 줄("repository … / backend … / base branch … / label …", "post-merge check: on|off"), 건너뜀("skip #N (…): blocked by an open issue" 등), 대상 목록("targets (all blocking issues currently closed):"), 티켓 단계("worktree … / terminal …", "branch …", "first file changes — …", "working — Nm elapsed, N uncommitted files: …", "commit …", "PR #N opened", "waiting for CI", "CI passed", "PR #N merged", "post-merge check started/passed in Ns/failed — tail"), 수리("conflict → asking the worker to repair (1)", "CI failed → …"), idle("worker idle, no PR (1/3)"), 요약("#N summary: wall-clock 54m, PR #46, CI 261s, repairs 0, idle false positives 1, post-merge check passed in 212s"), 스펙("spec #40: all 4 sub-issues closed → closed the spec issue", 리포트·회고 안내), 종료("No tickets to process", "No more tickets to process", "--max N reached", "done: N tickets"), 모든 ERROR 줄과 백엔드 점검 안내(Orca·cmux·tmux CLI 없음, 소켓, 신뢰 대화상자, 잠금), 데스크톱 알림("Ticket done", "Ticket loop stopped", "Ticket loop finished"). 요약 줄은 `grep "summary:"`로 찾는다
- 그대로인 것: 워커 프롬프트와 수리 프롬프트(에이전트에게 보내는 글), GitHub 코멘트(이슈·스펙 닫을 때), 백엔드 상태 코멘트(Orca 워크스페이스·cmux 로그), 스크립트의 주석과 `--help` 머리글
- 티켓 기록(`RECORDS_FILE`)의 `post_merge` 값이 "passed in Ns"·"failed in Ns"·"skipped"가 된다. 0.8.6 이하 기록의 "통과 N초"·"실패 N초"·"건너뜀"은 스펙 리포트가 전처럼 표시할 때 영어로 바꾸므로 옛 기록과 섞여도 한 표에 같이 나온다. `reason`(중단 사유)은 전처럼 ERROR 문구 그대로라 새 기록부터 영어다
- `tests/smoke.sh`: 영어 문구로 고친 단정(cmux "keep waiting", 스펙 닫기, 회고 안내 — 강제 어조 검사는 must/required/mandatory, 병합 뒤 검증 시작·통과 줄, 진행 로그 기대 출력). 리포트 고정 자료에 영어 `post_merge` 기록 한 건을 더해 옛 한국어 값과 새 영어 값이 둘 다 "post-merge check …"로 나오는 것
- 가이드북: 4·7·9·10장의 예시 로그와 인용 문구를 새 문구로, `grep "요약:"` → `grep "summary:"`, 부록 D 재생성, 부록 E 한 행. README 버전 고정 `#v0.8.7`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.7 init`(또는 `install.sh`)으로 스크립트가 바뀐다. 설정은 없다. 운영 문서 `docs/agents/ticket-loop.md`나 셸 별칭에 `grep "요약:"`을 적어 뒀다면 `summary:`로 맞춘다

## 0.8.6 — 2026-10-15

루프를 처음 돌리면 "워크트리 … / 터미널 …" 줄 뒤 첫 PR이 열릴 때까지(보통 수십 분) 루프 터미널에 아무 줄도 없어 멈춘 것처럼 보였다. 워커는 다른 창에서 일하고, 루프는 idle 대기 상한(10분)마다 돌아와 PR만 물었기 때문이다. 그 구간에 진행 로그를 넣었다.

- `ticket-loop.sh`: PR·수리를 기다리는 동안 `PROGRESS_SEC`(기본 60초)마다 워크트리를 git으로만 들여다본다(백엔드·에이전트와 무관, 네트워크 없음) — 브랜치가 바뀌면(워커가 `issue-N` → `issue-N-<slug>`) "브랜치 …", 처음 파일이 수정되면 "파일 수정 시작 — a, b, c 외 N", 새 커밋이 들어오면 커밋마다 "커밋 abc1234 <제목>"(오래된 것부터, amend·reset은 지금 커밋 하나만)을 바로 한 줄씩(청록). 그 밖에는 커밋 안 된 변경 파일 목록이 지난 줄과 달라졌을 때만 `HEARTBEAT_SEC`(기본 300초)에 한 번까지 "작업 중 — N분 경과, 커밋 안 된 변경 M개 파일: …" 한 줄(맨글자) — 목록이 같거나 비어 있으면 시간이 지나도 찍지 않는다(같은 내용을 되풀이하지 않는다). `idle_wait_ms`가 PR·수리 대기의 한 번 기다리는 길이를 `PROGRESS_SEC`로 바꾼다(`0`이면 끄고 전처럼 `IDLE_WAIT_MS`). `wait_for_pr`는 커맨드 치환(서브셸)으로 불리므로 상태(`PROG_*`)는 `run_ticket`이 `progress_reset`으로 전에 만들고, PR이 열린 뒤 `progress_sync`로 기준점을 옮겨 수리 단계가 이미 찍은 커밋을 되풀이하지 않는다. 워커 화면을 읽어 도구 호출을 뽑는 쪽은 에이전트마다 형식이 달라 쓰지 않았다
- `tests/smoke.sh`: 실제 git 저장소에서 `progress_reset`/`progress_check`를 그대로 부른다 — 조용할 때 `HEARTBEAT_SEC=0`이어도 아무 줄도 없음, 브랜치·첫 수정(이름 셋 + 외 1), 커밋 2개 순서, amend 뒤 하나만, 변경 파일 수, 커밋 직후 같은 목록이면 심장박동 없음·파일이 늘면 한 줄, `progress_sync` 뒤 조용함, `idle_wait_ms`의 두 값, 워크트리가 없을 때 0. `run_ticket`이 `progress_reset`·`progress_sync`를 부모 셸에서 부르는 것
- 가이드북: 6장 변수 표 `PROGRESS_SEC`·`HEARTBEAT_SEC` 행과 내부 상수 `IDLE_WAIT_MS` 행, 7장 2단계 첫 항목, 9장 예시 로그에 진행 줄, 2.5절 cmux `unknown` 설명, 부록 D 재생성, 부록 E 한 행. README 버전 고정 `#v0.8.6`. PDF 재빌드

같은 판에 루프가 워커의 PR을 못 찾고 "PR 없이 멈춤"으로 죽던 버그도 고쳤다. rsrehab/rental-portal(키트 0.8.5, 2026-10-15) #102에서 워커가 14:42:59에 PR #120을 열었고(CI lint·build·test 녹색, 이슈에 `in-review`) 워커 화면 꼬리 상태줄에도 `PR #120`이 보였는데, 루프는 14:44:04·14:45:07·14:46:08에 "#102: 워커 idle, PR 없음 (1/3)…(3/3)"을 찍고 "ERROR: #102: 워커가 PR 없이 멈췄습니다"로 끝났다(사람이 손으로 병합하고 R5로 정리). PR의 head 브랜치가 `issue-102`였다 — 루프가 워크트리를 만들며 붙인 이름 그대로이고 slug가 없다(앞 티켓들은 `issue-101-dispatch-cutoff-prev-business-day`처럼 규약대로였다). `open_pr_for`가 head를 `startswith("issue-102-")`로만 찾아, `wait_for_pr`의 첫 조회와 idle 뒤 재조회 세 번이 모두 빗나갔다.

- `ticket-loop.sh`: `open_pr_for`와 스펙 리포트 `REPORT_JQ`가 head 브랜치가 `<BRANCH_PREFIX>N`과 정확히 같거나 `<BRANCH_PREFIX>N-`로 시작하는 PR을 그 티켓의 PR로 본다. `N`만 접두로 보면 `issue-1020`·`issue-1020-x`가 #102에 걸리므로 두 꼴만이다. 리포트에서 이런 티켓의 PR이 비어 "Stopped"·"Closed without PR"로 나오던 것도 같이 고쳐진다. 0.8.6의 진행 로그 주석("워커가 issue-N → issue-N-<slug>로 옮김")은 브랜치가 바뀌었을 때 찍는 조건이라 이번 실측과 어긋나지 않는다 — 안 옮기면 그 줄이 없을 뿐이다. 주석에 "옮기지 않고 issue-N에 그대로 커밋해도 PR은 잡는다"를 덧붙였다
- `ticket-state.sh`: PR 목록 필터가 같은 규칙이고, 원격 브랜치 조회가 `refs/heads/issue-N`과 `refs/heads/issue-N-*` 둘 다 본다. 저장소 전체(`docs/guide.html` 포함)를 grep한 `N-` 접두 가정은 이 셋과 가이드 10.2의 같은 함수뿐이었다
- `templates/.ticket-loop/worker-rules.md`: "루프가 만든 워크트리는 `issue-N` 브랜치(기본 브랜치의 원격 tip)에서 시작한다. 그 브랜치에 커밋하지 말고, 첫 커밋 전에 implement 스킬대로 `issue-N-<slug>` 브랜치를 만들어 거기서 일한다" 한 줄. implement 스킬이 이미 `git checkout -b issue-<N>-<slug>`를 시키지만 #102의 워커는 건너뛰었다. 무인 워크트리의 시작 브랜치가 `issue-N`이라는 사실은 루프에서만 참이라 스킬이 아니라 여기에 둔다. 루프 쪽 수정만으로도 PR은 잡히므로 이 줄은 규약 유지용이다. 템플릿은 설치 뒤 프로젝트 소유라 **이미 설치된 저장소는 손으로 옮긴다**
- 브랜치 이름 대신 GitHub 연결(`gh pr list --json number,headRefName,closingIssuesReferences`)로도 찾을지 검토했다 — 쓰지 않는다. 본문의 `Closes #N`은 사람이 쓰는 것이라 사람이 연 PR이나 두 이슈를 한 번에 닫는 다른 PR도 "이 티켓의 PR"이 되고, 루프의 기준이 브랜치 이름 하나에서 둘로 늘어 10장 판정이 복잡해진다. 브랜치 꼴은 루프(`issue-N`)·스킬(`issue-N-<slug>`) 둘뿐이라 이름만으로 충분하다
- `tests/smoke.sh`: 가짜 `gh`로 `open_pr_for` — head가 `issue-102`·`issue-102-slug`면 잡고 `issue-1020`·`issue-1020-x`·`issue-10`이면 빈 값, PR이 없으면 빈 값. `REPORT_JQ` 고정 자료에 head가 정확히 `issue-44`인 병합 PR #52(T04의 PR, Merged 배지·KPI 3건)와 이슈 4(Not started — `issue-44`가 #4에 붙지 않는다). `ticket-state.sh`의 jq 필터를 뽑아 같은 규칙인지, 원격 브랜치 조회가 두 패턴인지, 워크트리 조회 패턴이 그대로인지
- 가이드북: 5장 집는 조건 표, 6장 `BRANCH_PREFIX` 행, 7장 2단계, 10.2 진단 함수, 10.3 표 아래 한 줄(원격에 `issue-N`만 있을 때 R 절차의 브랜치 이름), R2-b·R3·R5의 원격 브랜치 삭제 이름, 부록 D 재생성, 부록 E 한 행. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.6 init`(또는 `install.sh`)으로 스크립트(`ticket-loop.sh`·`ticket-state.sh`)가 바뀐다. 설정은 없어도 된다 — 전처럼 조용하길 바라면 `loop.env`에 `PROGRESS_SEC="${PROGRESS_SEC:-0}"`. `.ticket-loop/worker-rules.md`는 프로젝트 소유라 설치기가 덮지 않는다 — 위 브랜치 한 줄은 손으로 옮긴다

## 0.8.5 — 2026-10-15

병합 뒤 검증이 실패했을 때 루프가 그 로그를 못 찾던 버그를 고쳤다. rsrehab/rental-portal(키트 0.8.3, 2026-10-15) #101에서 통합 테스트가 실패하자 로그에는 "병합 뒤 검증 실패 — 꼬리 ---" 다음 줄로 `tail: .ticket-loop/post-merge-101.log: No such file or directory`가 찍혔고, ERROR 줄이 가리키는 저장소 루트의 `.ticket-loop/`에는 파일이 없었다. 실제 로그는 검증 워크트리 안 `~/.cache/ticket-loop/rsrehab-rental-portal/post-merge/.ticket-loop/post-merge-101.log`에 있었고, 지난 실행의 `post-merge-98.log`·`post-merge-99.log`도 전부 거기 쌓여 있었다. 원인은 `LOG_FILE` 기본값이 상대 경로(`.ticket-loop/loop-MMDD.log`)인 채로 `logfile="$(dirname "$LOG_FILE")/post-merge-N.log"`를 만들고, 그 파일을 `(cd "$wt" && … >"$logfile")`처럼 검증 워크트리로 `cd`한 서브셸에서 열어 워크트리 기준으로 생겼기 때문이다. 꼬리를 읽는 `tail`은 루프 cwd(저장소 루트)에서 돌아 못 찾았다. `LOG_FILE` 자체는 루프 cwd가 늘 저장소 루트라 지금까지 드러나지 않았다.

- `ticket-loop.sh`: `LOG_FILE`·`RECORDS_FILE`·`REPORT_DIR`를 시작 때 한 번 저장소 루트 기준 절대 경로로 굳힌다(`abs_path`. 환경변수나 `loop.env`로 상대 경로를 줘도 같다. `/dev/null`은 그대로). 0.8.4의 `exec 2> >(tee >(strip_ansi >> "$LOG_FILE") >&2)`도 절대 경로를 받는다. `ROOT`는 `loop.env`를 읽기 전에 정하고 도구 검사 뒤 git으로 다시 확정한다. `run_post_merge`는 로그 디렉터리를 `mkdir -p`하고 경로를 `POST_MERGE_LOG`에 둬서 "병합 뒤 검증 시작" 줄과 `die`의 ERROR 줄에 실제 파일 위치(절대 경로)가 찍히고, 실패 꼬리 `tail`도 그 경로를 읽는다. `record_ticket`·`write_spec_report`의 `$ROOT/` 덧붙이기는 필요 없어져 뺐다. 같은 패턴 전수 확인 — `cd`한 서브셸은 `CI_SKIP_CMD`(저장소 루트)·`WORKTREE_SETUP_CMD`(사용자 명령, 루프 파일을 안 씀)·병합 뒤 검증 셋이고, 프롬프트 파일은 `mktemp` 절대 경로, tmux 훅 상태 파일은 `~/.cache` 아래라 이 셋 밖에는 없었다. `WORKER_RULES_FILE`은 워커 프롬프트에 저장소 상대 경로로 들어가는 것이 맞아 그대로다
- `tests/smoke.sh`: bare 저장소 + 메인 체크아웃 + 검증 워크트리를 실제 git으로 만들어 `run_post_merge`를 상대 `LOG_FILE`로 돌린다 — `post-merge-N.log`가 저장소 루트 쪽 `.ticket-loop/`(다른 상대 디렉터리를 줘도 그쪽)에 생기고 워크트리 안에는 안 생기며, `POST_MERGE_CMD='…; exit 1'`일 때 꼬리에 명령 출력이 있고 "No such file"이 없고, 시작 줄·`POST_MERGE_LOG`가 절대 경로인 것. `abs_path`가 `/dev/null`·절대 경로를 그대로 두는 것. 0.8.4 스크립트로 같은 자리를 돌리면 "No such file"이 난다
- 가이드북: 6장 변수 표 `LOG_FILE` 행(상대 경로는 저장소 루트 기준, 검증 로그는 같은 디렉터리), 7장 6단계와 예시 로그, R10의 로그 위치, 부록 D 재생성, 부록 E 한 행. `setup-ticket-loop` 6항: 운영 문서에 검증 로그 위치 한 줄. README 버전 고정 `#v0.8.5`. PDF 재빌드
- 이미 설치된 저장소: `npx github:iwishash/ticket-loop-kit#v0.8.5 init`(또는 `install.sh`)으로 스크립트와 스킬이 바뀐다. 검증 워크트리 안 `.ticket-loop/post-merge-*.log`(`~/.cache/ticket-loop/<owner-repo>/post-merge/.ticket-loop/`)는 지난 실행의 흔적이라 지워도 된다. 운영 문서 `docs/agents/ticket-loop.md`의 R10 항목에 로그 위치를 적어 뒀다면 "저장소 루트의 `.ticket-loop/post-merge-N.log`(ERROR 줄에 절대 경로가 찍힌다)"로 맞춘다

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
