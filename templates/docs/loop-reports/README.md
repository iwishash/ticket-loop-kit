# 루프 스펙 리포트

`bash scripts/ticket-loop.sh --parent <스펙>` 실행이 정상 종료하면(완료 · 더 처리할 티켓 없음 · 처리할 티켓 없음) 루프가 여기에 `spec-<N>.html` 한 장을 쓴다(표의 고정 문구는 영어, 이슈·PR 제목과 중단 사유는 GitHub·기록의 원문 그대로). 스펙의 하위 티켓마다 상태 · 작업 결과 브리프(PR 제목, 본문의 인수 조건 체크 수, 중단 사유, CI 소요 · 수리 횟수 · 병합 뒤 검증) · 경과 시간 · 사용 모델 · 마친 시각을 표로 담는다. 설명은 「티켓 무인 루프 가이드북」 7장 9단계, 이 저장소의 운영 문서는 `docs/agents/ticket-loop.md`.

- 같은 스펙은 같은 파일을 덮어쓴다 — 끝난 스펙의 리포트를 다시 뽑으려면 `bash scripts/ticket-loop.sh --parent <N>`을 한 번 더 돌린다(남은 티켓이 없으면 리포트만 만들고 끝난다)
- 루프는 커밋하지 않는다. 사람이 보고 PR로 올린다
- 경과 시간 · 모델의 원자료는 기계별 `.ticket-loop/tickets.jsonl`(커밋 안 함)이다. 기록이 없는 티켓(다른 PC · 사람이 처리 · 이 기능 이전)은 PR 생성→병합 시간으로 대신하고 그렇게 표시하며 모델은 "not recorded"로 나온다
- 리포트를 쓰면 기본 브라우저로 연다(macOS `open`, Linux `xdg-open`). SSH 세션이나 화면 없는 Linux에서는 열지 않는다. 끄려면 `.ticket-loop/loop.env`에 `REPORT_OPEN=0`
- 위치를 바꾸려면 `.ticket-loop/loop.env`에 `REPORT_DIR`, `RECORDS_FILE`을 적는다
- `.ticket-loop/loop.env`에 `REPORT_DECISIONS_HEADING="사람 확인 필요"`처럼 PR 본문 절의 제목을 적으면, 리포트 머리에 그 절이 있는 PR의 절 본문을 티켓·PR 링크와 함께 모아 보인다(절이 없거나 빈 PR, 본문이 `없음`·`- 없음`처럼 없음 표시뿐인 PR은 제외 — 없음 표시 목록은 `REPORT_DECISIONS_NONE`, 기본 `없음|none|N/A`). 워커가 스펙과 다르게 정했거나 스펙이 사람에게 남긴 결정을 내린 것을 PR 본문의 그 절에 적게 해 두면, 병합된 PR을 하나씩 열지 않고 리포트에서 본다
