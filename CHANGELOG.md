# Changelog

## 0.1.0 — 2026-10-12

첫 공개. rsrehab/rental-portal의 티켓 루프(v1.7 실측, 가이드북 2판 PR #63)에서 범용 부분을 떼어 냈다.

- `install.sh`: 관리 파일 덮어쓰기, 템플릿은 없을 때만, mattpocock 스킬 벤더링, `.gitignore`·`deny` 병합, 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록, `.orca-loop/kit.json`
- `/setup-orca-loop` 스킬: 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`·`pr`을 저장소에 맞춰 채우고 PR
- `ticket-loop.sh`: 가이드북 2판 스크립트 + 저장소별 기본값 파일 `.orca-loop/loop.env`
- `docs/`: 가이드북 2판(PDF·HTML·빌드 스크립트)
