> [!NOTE]
> 한 사람의 저장소에 맞춰 만들고 자주 바뀐다. 기대어 쓴다면 버전 태그(`npx github:iwishash/ticket-loop-kit#vX.Y.Z init`)로 고정한다.

<div align="center">

# ticket-loop-kit

**스펙의 티켓을 코딩 에이전트에 맡기고, 돌아와 병합된 PR을 본다.**

GitHub 이슈 티켓을 한 건씩 — 새 워크트리, 에이전트, PR, CI, 수리, 병합까지 — 무인으로 처리하는 루프를 명령 하나로 아무 저장소에나 설치한다.

[![Version](https://img.shields.io/github/v/tag/iwishash/ticket-loop-kit?sort=semver&style=flat-square&label=version)](CHANGELOG.md)
[![smoke](https://img.shields.io/github/actions/workflow/status/iwishash/ticket-loop-kit/smoke.yml?branch=main&style=flat-square&label=smoke)](https://github.com/iwishash/ticket-loop-kit/actions/workflows/smoke.yml)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square)](#제약)

[**설치**](docs/install.ko.md) · [**루프 돌리기**](docs/loop.ko.md) · [**멈출 때**](docs/stops.ko.md) · [**검증 상태**](docs/verification.ko.md) · [**English**](README.md)

```sh
npx github:iwishash/ticket-loop-kit init
```

</div>

이 파일이 한국어 원문이고 [README.md](README.md)는 그 영문판이다.

---

## 왜

스펙을 티켓 열두 개로 나누는 건 쉽다. 어려운 건 에이전트가 티켓 하나하나를 끝내게 하는 뒷바라지다. 워크트리를 열고, 에이전트를 띄우고, PR을 기다리고, CI를 다시 돌리고, 병합하고, 당겨 오고, 느린 테스트를 돌리고, 다음 티켓을 띄운다 — 그리고 자리를 비운 사이 무언가 깨졌으면 알아채야 한다.

티켓 루프가 그 뒷바라지를 한다. 티켓에 `ready-for-agent` 라벨을 붙이거나(또는 스펙의 하위 이슈로 만들고) 명령 하나를 돌리면, 티켓마다 워크트리 → 에이전트 → PR → CI → 병합 → 정리를 거친 뒤 다음 티켓으로 간다. 멈출 일이 생기면 먼저 고쳐 보고, 그다음에 알린다.

## 무엇을 얻나

| | |
|---|---|
| **티켓 하나에 새 워크트리 하나** | 티켓마다 최신 기본 브랜치에서 빈 컨텍스트로 시작한다. 티켓 사이에 새는 것이 없고, 각 티켓은 앞서 병합된 것 위에 쌓인다. |
| **박힌 프롬프트가 아니라 스킬** | 워커는 저장소에 커밋된 `/implement N` 스킬을 따르고, 그 스킬이 `tdd` → `ticket-review` → `pr`을 부른다([mattpocock/skills](https://github.com/mattpocock/skills)에서 벤더링해 고정). 워커의 일하는 방식을 바꾸려면 PR로 스킬을 고친다. |
| **기본 브랜치까지** | CI를 기다리고, 충돌·실패는 같은 워커에 돌려보내 고치게 하고, 병합하고, 마지막 티켓이 닫히면 스펙도 닫는다. 느린 스위트는 몇 개 병합마다 기본 브랜치에서 돌고, 플레이크용 재실행(선택)과 깨뜨린 병합을 찾는 이분 탐색이 붙는다. |
| **스스로 고치는 멈춤** | 병합 뒤 검증 실패, 수리를 다 쓴 CI, 깨진 워크트리 준비는 수습 에이전트가 수정 PR을 연다. 그게 병합되면 루프는 멈춘 자리에서 이어 간다. |
| **알 수 있는 멈춤** | 시작·티켓 완료·멈춤·종료를 Slack으로, 이슈에는 코멘트와 `loop-stopped` 라벨을, 그리고 어느 에이전트 세션에서나 `/loop-triage`로 이어받을 수 있는 멈춤 기록을 남긴다. |
| **GitHub만이 상태** | 라벨·담당자·PR이 전부다. 서버도 DB도 없다 — 클론만 하면 다른 컴퓨터에서도 돈다. |
| **스펙마다 리포트** | `--parent <스펙>` 실행은 HTML 리포트로 끝난다. 티켓별 결과·CI와 검증 시간·모델, 그리고 아직 사람이 할 일. |

## 지원 환경

"확인"은 실제 티켓 1건이 끝까지 지나갔다는 뜻이다.

| | 확인됨 | 갖췄지만 미확인 | 미지원 |
|---|---|---|---|
| 워커 에이전트 | Claude Code | Codex CLI | |
| 백엔드(워크트리·터미널) | Orca 1.4 · cmux 0.65 · tmux 3.8 | | |
| OS | macOS | Linux, WSL | 네이티브 Windows |
| 이슈 트래커 | GitHub Issues | | 그 밖 |

`git`, `gh`(로그인), `jq`, bash가 필요하고 Node 18 이상은 `npx … init`에만 쓴다. tmux는 어느 터미널 앱에서나, SSH 너머에서도 돈다.

## 설치

대상 저장소 루트에서:

```sh
npx github:iwishash/ticket-loop-kit init
# Node 없이:
bash <(curl -fsSL https://raw.githubusercontent.com/iwishash/ticket-loop-kit/main/install.sh)
```

설치기가 백엔드와 설치 단계를 묻는다(`--yes`면 기본값). 그다음:

1. Claude Code에서 `/setup-ticket-loop`(Codex는 `$setup-ticket-loop`)를 돌린다. 저장소를 읽고 검증 명령·`orca.yaml`·CI·워커 규칙·`loop.env`를 채워 PR을 연다.
2. Orca만: Settings → Projects → <저장소> → Worktree Hooks → Advanced에서 Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기.
3. PR을 병합한다.

업데이트는 같은 설치 명령을 다시 돌린다. 키트 소유 파일만 바뀌고 `loop.env`와 프로젝트 소유 스킬은 그대로다. → [설치와 업데이트](docs/install.ko.md)

## 사용법

```sh
bash scripts/ticket-loop.sh --dry-run      # 가져갈 티켓 목록만
bash scripts/ticket-loop.sh --max 1        # 한 건만 — 처음엔 이것부터
bash scripts/ticket-loop.sh                # 준비된 티켓 전부
bash scripts/ticket-loop.sh --parent 40    # 스펙 #40의 하위 이슈, 끝나면 스펙 리포트
bash scripts/ticket-loop.sh 12 15          # 지정한 티켓만, 적은 순서대로
```

그 밖에 `--label <라벨>`, `--no-merge`(CI 통과까지만), `--skip-post-merge`, `--help`.

준비된 티켓은 열려 있고, `ready-for-agent` 라벨이 있고, 담당자가 없고, 열린 이슈에 막혀 있지 않고, 열린 PR이 없는 이슈다. 설정은 `.ticket-loop/loop.env`(커밋한다. 환경변수가 이긴다)에, Slack Webhook 같은 기계별 비밀 값은 `~/.config/ticket-loop/loop.env`에 둔다. 선택인 기획 스킬(`/grill-with-docs`, `/to-spec`, `/to-tickets`, `/retro`)은 아이디어를 스펙 이슈와 하위 티켓으로 만들고, 다 돈 뒤 돌아본다.

→ [루프 돌리기](docs/loop.ko.md) · [루프가 멈출 때](docs/stops.ko.md)

## 제약

- **워커는 권한 확인을 끄고 돈다.** 잘못된 병합이나 강제 push를 막는 진짜 방어선은 GitHub 브랜치 보호다. 키트의 `deny` 규칙은 둘째 줄이다.
- **저장소당 루프 하나, 한 번에 티켓 하나.** 여러 컴퓨터에서 돌리면 티켓이 겹치지 않게 가른다(`--parent`, `--label`, 번호 지정).
- **변경은 병합해야 워커에 닿는다.** 티켓마다 기본 브랜치에서 시작하므로 스킬·워커 규칙·`AGENTS.md`/`CLAUDE.md` 수정은 병합한 뒤에야 적용된다.
- **무거운 스위트는 워커가 돌리지 않는다.** 통합·E2E 테스트는 `POST_MERGE_EVERY`개 병합마다(기본 4) 기본 브랜치에서 돌므로, 회귀는 몇 병합 늦게 드러나고 그 뒤 이분 탐색으로 짚는다.
- **GitHub Issues만.** 다른 트래커는 티켓 선택·PR·병합을 다시 써야 한다.
- **아직 macOS뿐.** Linux·WSL 코드 경로는 한 번도 돌지 않았고 네이티브 Windows는 미지원이다. Codex 워커는 실제 티켓으로 돌려 본 적이 없다. → [검증 상태](docs/verification.ko.md)

## 문서

| | |
|---|---|
| [설치와 업데이트](docs/install.ko.md) | 설치기와 `/setup-ticket-loop`가 쓰는 것, 파일 위치, 옵션, 벤더링 스킬과 충돌 검사, 여러 컴퓨터 |
| [루프 돌리기](docs/loop.ko.md) | 알아둘 설정(병합 뒤 검증·재실행·묶음·화면 분류), 산출물, 백엔드 |
| [루프가 멈출 때](docs/stops.ko.md) | Slack·GitHub 알림, 수습 세션, 멈춤 기록 |
| [검증 상태](docs/verification.ko.md) | 실제 티켓으로 돌린 것과 아직 안 돌린 것 |
| [키트를 고칠 때](CONTRIBUTING.ko.md) | 테스트, 가이드북 동기화, 릴리스 |

## 라이선스

[MIT](LICENSE). 벤더링한 스킬은 [mattpocock/skills](https://github.com/mattpocock/skills)(MIT)에서 온다.
