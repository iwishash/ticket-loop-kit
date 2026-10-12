#!/usr/bin/env node
'use strict';

// agent-loop-kit — npx 껍질. 질문을 받고 검증된 bash 설치기(install.sh)를 호출한다.
//
//   npx github:iwishash/agent-loop-kit init            대상 저장소 루트에서, 물어보며 설치
//   npx github:iwishash/agent-loop-kit init --yes      묻지 않고 기본값으로(비대화 환경에서는 자동)
//   npx github:iwishash/agent-loop-kit#v0.3.0 init     키트 버전 고정(태그·브랜치·커밋)
//
// Node 쪽이 맡는 것: 백엔드 선택, .agent-loop/loop.env의 BACKEND 줄, 설치 단계 켜고 끄기, 도구 점검.
// 파일 복사·병합·라벨·등록은 install.sh가 그대로 한다.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const PKG_ROOT = path.resolve(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8'));
const INSTALL_SH = path.join(PKG_ROOT, 'install.sh');
const LOOP_DIR = '.agent-loop';

const BACKENDS = {
  orca: { label: 'Orca', available: true, note: 'The Orca app manages worktrees and agent terminals' },
  cmux: { label: 'cmux', available: true, note: 'The loop creates git worktrees and starts the agent in a cmux workspace; run the loop inside a cmux terminal' },
};

const HELP = `agent-loop-kit ${pkg.version} — installer for the unattended ticket loop

Usage
  agent-loop-kit init [options]   Install or update in the target repo root (idempotent)
  agent-loop-kit --version
  agent-loop-kit --help

Options
  -y, --yes              Use defaults without asking (automatic when not a TTY)
  --backend <name>       ${Object.entries(BACKENDS).map(([k, b]) => `${k}${b.available ? '' : ' (coming soon)'}`).join(' | ')}  (default: orca)
  --no-skills            Skip syncing the mattpocock skills
  --no-github            Do not create the GitHub labels
  --no-git-credential    Leave the repo's git credential helper alone
  --no-orca              Skip registering the repo with Orca
  --ref <ref>            Kit ref to record in .agent-loop/kit.json (default: the #ref of the npx spec, else "npx")

Pin a kit version with a tag on the npx spec:  npx github:iwishash/agent-loop-kit#v0.3.0 init
Requires git, gh (logged in), jq, rsync and bash. The backend app (Orca or cmux) and Claude Code are needed to run the loop.
`;

// ---------- 색 ----------
// 터미널일 때만 칠하고, NO_COLOR(https://no-color.org)나 TERM=dumb 이면 끈다. 파이프로 받는 쪽은 맨글자만 본다.
const COLOR = process.stdout.isTTY && !process.env.NO_COLOR && process.env.TERM !== 'dumb';
const paint = (code) => (s) => (COLOR ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const c = { bold: paint(1), dim: paint(2), red: paint(31), green: paint(32), yellow: paint(33), blue: paint(34), cyan: paint(36), inv: paint(7) };
const say = (s) => console.log(`${c.green('▸')} ${c.bold(s)}`);
const warn = (s) => console.error(c.yellow(`! ${s}`));
const die = (s, code = 1) => { console.error(c.red(`✗ ${s}`)); process.exit(code); };

// ---------- 키보드로 고르는 프롬프트 ----------
// 의존성 없이 raw 모드로 키를 받는다. ↑↓/j/k 이동, 숫자로 바로 이동, Enter 확정, Space 토글(체크리스트), q·Esc·Ctrl+C 중단.
// 화면은 커서를 위로 올려 같은 자리에 다시 그린다. 터미널이 아니면 호출되지 않는다(--yes 와 같게 처리).
function readKeys(onKey) {
  const readline = require('readline');
  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true); process.stdin.resume();
  process.stdout.write('\x1b[?25l');   // 커서 숨김 — 끝나면 다시 보인다
  return new Promise((resolve) => {
    const done = (v) => { process.stdout.write('\x1b[?25h'); process.stdin.off('keypress', handler); process.stdin.setRawMode(false); process.stdin.pause(); resolve(v); };
    const handler = (str, key) => {
      if (key && key.ctrl && key.name === 'c') { process.stdout.write('\x1b[?25h\n'); process.exit(130); }
      const r = onKey(str, key || {});
      if (r !== undefined) done(r);
    };
    process.stdin.on('keypress', handler);
  });
}
// 보이는 폭으로 채운다 — 한글·한자는 2칸, 색 이스케이프는 0칸. 색은 채운 뒤에 입힌다
const vwidth = (s) => [...String(s).replace(/\x1b\[[0-9;]*m/g, '')].reduce((n, ch) => n + (/[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(ch) ? 2 : 1), 0);
const padv = (s, w) => s + ' '.repeat(Math.max(0, w - vwidth(s)));
// 다시 그리기 — 지운 뒤 다시 쓴다. 커서를 올리는 칸 수는 논리 줄이 아니라 터미널에서 차지한 실제 행 수다(긴 줄은 접혀 2행이 된다).
// 그래도 접히지 않게 각 줄을 터미널 폭 안으로 자르는 것이 먼저다(fit). 2026-10-12 실측: 좁은 창에서 제목 줄이 키마다 하나씩 쌓였다.
const columns = () => Math.max(20, process.stdout.columns || 80);
const rowsOf = (line) => Math.max(1, Math.ceil(vwidth(line) / columns()));
const redraw = (lines, prevRows) => {
  if (prevRows > 0) process.stdout.write(`\x1b[${prevRows}A\x1b[0J`);
  process.stdout.write(lines.join('\n') + '\n');
  return lines.reduce((n, l) => n + rowsOf(l), 0);
};
// 설명을 남은 폭에 맞게 자른다(한글 2칸). 잘리면 … 를 붙인다
const fit = (text, budget) => {
  if (budget <= 1) return '';
  if (vwidth(text) <= budget) return text;
  let out = '';
  for (const ch of [...text]) { if (vwidth(out + ch) > budget - 1) break; out += ch; }
  return out + '…';
};
const keyHint = (s) => c.dim(`  ${s}`);
const finalLine = (title, picked) => console.log(`${c.green('✔')} ${title} ${c.dim('›')} ${c.cyan(picked)}`);

// 하나 고르기. items: [{key, label, note, disabled}]. 반환: key. Esc/q 는 null.
async function select(title, items, initialKey) {
  let cur = Math.max(0, items.findIndex((it) => it.key === initialKey));
  let drawn = 0;
  const draw = () => {
    const lines = [c.bold(title)];
    items.forEach((it, i) => {
      const on = i === cur;
      const mark = on ? c.cyan('❯') : ' ';
      const cell = padv(it.label, Math.max(...items.map((x) => vwidth(x.label))) + 2);
      const label = on ? c.cyan(c.bold(cell)) : it.disabled ? c.dim(cell) : cell;
      const head = `  ${mark} ${c.dim(String(i + 1) + ')')} ${label}`;
      const tail = it.disabled ? ' (coming soon)' : '';
      lines.push(`${head}${c.dim(fit(it.note || '', columns() - vwidth(head) - vwidth(tail) - 1))}${it.disabled ? c.yellow(tail) : ''}`);
    });
    lines.push(keyHint('↑↓ move · number to jump · Enter confirm · q quit'));
    drawn = redraw(lines, drawn);
  };
  draw();
  const picked = await readKeys((str, key) => {
    if (key.name === 'up' || str === 'k') { cur = (cur - 1 + items.length) % items.length; draw(); return; }
    if (key.name === 'down' || str === 'j') { cur = (cur + 1) % items.length; draw(); return; }
    if (/^[1-9]$/.test(str || '') && Number(str) <= items.length) { cur = Number(str) - 1; draw(); return; }
    if (key.name === 'return') return items[cur].key;
    if (key.name === 'escape' || str === 'q') return null;
  });
  process.stdout.write(`\x1b[${drawn}A\x1b[0J`);
  if (picked !== null) finalLine(title, items[cur].label);
  return picked;
}

// 여러 개 켜고 끄기. items: [{key, label, note, on}]. 반환: {key: boolean}. Esc/q 는 null.
async function checklist(title, items) {
  const state = Object.fromEntries(items.map((it) => [it.key, it.on !== false]));
  let cur = 0, drawn = 0;
  const draw = () => {
    const lines = [c.bold(title)];
    items.forEach((it, i) => {
      const onRow = i === cur, checked = state[it.key];
      const box = checked ? c.green('◉') : c.dim('◯');
      const cell = padv(it.label, Math.max(...items.map((x) => vwidth(x.label))) + 2);
      const label = onRow ? c.cyan(c.bold(cell)) : checked ? cell : c.dim(cell);
      const head = `  ${onRow ? c.cyan('❯') : ' '} ${box} ${label}`;
      lines.push(`${head}${c.dim(fit(it.note || '', columns() - vwidth(head) - 1))}`);
    });
    lines.push(keyHint('↑↓ move · Space toggle · a all · n none · Enter confirm · q quit'));
    drawn = redraw(lines, drawn);
  };
  draw();
  const ok = await readKeys((str, key) => {
    if (key.name === 'up' || str === 'k') { cur = (cur - 1 + items.length) % items.length; draw(); return; }
    if (key.name === 'down' || str === 'j') { cur = (cur + 1) % items.length; draw(); return; }
    if (key.name === 'space') { state[items[cur].key] = !state[items[cur].key]; draw(); return; }
    if (str === 'a') { items.forEach((it) => { state[it.key] = true; }); draw(); return; }
    if (str === 'n') { items.forEach((it) => { state[it.key] = false; }); draw(); return; }
    if (/^[1-9]$/.test(str || '') && Number(str) <= items.length) { cur = Number(str) - 1; draw(); return; }
    if (key.name === 'return') return true;
    if (key.name === 'escape' || str === 'q') return false;
  });
  process.stdout.write(`\x1b[${drawn}A\x1b[0J`);
  if (!ok) return null;
  const onLabels = items.filter((it) => state[it.key]).map((it) => it.label);
  finalLine(title, onLabels.length ? onLabels.join(', ') : '(none)');
  return state;
}

function parseArgs(argv) {
  const o = { command: null, yes: false, backend: null, ref: null, skills: true, github: true, credential: true, orca: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case 'init': o.command = 'init'; break;
      case '-y': case '--yes': o.yes = true; break;
      case '--backend': o.backend = argv[++i]; break;
      case '--ref': o.ref = argv[++i]; break;
      case '--no-skills': o.skills = false; break;
      case '--no-github': o.github = false; break;
      case '--no-git-credential': o.credential = false; break;
      case '--no-orca': o.orca = false; break;
      case '-h': case '--help': o.command = 'help'; break;
      case '-v': case '--version': o.command = 'version'; break;
      default: die(`Unknown argument: ${a}\n\n${HELP}`, 2);
    }
    if ((a === '--backend' || a === '--ref') && o[a.slice(2)] == null) die(`${a} needs a value.`, 2);
  }
  return o;
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts });
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim(), status: r.status };
}
const has = (tool) => run(process.platform === 'win32' ? 'where' : 'which', [tool]).ok;


// npx가 git에서 받은 패키지에는 .git이 없다. 커밋은 npx 캐시의 package-lock.json("resolved": "git+…#<sha>")에,
// 사용자가 준 ref(npx github:…#v0.3.0)는 같은 자리의 package.json dependencies 스펙에 남는다.
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const NPX_DIR = path.resolve(PKG_ROOT, '..', '..');
function kitCommit() {
  if (pkg.gitHead) return pkg.gitHead;
  const lock = readJson(path.join(NPX_DIR, 'package-lock.json'));
  const resolved = lock && lock.packages && lock.packages[`node_modules/${pkg.name}`] && lock.packages[`node_modules/${pkg.name}`].resolved;
  const m = resolved && String(resolved).match(/#([0-9a-f]{40})$/);
  if (m) return m[1];
  const r = run('git', ['-C', PKG_ROOT, 'rev-parse', 'HEAD']); // 키트를 clone해 두고 직접 실행할 때
  return r.ok ? r.out : 'unknown';
}
function kitRef() {
  const top = readJson(path.join(NPX_DIR, 'package.json'));
  const spec = top && top.dependencies && top.dependencies[pkg.name];
  const m = spec && String(spec).match(/#(.+)$/);
  if (m) return `npx#${m[1]}`;
  if (spec) return 'npx';
  return 'local';
}

// .agent-loop/loop.env — 없으면 만들고, 있으면 BACKEND 줄만 없을 때 덧붙인다(프로젝트 소유 파일이라 나머지는 건드리지 않는다)
function writeLoopEnv(root, backend) {
  const dir = path.join(root, LOOP_DIR);
  const file = path.join(dir, 'loop.env');
  const line = `BACKEND="\${BACKEND:-${backend}}"`;
  if (!fs.existsSync(file)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, [
      '# agent-loop-kit — 이 저장소의 티켓 루프 기본값. ticket-loop.sh가 시작할 때 읽는다.',
      '# VAR="${VAR:-값}" 꼴로 적어 두면 실행할 때 준 환경변수가 이긴다. 나머지 값(CI_SKIP_REGEX, POST_MERGE_CMD,',
      '# POST_MERGE_PORT …)은 /setup-agent-loop 가 저장소를 읽고 채운다.',
      `# 백엔드: ${Object.keys(BACKENDS).join(' | ')}`,
      line,
      ...(backend === 'cmux' ? [
        '# cmux는 orca.yaml setup 대신 이 명령으로 새 워크트리를 준비한다(의존성 설치·env 복사). LOOP_ROOT_PATH, LOOP_WORKTREE_PATH 사용 가능',
        '# WORKTREE_SETUP_CMD="${WORKTREE_SETUP_CMD:-pnpm install}"',
      ] : []),
      '',
    ].join('\n'));
    return `Created ${LOOP_DIR}/loop.env (BACKEND=${backend})`;
  }
  const text = fs.readFileSync(file, 'utf8');
  const m = text.match(/^\s*BACKEND=["']?\$\{BACKEND:-([a-z]+)\}["']?\s*$/m) || text.match(/^\s*BACKEND=["']?([a-z]+)["']?\s*$/m);
  if (!m) {
    fs.appendFileSync(file, `${text.endsWith('\n') || text === '' ? '' : '\n'}# 백엔드: ${Object.keys(BACKENDS).join(' | ')}\n${line}\n`);
    return `Added BACKEND=${backend} to ${LOOP_DIR}/loop.env`;
  }
  if (m[1] !== backend) warn(`Keeping BACKEND=${m[1]} in ${LOOP_DIR}/loop.env (differs from the selected ${backend} — edit the file to change it).`);
  return `Kept ${LOOP_DIR}/loop.env (BACKEND=${m[1]})`;
}

async function init(o) {
  if (process.platform === 'win32') die('Windows is not supported (the installer is bash). Run it under WSL.');
  if (!fs.existsSync(INSTALL_SH)) die(`Kit package is incomplete: ${INSTALL_SH} is missing`);
  for (const t of ['git', 'bash', 'jq']) if (!has(t)) die(`${t} is not installed.`);

  const top = run('git', ['rev-parse', '--show-toplevel']);
  if (!top.ok) die('Run this inside a git repository.');
  const root = top.out;
  if (path.resolve(process.cwd()) !== path.resolve(root)) warn(`Installing into the repository root (${root}).`);

  const interactive = !o.yes && process.stdin.isTTY && process.stdout.isTTY;
  const commit = kitCommit();
  const prev = readJson(path.join(root, LOOP_DIR, 'kit.json')) || readJson(path.join(root, '.orca-loop', 'kit.json'));
  say(`agent-loop-kit ${c.cyan(pkg.version)} ${c.dim(`(${commit.slice(0, 7)})`)} → ${root}`);
  if (prev) console.log(c.dim(`  currently installed: ${prev.version || '?'} (${String(prev.commit || '').slice(0, 7)}, ${prev.installed_at || '?'}) — updating`));

  if (!has('gh')) warn('gh is not installed: labels, credential and Orca registration will be skipped, and the loop itself needs gh.');
  else if (!run('gh', ['auth', 'status']).ok) warn('gh is not logged in (gh auth login).');
  if (!has('rsync')) warn('rsync is not installed: the mattpocock skill sync will be skipped.');

  // 백엔드
  let backend = o.backend;
  if (backend && !BACKENDS[backend]) die(`Unknown backend ${backend}. Choose one of: ${Object.keys(BACKENDS).join(', ')}`);
  if (interactive && !backend) {
    console.log('');
    backend = await select('Backend — who manages worktrees and agent terminals?',
      Object.entries(BACKENDS).map(([key, b]) => ({ key, label: b.label, note: b.note, disabled: !b.available })), 'orca');
    if (backend === null) { console.log(c.dim('Aborted.')); process.exit(130); }
  }
  backend = backend || 'orca';
  if (!BACKENDS[backend].available) die(`The ${BACKENDS[backend].label} backend is not available yet. ${BACKENDS[backend].note}.`);

  // origin 이 실제로 쓰는 주소 — ls-remote --get-url 은 insteadOf 규칙까지 적용한 값을 준다. SSH 면 gh 토큰 단계는 쓰이지 않는다
  const originUrl = run('git', ['ls-remote', '--get-url', 'origin']).out;
  const sshRemote = /^(git@|ssh:\/\/|git\+ssh:\/\/)|^[^/]+@[^:]+:/.test(originUrl);
  if (sshRemote && o.credential && !o.yes) o.credential = false;   // 기본값만 끈다. --yes 는 install.sh 가 알아서 한다(SSH 면 설정해도 무해)

  // 설치 단계 — Enter 만 치면 기본값
  if (interactive) {
    const items = [
      { key: 'skills', label: 'Vendor the mattpocock skills', note: 'copy 26 skills into .claude/skills/ at the pinned upstream version — overwrites vendored ones, leaves implement·pr alone', on: o.skills },
      { key: 'github', label: 'Create the 6 GitHub labels', note: 'ready-for-agent · in-review …', on: o.github },
      { key: 'credential', label: 'Use the gh token for git push',
        note: sshRemote ? 'SSH remote detected — not needed (default off)' : 'this repo only; keeps unattended HTTPS push from waiting on the keychain', on: o.credential },
    ];
    if (backend === 'orca') items.push({ key: 'orca', label: 'Register the repo with Orca', note: 'skipped if already registered', on: o.orca });
    const picked = await checklist('Install steps', items);
    if (picked === null) { console.log(c.dim('Aborted.')); process.exit(130); }
    Object.assign(o, picked);
  }
  if (backend !== 'orca') o.orca = false;

  console.log('');
  say(`Backend: ${c.cyan(BACKENDS[backend].label)}`);

  // install.sh 가 먼저 돈다 — 옛 .orca-loop/ 를 .agent-loop/ 로 옮기는 마이그레이션이 거기 있어서, loop.env 는 그 뒤에 쓴다
  const args = [INSTALL_SH, '--ref', o.ref || kitRef()];
  if (!o.skills) args.push('--no-skills');
  if (!o.github) args.push('--no-github');
  if (!o.credential) args.push('--no-git-credential');
  if (!o.orca) args.push('--no-orca');
  const r = spawnSync('bash', args, { cwd: root, stdio: 'inherit', env: { ...process.env, KIT_DIR: PKG_ROOT, KIT_COMMIT: commit } });
  if (r.error) die(`Failed to run install.sh: ${r.error.message}`);
  if (r.status !== 0) process.exit(r.status == null ? 1 : r.status);
  say(writeLoopEnv(root, backend));
}

(async () => {
  const o = parseArgs(process.argv.slice(2));
  if (o.command === 'version') { console.log(pkg.version); return; }
  if (o.command === 'init') { await init(o); return; }
  process.stdout.write(HELP);
  if (o.command !== 'help') process.exit(2);
})().catch((e) => {
  if (e && e.name === 'AbortError') { console.log('\nAborted.'); process.exit(130); } // 프롬프트에서 Ctrl+D
  die(e && e.stack ? e.stack : String(e));
});
