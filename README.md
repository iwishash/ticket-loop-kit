# orca-loop-kit

GitHub 이슈 티켓을 Orca 워크트리에서 한 건씩 무인으로 구현·검증·병합하는 **티켓 루프**를 다른 저장소에 설치하고 업데이트하는 키트.
원리와 운영은 [「Orca 티켓 무인 루프 가이드북」](docs/orca-ticket-loop-guide.pdf)에 있다.

## 설치

대상 저장소 루트에서:

```bash
bash <(gh api repos/iwishash/orca-loop-kit/contents/install.sh -H "Accept: application/vnd.github.raw")
```

그다음 Claude Code에서:

1. `/setup-matt-pocock-skills` — `docs/agents/issue-tracker.md`가 아직 없을 때
2. `/setup-orca-loop` — 검증 명령·`orca.yaml`·CI·워커 규칙·`implement`를 이 저장소에 맞춰 채우고 PR을 연다

마지막으로 Orca 앱에서 Settings → Projects → <저장소> → Worktree Hooks → Advanced: Command Source **"orca.yaml only"**, **"Wait for setup to complete before starting agent"** 켜기. PR을 병합한 뒤 `bash scripts/ticket-loop.sh --dry-run` → `--max 1`.

필요한 도구: `git`, `gh`(로그인), `jq`, `rsync`, Orca 앱과 CLI, Claude Code.

## 무엇을 어디에 두나

| 키트 경로 | 대상 저장소 | 설치 때 |
|---|---|---|
| `files/scripts/ticket-loop.sh` | `scripts/ticket-loop.sh` | 매번 덮어씀(키트 소유) |
| `files/scripts/ticket-state.sh` | `scripts/ticket-state.sh` | 매번 덮어씀 |
| `files/scripts/sync-mattpocock-skills.sh` | `scripts/sync-mattpocock-skills.sh` | 매번 덮어씀 |
| `files/.claude/skills/setup-orca-loop/` | 같은 경로 | 매번 덮어씀 |
| `templates/.claude/skills/implement/`, `pr/` | 같은 경로 | 없을 때만(이후 프로젝트 소유) |
| `templates/.orca-loop/worker-rules.md` | 같은 경로 | 없을 때만 |
| — | `.claude/skills/<mattpocock 스킬>` | `sync-mattpocock-skills.sh`가 벤더링 |
| — | `.gitignore`, `.claude/settings.json` `deny` | 줄·항목 병합 |
| — | GitHub 라벨 6개, 저장소 git 자격 증명(gh), Orca 등록 | 없으면 만듦 |
| — | `.orca-loop/kit.json` | 설치한 키트 커밋 기록 |

프로젝트별 값은 대상 저장소의 `.orca-loop/loop.env`(루프 기본값), `orca.yaml`, `.orca-loop/worker-rules.md`, `implement`·`pr` 스킬에 있다. 키트 소유 파일은 대상 저장소에서 고치지 말고 키트에서 고친다.

## 업데이트

같은 설치 명령을 다시 실행한다. 키트 소유 파일과 mattpocock 스킬만 바뀌고, 프로젝트 소유 파일은 그대로다. 특정 버전으로 고정하려면 `--ref v0.1.0`. 바뀐 것은 `git diff`로 보고 PR로 올린다.

옵션: `--ref <ref>`, `--no-skills`, `--no-github`, `--no-git-credential`, `--no-orca` (`bash install.sh --help`).

## 키트를 고칠 때

- 루프 스크립트를 고치면 `python3 docs/sync-guide.py && bash docs/build-pdf.sh`로 부록 D와 PDF를 다시 만든다(`tests/smoke.sh`가 부록 D 일치를 검사한다).
- `bash tests/smoke.sh` — 임시 저장소에 설치해 보고(네트워크·GitHub 없이), 두 번 설치해도 결과가 같은지 확인한다.
- 바뀐 점은 `CHANGELOG.md`에, 버전은 `VERSION`과 태그로.
