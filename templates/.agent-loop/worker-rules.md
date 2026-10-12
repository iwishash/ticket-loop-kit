# 워커 규칙 (scripts/ticket-loop.sh)

무인 루프의 워커만 따르는 프로젝트 규칙이다. 절차(선행 확인·브랜치·seam·ticket-review·PR 본문·라벨)는 `.claude/skills/implement/SKILL.md`가 단일 진실이다.

- 검증은 두 층이다. 수시에는 `__TYPECHECK__`과 `__TEST_FILE__`만 돌린다. 전체 묶음 `__VERIFY__`는 첫 커밋 직전 1회, ticket-review 반영 커밋 직전 1회만 돌린다.
- __HEAVY_TESTS_RULE__
- __MIGRATION_RULE__
- 프로젝트 의존성을 쓰는 임시 스크립트는 워크트리 안 `scripts/`에 두고 커밋 전에 지운다(저장소 밖 임시 폴더에서는 모듈 해석이 실패한다).
- 화면 확인용 스크린샷은 작게(폭 400px 이하) 한 장만 찍는다.
- 운영 환경(운영 DB, 배포 명령)에는 어떤 경우에도 연결하지 않는다.
- CI를 통과시키려고 테스트를 건너뛰거나 지우지 않는다.
