'use strict';
// Polestar Plus: the fork's build step. Takes Polestar's addon folders (the
// repository's addon/ tree, with the generated data folders git does not hold
// taken from an upstream release) and writes copies renamed so that they load
// beside an unchanged Polestar install: every folder, TOC, global, frame,
// SavedVariable, slash command, binding, popup, addon-message prefix and
// sibling-folder name moves from "Polestar" to "PolestarPlus" (FORK.md).
//
// The rename is text rules over each file, never hand edits, so a merge of
// upstream's `next` needs nothing redone:
//
//   1. tokens (code, comments and strings alike)
//        Polestar...   -> PolestarPlus...   when not inside another identifier
//                                            (|cAARRGGBB colour codes count as a boundary)
//        ...POLESTAR... -> ...POLESTARPLUS... (SLASH_, BINDING_NAME_, popups, events)
//        polestar_x     -> polestarplus_x    (bag addon widget ids)
//        /polestar      -> /psf              (the slash command, in help texts too)
//   2. display (inside Lua string literals that hold a space, and TOC
//      Title/Notes/Category/Author lines): "PolestarPlus" read as a word
//      becomes "Polestar Plus", and the house colour before it the fork's.
//
// Lowercase values ("polestar" the skin key, polestar.guide, the Discord and
// GitHub links) are not names the client shares between addons and stay.

const fs = require('node:fs');
const path = require('node:path');

const BRAND = {
	name: 'Polestar Plus',
	token: 'PolestarPlus',
	upper: 'POLESTARPLUS',
	lower: 'polestarplus',
	slash: ['/psf', '/polestarplus', '/psplus'],
	colour: 'ffb347', // the fork's accent in chat and the AddOns list (Polestar's is 4fd1c5)
	website: 'https://github.com/vitoc82-se/polestar',
};

// Release folders the fork leaves out: the Recorder ships in its own zip and
// writes upstream's recordings; the Arcade's globals (FreedoomArcade*) are
// its own, not Polestar-named, and Polestar's copy of it already provides them;
// the example skin is not part of a release.
const EXCLUDE = new Set(['Polestar_Recorder', 'Polestar_Arcade', 'Polestar_Skin_Example']);

const TEXT = new Set(['.lua', '.xml', '.toc']);

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

const ID = /[A-Za-z0-9_]/;

function tokens(text) {
	let s = text;
	// A colour code runs straight into the word: |cff4fd1c5Polestar|r.
	s = s.replace(/(\|c[0-9a-fA-F]{8})Polestar(?!Plus)/g, `$1${BRAND.token}`);
	s = s.replace(/(^|[^A-Za-z0-9_])Polestar(?!Plus)/g, `$1${BRAND.token}`);
	s = s.replace(/POLESTAR(?!PLUS)/g, BRAND.upper);
	s = s.replace(/(^|[^A-Za-z0-9_])polestar_(?=[a-z])/g, `$1${BRAND.lower}_`);
	// The slash command, never a path or a link (fitzforge/polestar, discord.gg/polestar).
	s = s.replace(/(^|[^A-Za-z0-9_./-])\/polestar(?![A-Za-z0-9_])/g, `$1${BRAND.slash[0]}`);
	return s;
}

// Polestar's own slash aliases, which would shadow the original's.
function slashAliases(text) {
	return text
		.replace(new RegExp(`(SLASH_${BRAND.upper}2\\s*=\\s*)"/pole"`), `$1"${BRAND.slash[1]}"`)
		.replace(new RegExp(`(SLASH_${BRAND.upper}3\\s*=\\s*)"/ps"`), `$1"${BRAND.slash[2]}"`);
}

const WORD_END = `(?=[\\s'\u2019:.,;!?)\\-|%"\u00bb\u201c\u201d\u3000\uff1a]|$)`;
const DISPLAY = new RegExp(`${BRAND.token}${WORD_END}`, 'g');
const DISPLAY_UPPER = new RegExp(`${BRAND.upper}${WORD_END}`, 'g');

function display(s) {
	if (!/\s/.test(s)) return s;
	return s
		.replace(DISPLAY, BRAND.name)
		.replace(DISPLAY_UPPER, BRAND.name.toUpperCase())
		.replace(new RegExp(`\\|cff4fd1c5${BRAND.name}`, 'g'), `|cff${BRAND.colour}${BRAND.name}`);
}

// Lua source -> the same with display() applied to each string literal's body
// (short strings with their escapes, and long brackets), comments untouched.
function luaStrings(src, fn) {
	let out = '';
	let i = 0;
	const n = src.length;
	let last = 0;
	const longOpen = (at) => {
		// [[ or [=*[ at `at` -> level, or -1
		if (src[at] !== '[') return -1;
		let j = at + 1;
		let level = 0;
		while (src[j] === '=') { level++; j++; }
		return src[j] === '[' ? level : -1;
	};
	const longEnd = (from, level) => {
		const close = ']' + '='.repeat(level) + ']';
		const k = src.indexOf(close, from);
		return k < 0 ? n : k;
	};
	while (i < n) {
		const c = src[i];
		if (c === '-' && src[i + 1] === '-') {
			const lv = longOpen(i + 2);
			if (lv >= 0) {
				const end = longEnd(i + 4 + lv, lv);
				i = Math.min(n, end + 2 + lv);
			} else {
				const nl = src.indexOf('\n', i);
				i = nl < 0 ? n : nl;
			}
			continue;
		}
		if (c === '"' || c === "'") {
			let j = i + 1;
			while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
			out += src.slice(last, i + 1) + fn(src.slice(i + 1, j));
			last = j;
			i = j + 1;
			continue;
		}
		if (c === '[') {
			const lv = longOpen(i);
			if (lv >= 0) {
				const start = i + 2 + lv;
				const end = longEnd(start, lv);
				out += src.slice(last, start) + fn(src.slice(start, end));
				last = end;
				i = end + 2 + lv;
				continue;
			}
		}
		i++;
	}
	return out + src.slice(last);
}

const TOC_DISPLAY = /^(## (?:Title|Notes|Category|Author)(?:-[a-zA-Z]{4})?:)(.*)$/;

function toc(text, folder) {
	const lines = text.split(/\r?\n/);
	const out = [];
	let website = false;
	for (let line of lines) {
		const m = TOC_DISPLAY.exec(line);
		if (m) {
			const key = m[1];
			let value = m[2].replace(DISPLAY, BRAND.name).replace(new RegExp(`${BRAND.token}$`), BRAND.name);
			if (/^## Title:/.test(key) && folder === BRAND.token) value = ` |cff${BRAND.colour}${BRAND.name}|r`;
			else if (/^## Title/.test(key) && !value.includes(BRAND.name)) value = ` ${BRAND.name}:${value}`;
			if (/^## Author:/.test(key)) value = ` ${BRAND.name} (a fork of Polestar by the Polestar authors)`;
			line = key + value;
		}
		if (/^## X-Website:/.test(line)) {
			line = `## X-Website: ${BRAND.website}`;
			website = true;
		}
		out.push(line);
	}
	if (folder === BRAND.token) {
		const at = out.findIndex((l) => /^## Version:/.test(l));
		out.splice(at < 0 ? 1 : at + 1, 0, `## X-Fork: ${BRAND.name}, a fork of Polestar (https://github.com/fitzforge/polestar), GPL-3.0`);
		if (!website) out.splice(1, 0, `## X-Website: ${BRAND.website}`);
	}
	return out.join('\n');
}

function rebrandFile(rel, text) {
	const ext = path.extname(rel).toLowerCase();
	let s = tokens(text);
	if (ext === '.lua') s = slashAliases(luaStrings(s, display));
	if (ext === '.toc') s = toc(s, rel.split(/[\\/]/)[0]);
	return s;
}

// "Polestar_Guides" -> "PolestarPlus_Guides"
function folderName(name) {
	return tokens(name);
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

function walk(dir, base = dir, out = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		if (e.name === '.DS_Store') continue;
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, base, out);
		else if (e.isFile()) out.push(path.relative(base, p));
	}
	return out;
}

// The folders to build: every Polestar folder of `addonDir` (only the files git
// tracks when `tracked` is given), then those `dataDir` has and addonDir lacks
// (Polestar_QuestDB, Polestar_Codex: generated, not in git).
function sources({ addonDir, dataDir, tracked }) {
	const folders = new Map(); // name -> { dir, files }
	const add = (dir, name, files) => {
		if (EXCLUDE.has(name) || folders.has(name)) return;
		if (!files.some((f) => f === `${name}.toc`)) return;
		folders.set(name, { dir: path.join(dir, name), files });
	};
	for (const name of fs.readdirSync(addonDir).sort()) {
		if (!/^Polestar(_|$)/.test(name) || !fs.statSync(path.join(addonDir, name)).isDirectory()) continue;
		const files = tracked ? tracked(name) : walk(path.join(addonDir, name));
		add(addonDir, name, files);
	}
	if (dataDir) {
		for (const name of fs.readdirSync(dataDir).sort()) {
			if (!/^Polestar(_|$)/.test(name) || !fs.statSync(path.join(dataDir, name)).isDirectory()) continue;
			add(dataDir, name, walk(path.join(dataDir, name)));
		}
	}
	return folders;
}

// The release's player files that git keeps elsewhere: Polestar's LICENSE.
function extras(root) {
	return { Polestar: { LICENSE: path.join(root, 'LICENSE'), 'LICENSE-EXCEPTION.md': path.join(root, 'LICENSE-EXCEPTION.md') } };
}

function build({ addonDir, dataDir, outDir, root, tracked, log = () => {} }) {
	const folders = sources({ addonDir, dataDir, tracked });
	fs.rmSync(outDir, { recursive: true, force: true });
	fs.mkdirSync(outDir, { recursive: true });
	const built = [];
	let files = 0;
	for (const [name, src] of folders) {
		const dest = path.join(outDir, folderName(name));
		for (const rel of src.files) {
			const from = path.join(src.dir, rel);
			const relOut = rel.split(path.sep).map((part, i, all) => (i === all.length - 1 && part === `${name}.toc` ? `${folderName(name)}.toc` : part)).join(path.sep);
			const to = path.join(dest, relOut);
			fs.mkdirSync(path.dirname(to), { recursive: true });
			if (TEXT.has(path.extname(rel).toLowerCase())) {
				fs.writeFileSync(to, rebrandFile(path.join(folderName(name), relOut), fs.readFileSync(from, 'utf8')));
			} else {
				fs.copyFileSync(from, to);
			}
			files++;
		}
		const more = root && extras(root)[name];
		for (const [file, from] of Object.entries(more || {})) {
			if (fs.existsSync(from) && !fs.existsSync(path.join(dest, file))) fs.copyFileSync(from, path.join(dest, file));
		}
		built.push(folderName(name));
	}
	fs.writeFileSync(path.join(outDir, BRAND.token, 'FORK.txt'), forkNote());
	log(`built ${built.length} folders, ${files} files into ${outDir}`);
	return built;
}

function forkNote() {
	return [
		`${BRAND.name} is a fork of Polestar (https://github.com/fitzforge/polestar),`,
		'the leveling guide addon for World of Warcraft: Forever, renamed so both',
		'can be installed and loaded side by side. Polestar is Copyright (c) 2026',
		'The Polestar authors and is licensed under the GNU General Public License',
		'version 3 (LICENSE) with the additional permissions in LICENSE-EXCEPTION.md.',
		'This fork is under the same licence. Third-party material keeps its own',
		'licences and credits (CREDITS.md and LICENSE-DATA.txt in the folders).',
		'',
		`Source of this fork: ${BRAND.website}`,
		'Report problems with this fork there, not to Polestar.',
		'',
	].join('\n');
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

// Leftover Polestar names in the built folders: a "Polestar" word that is not
// "PolestarPlus"/"Polestar Plus", in code (comments are fine: the credits say
// Polestar) or a TOC. -> [{ file, line, text }]
function leftovers(outDir) {
	const out = [];
	for (const rel of walk(outDir)) {
		const ext = path.extname(rel).toLowerCase();
		if (!TEXT.has(ext)) continue;
		if (!rel.startsWith(BRAND.token)) out.push({ file: rel, line: 0, text: 'folder not renamed' });
		let text = fs.readFileSync(path.join(outDir, rel), 'utf8');
		if (ext === '.lua') text = stripLuaComments(text);
		if (ext === '.xml') text = text.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '));
		const lines = text.split('\n');
		lines.forEach((l, i) => {
			if (ext === '.toc' && /^## (X-Fork|Author|X-License)/.test(l)) return;
			if (ext === '.toc' && /^#/.test(l) && !/^## /.test(l)) return;
			const re = /(^|[^A-Za-z0-9_])Polestar(?! ?Plus)(?!['\u2019]s )|POLESTAR(?! ?PLUS)|(^|[^A-Za-z0-9_])polestar_|SLASH_[A-Z_]+\d*\s*=\s*"\/(polestar|pole|ps)"/;
			if (re.test(l)) out.push({ file: rel, line: i + 1, text: l.trim().slice(0, 160) });
		});
	}
	return out;
}

function stripLuaComments(src) {
	// Blank out comments, keep line numbers.
	let out = '';
	let i = 0;
	const n = src.length;
	while (i < n) {
		const c = src[i];
		if (c === '-' && src[i + 1] === '-') {
			let lv = -1;
			if (src[i + 2] === '[') {
				let j = i + 3;
				let level = 0;
				while (src[j] === '=') { level++; j++; }
				if (src[j] === '[') lv = level;
			}
			let end;
			if (lv >= 0) {
				const close = ']' + '='.repeat(lv) + ']';
				const k = src.indexOf(close, i + 4 + lv);
				end = k < 0 ? n : k + close.length;
			} else {
				const nl = src.indexOf('\n', i);
				end = nl < 0 ? n : nl;
			}
			out += src.slice(i, end).replace(/[^\n]/g, ' ');
			i = end;
			continue;
		}
		if (c === '"' || c === "'") {
			let j = i + 1;
			while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
			out += src.slice(i, j + 1);
			i = j + 1;
			continue;
		}
		if (c === '[') {
			let j = i + 1;
			let level = 0;
			while (src[j] === '=') { level++; j++; }
			if (src[j] === '[') {
				const close = ']' + '='.repeat(level) + ']';
				const k = src.indexOf(close, j + 1);
				const end = k < 0 ? n : k + close.length;
				out += src.slice(i, end);
				i = end;
				continue;
			}
		}
		out += c;
		i++;
	}
	return out;
}

// What one AddOns tree claims in the client's shared namespaces, read from its
// files: folders, SavedVariables, slash words and their SlashCmdList keys,
// key bindings, named frames and templates, static popups, addon-message
// prefixes and assigned globals (`luajit -bl` GSET, when LuaJIT is there).
function claims(dir, folders, { luajit } = {}) {
	const c = { folders: new Set(), saved: new Set(), slash: new Set(), slashKeys: new Set(), bindings: new Set(), frames: new Set(), popups: new Set(), prefixes: new Set(), globals: new Set() };
	const { execFileSync } = require('node:child_process');
	for (const name of folders) {
		c.folders.add(name);
		const base = path.join(dir, name);
		if (!fs.existsSync(base)) continue;
		for (const rel of walk(base)) {
			const ext = path.extname(rel).toLowerCase();
			if (!TEXT.has(ext)) continue;
			const file = path.join(base, rel);
			const text = fs.readFileSync(file, 'utf8');
			if (ext === '.toc') {
				for (const m of text.matchAll(/^## SavedVariables(?:PerCharacter)?:\s*(.+)$/gm)) for (const v of m[1].split(',')) c.saved.add(v.trim());
				continue;
			}
			if (ext === '.xml') {
				for (const m of text.matchAll(/<(?:Frame|Button|CheckButton|EditBox|ScrollFrame|Slider|StatusBar|GameTooltip|Texture|FontString|Font|Binding)\b[^>]*\bname="([^"$]+)"/g)) {
					(/<Binding\b/.test(m[0]) ? c.bindings : c.frames).add(m[1]);
				}
				continue;
			}
			const code = stripLuaComments(text);
			for (const m of code.matchAll(/\bSLASH_([A-Z0-9_]+?)\d+\s*=\s*"([^"]+)"/g)) {
				c.slashKeys.add(m[1]);
				c.slash.add(m[2].toLowerCase());
			}
			for (const m of code.matchAll(/CreateFrame\(\s*"[A-Za-z]+"\s*,\s*"([A-Za-z0-9_]+)"/g)) c.frames.add(m[1]);
			for (const m of code.matchAll(/\b[A-Z_]*POPUP[A-Z_]*\s*=\s*"([A-Z0-9_]+)"|\bWHICH\s*=\s*"([A-Z0-9_]+)"/g)) c.popups.add(m[1] || m[2]);
			for (const m of code.matchAll(/\bPREFIX\s*=\s*"([A-Za-z0-9]+)"/g)) c.prefixes.add(m[1]);
			if (luajit && !/Polestar(Plus)?_(Nav_R|Codex|QuestDB|ItemDB)/.test(name) && text.length < 2e6) {
				try {
					const bc = execFileSync(luajit, ['-bl', file], { encoding: 'utf8', maxBuffer: 64 << 20, stdio: ['ignore', 'pipe', 'ignore'] });
					for (const m of bc.matchAll(/\bGSET\s+\d+\s+\d+\s+;\s+"([^"]+)"/g)) c.globals.add(m[1]);
				} catch {
					// a file LuaJIT cannot compile on its own (goto, 5.2 syntax): the other checks still run
				}
			}
		}
	}
	return c;
}

// Globals both trees may set: the client's own (a hook writes back the same
// function) and names no addon owns.
const SHARED_OK = new Set(['SlashCmdList', 'StaticPopupDialogs', 'UISpecialFrames', '_', 'BINDING_HEADER_OTHER']);

function collisions(a, b) {
	const out = {};
	for (const key of Object.keys(a)) {
		const both = [...a[key]].filter((v) => b[key].has(v) && !(key === 'globals' && SHARED_OK.has(v)));
		if (both.length) out[key] = both.sort();
	}
	return out;
}

// Claimed by both on paper, but taken at run time only by the first addon
// that finds it free: /way and the TomTom stand-in (Nav/Journey.lua:
// wayTaken, tomtomInstalled) and /rl (Core/Init.lua: slashTaken). Polestar
// loads before PolestarPlus, so Polestar keeps them.
const RUNTIME_GUARDED = { slash: new Set(['/rl', '/way']), globals: new Set(['TomTom']) };

// collisions() split into the real ones and the run-time guarded ones.
function split(shared) {
	const real = {};
	const guarded = {};
	for (const [k, list] of Object.entries(shared)) {
		for (const v of list) {
			const into = RUNTIME_GUARDED[k] && RUNTIME_GUARDED[k].has(v) ? guarded : real;
			(into[k] = into[k] || []).push(v);
		}
	}
	return { real, guarded };
}

module.exports = { BRAND, EXCLUDE, RUNTIME_GUARDED, split, tokens, display, luaStrings, toc, rebrandFile, folderName, sources, build, leftovers, claims, collisions, walk };
