'use strict';
// Polestar Plus, the fork (FORK.md): the rebrand step (tools/lib/fork/rebrand.js) renames every name the
// client shares between addons, keeps lowercase values and links, shows "Polestar Plus" in text, leaves no
// Polestar name in the built code, and the built addon loads beside Polestar in one client with nothing shared.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const R = require('../tools/lib/fork/rebrand');
const { runAddon, ROOT } = require('./helpers/lua');

test('the token rules rename globals, folders, slash words, bindings and widget ids, and keep values and links', () => {
	const src = [
		'local f = CreateFrame("Frame", "PolestarGuideFrame", UIParent)',
		'SLASH_POLESTAR1 = "/polestar"',
		'SLASH_POLESTAR2 = "/pole"',
		'SLASH_POLESTAR3 = "/ps"',
		'BINDING_NAME_POLESTAR_TOGGLE = L["Toggle guide window"]',
		'local WIDGET = "polestar_quest_needed"',
		'local A = C_AddOns.IsAddOnLoaded("Polestar_Guides_" .. race)',
		'local tex = "Interface\\\\AddOns\\\\Polestar\\\\Media\\\\UI\\\\logo"',
		'local skin = "polestar"',
		'local url = "https://github.com/fitzforge/polestar" .. "discord.gg/polestar"',
		'PolestarDB = PolestarDB or {}',
		'local PREFIX = "|cff4fd1c5Polestar|r: "',
		'print(L["Guide window hidden. Type /polestar to bring it back."])',
		'-- Polestar\'s own comment, /polestar in it',
		'local AllRunPolestar = 1',
	].join('\n');
	const out = R.rebrandFile('PolestarPlus/Core/X.lua', src).split('\n');
	assert.deepEqual(out, [
		'local f = CreateFrame("Frame", "PolestarPlusGuideFrame", UIParent)',
		'SLASH_POLESTARPLUS1 = "/psf"',
		'SLASH_POLESTARPLUS2 = "/polestarplus"',
		'SLASH_POLESTARPLUS3 = "/psplus"',
		'BINDING_NAME_POLESTARPLUS_TOGGLE = L["Toggle guide window"]',
		'local WIDGET = "polestarplus_quest_needed"',
		'local A = C_AddOns.IsAddOnLoaded("PolestarPlus_Guides_" .. race)',
		'local tex = "Interface\\\\AddOns\\\\PolestarPlus\\\\Media\\\\UI\\\\logo"',
		'local skin = "polestar"',
		'local url = "https://github.com/fitzforge/polestar" .. "discord.gg/polestar"',
		'PolestarPlusDB = PolestarPlusDB or {}',
		'local PREFIX = "|cffffb347Polestar Plus|r: "',
		'print(L["Guide window hidden. Type /psf to bring it back."])',
		"-- PolestarPlus's own comment, /psf in it",
		'local AllRunPolestar = 1',
	]);
});

test('a TOC gets its renamed folders and SavedVariables, the fork\'s title, author and website', () => {
	const toc = [
		'## Interface: 16001',
		'## Title: Polestar',
		'## Title-deDE: Polestar',
		'## Author: Polestar',
		'## X-Website: https://github.com/fitzforge/polestar',
		'## Version: 0.4.2',
		'## Category: Polestar',
		'## Dependencies: Polestar',
		'## SavedVariables: PolestarDB',
		'## SavedVariablesPerCharacter: PolestarCharDB',
		'Core\\Core.xml',
	].join('\n');
	const out = R.rebrandFile('PolestarPlus/PolestarPlus.toc', toc).split('\n');
	assert.ok(out.includes('## Title: |cffffb347Polestar Plus|r'));
	assert.ok(out.includes('## Title-deDE: Polestar Plus'));
	assert.ok(out.includes('## Category: Polestar Plus'));
	assert.ok(out.includes('## Dependencies: PolestarPlus'));
	assert.ok(out.includes('## SavedVariables: PolestarPlusDB'));
	assert.ok(out.includes('## SavedVariablesPerCharacter: PolestarPlusCharDB'));
	assert.ok(out.includes(`## X-Website: ${R.BRAND.website}`));
	assert.ok(out.some((l) => l.startsWith('## X-Fork: Polestar Plus, a fork of Polestar')));
	assert.ok(out.includes('## Author: Polestar Plus (a fork of Polestar by the Polestar authors)'));
	const guides = R.rebrandFile('PolestarPlus_Guides/PolestarPlus_Guides.toc', '## Title: Polestar Guides\n## Dependencies: Polestar').split('\n');
	assert.deepEqual(guides, ['## Title: Polestar Plus Guides', '## Dependencies: PolestarPlus']);
});

test('the built addon has no Polestar name left, keeps the licence and credits, and loads beside Polestar with nothing shared', () => {
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'polestar-fork-'));
	try {
		const out = path.join(tmp, 'AddOns');
		const folders = R.build({ addonDir: path.join(ROOT, 'addon'), outDir: out, root: ROOT });
		assert.ok(folders.includes('PolestarPlus') && folders.includes('PolestarPlus_Guides') && folders.includes('PolestarPlus_Nav'), folders.join(','));
		assert.ok(!folders.some((f) => !f.startsWith('PolestarPlus')), 'every folder renamed');
		assert.ok(!folders.includes('PolestarPlus_Recorder') && !folders.includes('PolestarPlus_Arcade'));
		assert.deepEqual(R.leftovers(out), []);
		for (const f of ['LICENSE', 'LICENSE-EXCEPTION.md', 'FORK.txt']) assert.ok(fs.existsSync(path.join(out, 'PolestarPlus', f)), f);
		assert.ok(fs.existsSync(path.join(out, 'PolestarPlus_Nav', 'CREDITS.md')), 'third-party credits kept');
		// The nav pages hold raw zlib bytes in Lua strings: past the renames, every byte stays.
		const pages = fs.readdirSync(path.join(ROOT, 'addon')).filter((n) => /^Polestar_Nav_R\d/.test(n));
		assert.ok(pages.length > 0, 'nav page folders in addon/');
		let binary = 0;
		for (const n of pages) {
			const src = fs.readFileSync(path.join(ROOT, 'addon', n, 'Pages.lua'));
			const got = fs.readFileSync(path.join(out, R.folderName(n), 'Pages.lua'));
			if (R.readText(path.join(ROOT, 'addon', n, 'Pages.lua')).encoding === 'latin1') binary++;
			assert.ok(Buffer.from(got.toString('latin1').replace(/PolestarPlus/g, 'Polestar'), 'latin1').equals(src), `${n}/Pages.lua bytes kept`);
		}
		assert.ok(binary > 0, 'some page holds bytes that are not UTF-8');
		const mine = R.claims(out, folders);
		const theirs = R.claims(path.join(ROOT, 'addon'), fs.readdirSync(path.join(ROOT, 'addon')).filter((n) => /^Polestar(_|$)/.test(n) && !R.EXCLUDE.has(n)));
		// /way and /rl are taken by whoever loads first, at run time; nothing else is shared.
		const shared = R.collisions(theirs, mine);
		assert.deepEqual(shared, { slash: ['/rl', '/way'] });

		const [both] = runAddon({
			stubs: ['stub_world.lua'],
			addons: ['Polestar', 'Polestar_Guides', { name: 'PolestarPlus', dir: path.join(out, 'PolestarPlus') }, { name: 'PolestarPlus_Guides', dir: path.join(out, 'PolestarPlus_Guides') }],
			login: true,
			script: `
local n1, n2 = #Polestar.Guides.List(), #PolestarPlus.Guides.List()
emit({
	distinct = Polestar ~= PolestarPlus and Polestar.Engine ~= PolestarPlus.Engine,
	slash = { SLASH_POLESTAR1, SLASH_POLESTAR2, SLASH_POLESTAR3, SLASH_POLESTARPLUS1, SLASH_POLESTARPLUS2, SLASH_POLESTARPLUS3 },
	rl = { SLASH_POLESTAR_RL1 or false, SLASH_POLESTARPLUS_RL1 or false },
	handlers = SlashCmdList.POLESTAR ~= SlashCmdList.POLESTARPLUS,
	saved = type(PolestarDB) == "table" and type(PolestarPlusDB) == "table" and PolestarDB ~= PolestarPlusDB,
	planners = PolestarPlus.ForkZoneQuests ~= nil and PolestarPlus.ForkLogRoute ~= nil,
	guides = n1 > 10 and n1 == n2,
})`,
		}).emitted;
		assert.deepEqual(both, {
			distinct: true,
			slash: ['/polestar', '/pole', '/ps', '/psf', '/polestarplus', '/psplus'],
			rl: ['/rl', false],
			handlers: true,
			saved: true,
			planners: true,
			guides: true,
		});
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
});
