'use strict';
// `polestar fork`: build, check and install Polestar Plus, the fork's renamed
// copy of the addon that loads beside Polestar (FORK.md, tools/lib/fork/rebrand.js).

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const R = require('../lib/fork/rebrand');

const ROOT = path.join(__dirname, '..', '..');
const DEFAULT_OUT = path.join(ROOT, 'dist', 'fork', 'AddOns');

const usage = `polestar fork build [--data <release zip | folder with Polestar_QuestDB and Polestar_Codex>] [--out <dir>]
polestar fork check [--out <dir>] [--against <AddOns folder holding Polestar>] [--no-luajit]
polestar fork install --to <AddOns folder> [--out <dir>]

  build    renames addon/ (the files git tracks or would add) and the data folders
           git lacks (Polestar_QuestDB, Polestar_Codex: from --data, an upstream
           release) into ${path.relative(ROOT, DEFAULT_OUT)}, as ${R.BRAND.name} (${R.BRAND.token}*)
  check    fails on a leftover Polestar name in the built code, and, with --against,
           on any folder, SavedVariable, slash command, binding, frame, popup,
           addon-message prefix or global that both installs claim
  install  replaces the ${R.BRAND.token}* folders in --to with the built ones; never
           touches another folder`;

function arg(argv, name) {
	const i = argv.indexOf(name);
	return i >= 0 ? argv[i + 1] : undefined;
}

function tracked(name) {
	const out = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', `addon/${name}`], { cwd: ROOT, encoding: 'utf8', maxBuffer: 256 << 20 });
	return out.split('\0').filter(Boolean).map((p) => path.relative(path.join('addon', name), p)).filter((p) => fs.existsSync(path.join(ROOT, 'addon', name, p)));
}

function dataDir(data) {
	if (!data) return undefined;
	const abs = path.resolve(data);
	if (!abs.endsWith('.zip')) return abs;
	const dir = path.join(ROOT, 'dist', 'fork', 'release');
	fs.rmSync(dir, { recursive: true, force: true });
	fs.mkdirSync(dir, { recursive: true });
	execFileSync('unzip', ['-q', abs, '-d', dir]);
	return dir;
}

function which(cmd) {
	try {
		return execFileSync('sh', ['-c', `command -v ${cmd}`], { encoding: 'utf8' }).trim() || undefined;
	} catch {
		return undefined;
	}
}

function built(out) {
	if (!fs.existsSync(out)) return [];
	return fs.readdirSync(out).filter((n) => n.startsWith(R.BRAND.token) && fs.statSync(path.join(out, n)).isDirectory()).sort();
}

function build(argv) {
	const out = path.resolve(arg(argv, '--out') || DEFAULT_OUT);
	const data = dataDir(arg(argv, '--data'));
	const folders = R.build({ addonDir: path.join(ROOT, 'addon'), dataDir: data, outDir: out, root: ROOT, tracked, log: (m) => console.log(m) });
	for (const need of ['QuestDB', 'Codex']) {
		if (!folders.includes(`${R.BRAND.token}_${need}`)) console.log(`note: no ${R.BRAND.token}_${need} (pass --data with an upstream release that has Polestar_${need})`);
	}
	return 0;
}

function check(argv) {
	const out = path.resolve(arg(argv, '--out') || DEFAULT_OUT);
	const mine = built(out);
	if (mine.length === 0) {
		console.error(`nothing built in ${out}: run polestar fork build first`);
		return 1;
	}
	let failed = false;
	const left = R.leftovers(out);
	if (left.length) {
		failed = true;
		console.log(`${left.length} leftover Polestar names:`);
		for (const l of left.slice(0, 40)) console.log(`  ${l.file}:${l.line}  ${l.text}`);
	} else {
		console.log(`no leftover Polestar names in ${mine.length} folders`);
	}
	const against = arg(argv, '--against');
	if (against) {
		const luajit = argv.includes('--no-luajit') ? undefined : which('luajit');
		const theirs = fs.readdirSync(against).filter((n) => /^Polestar(_|$)/.test(n) && !n.startsWith(R.BRAND.token));
		const a = R.claims(against, theirs, { luajit });
		const b = R.claims(out, mine, { luajit });
		const { real: both, guarded } = R.split(R.collisions(a, b));
		const kinds = Object.keys(both);
		for (const [k, list] of Object.entries(guarded)) console.log(`  ${k} ${list.join(', ')}: in both, taken at run time by whichever loads first (Polestar)`);
		console.log(`Polestar claims: ${Object.entries(a).map(([k, v]) => `${v.size} ${k}`).join(', ')}`);
		console.log(`${R.BRAND.name} claims: ${Object.entries(b).map(([k, v]) => `${v.size} ${k}`).join(', ')}${luajit ? '' : ' (no LuaJIT: globals not read)'}`);
		if (kinds.length) {
			failed = true;
			for (const k of kinds) console.log(`  shared ${k}: ${both[k].slice(0, 30).join(', ')}${both[k].length > 30 ? ', ...' : ''}`);
		} else {
			console.log('no collisions');
		}
	}
	return failed ? 1 : 0;
}

function install(argv) {
	const out = path.resolve(arg(argv, '--out') || DEFAULT_OUT);
	const to = arg(argv, '--to');
	if (!to) {
		console.error('install needs --to <AddOns folder>');
		return 2;
	}
	const mine = built(out);
	if (mine.length === 0) {
		console.error(`nothing built in ${out}: run polestar fork build first`);
		return 1;
	}
	fs.mkdirSync(to, { recursive: true });
	for (const name of fs.readdirSync(to)) {
		if (name.startsWith(R.BRAND.token)) fs.rmSync(path.join(to, name), { recursive: true, force: true });
	}
	for (const name of mine) fs.cpSync(path.join(out, name), path.join(to, name), { recursive: true });
	console.log(`installed ${mine.length} ${R.BRAND.token} folders into ${to}`);
	return 0;
}

function run(argv) {
	const [sub, ...rest] = argv;
	if (sub === 'build') return build(rest);
	if (sub === 'check') return check(rest);
	if (sub === 'install') return install(rest);
	console.error(usage);
	return 2;
}

module.exports = { name: 'fork', summary: `build, check and install ${R.BRAND.name}, the side-by-side fork`, usage, run };
