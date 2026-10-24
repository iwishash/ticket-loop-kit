# 키트를 고칠 때

[README](README.ko.md) · [English](CONTRIBUTING.md)

- 루프 스크립트를 고치면 `python3 docs/sync-guide.py && bash docs/build-pdf.sh`로 부록 D와 PDF를 다시 만든다(`tests/smoke.sh`가 부록 D 일치를 검사한다).
- `bash tests/smoke.sh`는 네트워크 없이 임시 저장소에 설치하고, 두 번 설치해도 같은지, 스펙 리포트가 고정 자료로 그려지는지 확인한다.
- 바뀐 점은 `CHANGELOG.md`에, 버전은 `VERSION`·`package.json`과 태그로.
- `package.json`에 `prepare` 같은 빌드 단계를 두지 않는다. git에서 바로 받으면 사용자 PC에서 돈다. npx 패키지에는 `files` 목록만 들어가고 `docs/`·`tests/`는 빠진다.
