#!/usr/bin/env node
'use strict';

// agent-loop-kit — npx 껍질. 질문을 받고 검증된 bash 설치기(install.sh)를 호출한다.
//
//   npx github:iwishash/agent-loop-kit init            대상 저장소 루트에서, 물어보며 설치
//   npx github:iwishash/agent-loop-kit init --yes      묻지 않고 기본값으로(비대화 환경에서는 자동)
//   npx github:iwishash/agent-loop-kit#v0.3.0 init     키트 버전 고정(태그·브랜치·커밋)
//
// Node 쪽이 맡는 것: 백엔드 선택, .orca-loop/loop.env의 BACKEND 줄, 설치 단계 켜고 끄기, 도구 점검.
// 파일 복사·병합·라벨·등록은 install.sh가 그대로 한다.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const PKG_ROOT = path.resolve(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8'));
const INSTALL_SH = path.join(PKG_ROOT, 'install.sh');
const LOOP_DIR = '.orca-loop';

const BACKENDS = {
  orca: { label: 'Orca', available: true, note: '워크트리·터미널을 Orca 앱이 관리한다' },
  cmux: { label: 'cmux', available: false, note: 'ticket-loop.sh의 백엔드 분리 뒤 지원' },
};

const HELP = `agent-loop-kit ${pkg.version} — 티켓 무인 루프 설치 키트

사용법
  agent-loop-kit init [옵션]     대상 저장소 루트에서 설치·업데이트 (여러 번 실행해도 결과가 같다)
  agent-loop-kit --version
  agent-loop-kit --help

옵션
  -y, --yes              묻지 않고 기본값으로 진행 (터미널이 아니면 자동)
  --backend <이름>        ${Object.entries(BACKENDS).map(([k, b]) => `${k}${b.available ? '' : '(준비 중)'}`).join(' | ')}  (기본 orca)
  --no-skills            mattpocock 스킬 동기화를 건너뛴다
  --no-github            GitHub 라벨을 만들지 않는다
  --no-git-credential    저장소 git 자격 증명을 바꾸지 않는다
  --no-orca              Orca 저장소 등록을 건너뛴다
  --ref <ref>            .orca-loop/kit.json에 남길 키트 ref 표시 (기본: npx 스펙의 #ref, 없으면 npx)

키트 버전을 고정하려면 npx 쪽에 태그를 붙인다:  npx github:iwishash/agent-loop-kit#v0.3.0 init
필요한 도구: git, gh(로그인), jq, rsync, bash. 백엔드 앱(Orca)과 Claude Code는 루프를 돌릴 때 필요하다.
`;

const bold = (s) => (process.stdout.isTTY ? `\x1b[1m${s}\x1b[0m` : s);
const say = (s) => console.log(bold(`▸ ${s}`));
const warn = (s) => console.error(process.stderr.isTTY ? `\x1b[33m! ${s}\x1b[0m` : `! ${s}`);
const die = (s, code = 1) => { console.error(process.stderr.isTTY ? `\x1b[31m✗ ${s}\x1b[0m` : `✗ ${s}`); process.exit(code); };

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
      default: die(`알 수 없는 인자: ${a}\n\n${HELP}`, 2);
    }
    if ((a === '--backend' || a === '--ref') && o[a.slice(2)] == null) die(`${a} 에 값이 필요합니다.`, 2);
  }
  return o;
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts });
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim(), status: r.status };
}
const has = (tool) => run(process.platform === 'win32' ? 'where' : 'which', [tool]).ok;

async function ask(rl, q, def) {
  const a = (await rl.question(q)).trim();
  return a === '' ? def : a;
}
async function askYesNo(rl, q, def = true) {
  for (;;) {
    const a = (await ask(rl, `${q} [${def ? 'Y/n' : 'y/N'}] `, def ? 'y' : 'n')).toLowerCase();
    if (['y', 'yes', '예', 'ㅇ'].includes(a)) return true;
    if (['n', 'no', '아니오', '아니요', 'ㄴ'].includes(a)) return false;
  }
}

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

// .orca-loop/loop.env — 없으면 만들고, 있으면 BACKEND 줄만 없을 때 덧붙인다(프로젝트 소유 파일이라 나머지는 건드리지 않는다)
function writeLoopEnv(root, backend) {
  const dir = path.join(root, LOOP_DIR);
  const file = path.join(dir, 'loop.env');
  const line = `BACKEND="\${BACKEND:-${backend}}"`;
  if (!fs.existsSync(file)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, [
      '# agent-loop-kit — 이 저장소의 티켓 루프 기본값. ticket-loop.sh가 시작할 때 읽는다.',
      '# VAR="${VAR:-값}" 꼴로 적어 두면 실행할 때 준 환경변수가 이긴다. 나머지 값(CI_SKIP_REGEX, POST_MERGE_CMD,',
      '# POST_MERGE_PORT …)은 /setup-orca-loop 가 저장소를 읽고 채운다.',
      `# 백엔드: ${Object.keys(BACKENDS).join(' | ')}`,
      line,
      '',
    ].join('\n'));
    return `${LOOP_DIR}/loop.env 생성 (BACKEND=${backend})`;
  }
  const text = fs.readFileSync(file, 'utf8');
  const m = text.match(/^\s*BACKEND=["']?\$\{BACKEND:-([a-z]+)\}["']?\s*$/m) || text.match(/^\s*BACKEND=["']?([a-z]+)["']?\s*$/m);
  if (!m) {
    fs.appendFileSync(file, `${text.endsWith('\n') || text === '' ? '' : '\n'}# 백엔드: ${Object.keys(BACKENDS).join(' | ')}\n${line}\n`);
    return `${LOOP_DIR}/loop.env 에 BACKEND=${backend} 줄 추가`;
  }
  if (m[1] !== backend) warn(`${LOOP_DIR}/loop.env 의 BACKEND=${m[1]} 를 그대로 둡니다 (선택한 ${backend} 와 다릅니다 — 바꾸려면 직접 고치세요).`);
  return `${LOOP_DIR}/loop.env 유지 (BACKEND=${m[1]})`;
}

async function init(o) {
  if (process.platform === 'win32') die('Windows는 지원하지 않습니다 (bash 설치기를 씁니다). WSL에서 실행하세요.');
  if (!fs.existsSync(INSTALL_SH)) die(`키트 패키지가 온전하지 않습니다: ${INSTALL_SH} 없음`);
  for (const t of ['git', 'bash', 'jq']) if (!has(t)) die(`${t} 이(가) 없습니다.`);

  const top = run('git', ['rev-parse', '--show-toplevel']);
  if (!top.ok) die('git 저장소 안에서 실행하세요.');
  const root = top.out;
  if (path.resolve(process.cwd()) !== path.resolve(root)) warn(`저장소 루트(${root})에 설치합니다.`);

  const interactive = !o.yes && process.stdin.isTTY && process.stdout.isTTY;
  const commit = kitCommit();
  const prev = (() => { try { return JSON.parse(fs.readFileSync(path.join(root, LOOP_DIR, 'kit.json'), 'utf8')); } catch { return null; } })();
  say(`agent-loop-kit ${pkg.version} (${commit.slice(0, 7)}) → ${root}`);
  if (prev) console.log(`  현재 설치: ${prev.version || '?'} (${String(prev.commit || '').slice(0, 7)}, ${prev.installed_at || '?'}) — 업데이트`);

  if (!has('gh')) warn('gh가 없습니다. 라벨·자격 증명·Orca 등록이 건너뛰어지고, 루프 실행에도 gh가 필요합니다.');
  else if (!run('gh', ['auth', 'status']).ok) warn('gh가 로그인돼 있지 않습니다 (gh auth login).');
  if (!has('rsync')) warn('rsync가 없어 mattpocock 스킬 동기화를 건너뜁니다.');

  // 백엔드
  let backend = o.backend;
  if (backend && !BACKENDS[backend]) die(`백엔드 ${backend} 를 모릅니다. 가능: ${Object.keys(BACKENDS).join(', ')}`);
  let rl = null;
  if (interactive) {
    rl = require('readline/promises').createInterface({ input: process.stdin, output: process.stdout });
    if (!backend) {
      const keys = Object.keys(BACKENDS);
      console.log('\n백엔드 — 워크트리와 에이전트 터미널을 누가 관리하나');
      keys.forEach((k, i) => console.log(`  ${i + 1}) ${BACKENDS[k].label.padEnd(6)} ${BACKENDS[k].note}${BACKENDS[k].available ? '' : ' (준비 중)'}`));
      for (;;) {
        const a = await ask(rl, '선택 [1]: ', '1');
        const k = keys[Number(a) - 1] || (BACKENDS[a] ? a : null);
        if (k) { backend = k; break; }
      }
    }
  }
  backend = backend || 'orca';
  if (!BACKENDS[backend].available) { rl && rl.close(); die(`${BACKENDS[backend].label} 백엔드는 아직 없습니다. ${BACKENDS[backend].note}.`); }

  // 설치 단계
  if (rl) {
    console.log('');
    if (!(await askYesNo(rl, '기본 설정으로 설치할까요? (스킬 동기화, GitHub 라벨, gh 자격 증명, 백엔드 등록)'))) {
      o.skills = await askYesNo(rl, '  mattpocock 스킬을 .claude/skills/에 벤더링', o.skills);
      o.github = await askYesNo(rl, '  GitHub 라벨 6개 만들기', o.github);
      o.credential = await askYesNo(rl, '  이 저장소의 git push가 gh 토큰을 쓰게 하기', o.credential);
      if (backend === 'orca') o.orca = await askYesNo(rl, '  Orca에 저장소 등록', o.orca);
    }
    rl.close();
  }
  if (backend !== 'orca') o.orca = false;

  console.log('');
  say(`백엔드 ${BACKENDS[backend].label}`);
  console.log(`  ${writeLoopEnv(root, backend)}`);

  const args = [INSTALL_SH, '--ref', o.ref || kitRef()];
  if (!o.skills) args.push('--no-skills');
  if (!o.github) args.push('--no-github');
  if (!o.credential) args.push('--no-git-credential');
  if (!o.orca) args.push('--no-orca');
  const r = spawnSync('bash', args, { cwd: root, stdio: 'inherit', env: { ...process.env, KIT_DIR: PKG_ROOT, KIT_COMMIT: commit } });
  if (r.error) die(`install.sh 실행 실패: ${r.error.message}`);
  process.exit(r.status == null ? 1 : r.status);
}

(async () => {
  const o = parseArgs(process.argv.slice(2));
  if (o.command === 'version') { console.log(pkg.version); return; }
  if (o.command === 'init') { await init(o); return; }
  process.stdout.write(HELP);
  if (o.command !== 'help') process.exit(2);
})().catch((e) => {
  if (e && e.name === 'AbortError') { console.log('\n중단했습니다.'); process.exit(130); } // 프롬프트에서 Ctrl+D
  die(e && e.stack ? e.stack : String(e));
});
