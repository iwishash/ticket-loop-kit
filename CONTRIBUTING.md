# Working on the kit

[README](README.md) · [한국어](CONTRIBUTING.ko.md)

- After changing the loop script, regenerate Appendix D and the PDF: `python3 docs/sync-guide.py && bash docs/build-pdf.sh` (`tests/smoke.sh` checks that Appendix D matches).
- `bash tests/smoke.sh` installs into a temporary repository without network, checks that installing twice is idempotent, and renders the spec report against fixtures.
- Record changes in `CHANGELOG.md`; the version goes in `VERSION`, `package.json`, and a tag.
- Do not add a build step such as `prepare` to `package.json`; fetched straight from git, it would run on the user's machine. The npx package contains only the `files` list; `docs/` and `tests/` are excluded.
