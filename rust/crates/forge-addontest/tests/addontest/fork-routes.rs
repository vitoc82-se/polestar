//! Polestar Plus, the fork (FORK.md): the quest log route (addon/Polestar/Fork/LogRoute.lua, Lookup kind "questlog")
//! and the zone completionist (Fork/ZoneQuests.lua, kind "zone"), built from a synthetic Codex (fictional quests,
//! NPCs and zones on the lookup fixture's three maps) in the real addon, then played to the end by the shared guide
//! simulator. The rules pinned: every quest's objectives come before its turn-in; an accept comes after the turn-ins
//! of its prerequisites (and a breadcrumb's); quests handed in to one NPC share a stop; what can't be routed is
//! listed with its reason; the route order keeps every dependency for random stop sets.

use forge_addontest::codex::{fixture, write_codex_pack, CodexOpts, CodexPack};
use forge_addontest::playtest::SIMULATE;
use forge_addontest::{emitted, RunAddon};
use serde_json::{json, Value};

const VALE: i64 = 9001; // Amber Vale (continent 0)
const HOLLOW: i64 = 9002; // Ember Hollow (continent 0, next door)

fn npc(id: i64, name: &str, map: i64, x: f64, y: f64) -> Value {
	json!({ "id": id, "name": name, "level": 20, "levelMax": null, "faction": null, "rare": false, "elite": false, "boss": false, "instance": null, "roles": [],
		"spawns": [{ "map": map, "x": x, "y": y, "f": "e" }] })
}

fn quest(id: i64, title: &str, level: i64, giver: i64, ender: i64, objectives: Value, zone: i64) -> Value {
	json!({ "id": id, "title": title, "level": level, "minLevel": (level - 4).max(1), "faction": null, "races": null, "classes": null,
		"start": { "npc": [giver], "object": [], "item": [] }, "end": { "npc": [ender], "object": [] },
		"objectives": objectives, "pre": [], "preAny": [], "zone": zone, "rewards": [], "choices": [] })
}

fn kill(id: i64, n: i64, text: &str) -> Value {
	json!({ "type": "kill", "id": id, "count": n, "text": text })
}

struct Ctx {
	maps: String,
	pack: CodexPack,
}

/// The lookup fixture's maps, zones and instances, with this file's NPCs, items and quests only.
fn ctx(npcs: Vec<Value>, items: Vec<Value>, quests: Vec<Value>) -> Ctx {
	let mut codex = fixture("lookup.json");
	codex["npcs"] = json!({});
	codex["objects"] = json!({});
	codex["items"] = json!({});
	codex["quests"] = json!({});
	codex["spells"] = json!({});
	// The fixture's dungeon boss, inside the Ashen Crypt.
	codex["npcs"]["5013"] = json!({ "id": 5013, "name": "Lord Ashcroft", "level": 26, "levelMax": null, "faction": null, "rare": false, "elite": true, "boss": true,
		"instance": "ashen_crypt", "roles": [], "spawns": [] });
	for n in npcs {
		let k = n["id"].to_string();
		codex["npcs"][k] = n;
	}
	for i in items {
		let k = i["id"].to_string();
		codex["items"][k] = i;
	}
	for q in quests {
		let k = q["id"].to_string();
		codex["quests"][k] = q;
	}
	let mut frames: Vec<(i64, Value)> = codex["frames"].as_object().unwrap().iter().map(|(k, f)| (k.parse::<i64>().unwrap(), f.clone())).collect();
	frames.sort_by_key(|(id, _)| *id);
	let maps = frames
		.iter()
		.map(|(id, f)| {
			format!(
				"w.addMap({id}, {{ name = {}, c = {}, left = {}, right = {}, top = {}, bottom = {} }})",
				serde_json::to_string(&codex["zones"][id.to_string().as_str()]["name"]).unwrap(),
				f["c"],
				f["left"],
				f["right"],
				f["top"],
				f["bottom"]
			)
		})
		.collect::<Vec<_>>()
		.join("\n");
	let pack = write_codex_pack(&codex, &CodexOpts::default());
	Ctx { maps, pack }
}

fn before(c: &Ctx, tail: &str) -> String {
	format!("{}\nlocal w = stub.world\n{}\nw.level = 20\nw.moveTo({VALE}, 50, 50)\n{tail}", c.pack.stub_lua, c.maps)
}

// The open guide as data: each goal with its step, verb and quest, in order.
const DESCRIBE: &str = r#"
local function describe(id)
	local g = id and Polestar.Guides.Get(id)
	if not g then return false end
	local goals, steps = {}, {}
	for i, s in ipairs(g.steps) do
		steps[i] = { title = s.title, note = s.note or false, away = s.away or false }
		for _, goal in ipairs(s.goals) do
			goals[#goals + 1] = { step = i, t = goal.t, quest = goal.quest or false, npc = goal.npc or false, map = goal.map or false }
		end
	end
	return { id = id, title = g.title, goals = goals, steps = steps }
end
"#;

fn run(c: &Ctx, setup: &str, script: &str) -> Vec<Value> {
	emitted(&RunAddon {
		stubs: vec!["stub_world.lua"],
		before: before(c, setup),
		addons: vec!["Polestar".into()],
		script: format!("{DESCRIBE}\nstub.login()\n{script}"),
		..Default::default()
	})
}

/// Position of the first goal matching (verb, quest), and of the last.
fn at(goals: &Value, t: &str, q: i64) -> (usize, usize) {
	let hits: Vec<usize> = goals.as_array().unwrap().iter().enumerate().filter(|(_, g)| g["t"] == t && g["quest"] == q).map(|(i, _)| i).collect();
	assert!(!hits.is_empty(), "no {t} goal for quest {q} in {goals}");
	(hits[0], *hits.last().unwrap())
}

fn work_before_turnin(goals: &Value, q: i64) {
	let (turnin, _) = at(goals, "turnin", q);
	for (i, g) in goals.as_array().unwrap().iter().enumerate() {
		if g["quest"] == q && g["t"] != "turnin" && g["t"] != "accept" {
			assert!(i < turnin, "quest {q}: its {} (goal {i}) comes after its turn-in (goal {turnin})", g["t"]);
		}
	}
}

// ---------------------------------------------------------------------------
// The quest log route
// ---------------------------------------------------------------------------

fn log_ctx() -> Ctx {
	ctx(
		vec![
			npc(9500, "Warden Brisk", VALE, 48.0, 50.0),
			npc(9501, "Keeper Moss", HOLLOW, 50.0, 50.0),
			npc(9510, "Thornback Boar", VALE, 20.0, 20.0),
			npc(9511, "Cinder Hound", HOLLOW, 30.0, 30.0),
			npc(9512, "Gloom Moth", VALE, 80.0, 80.0),
			npc(9513, "Dusk Rat", VALE, 60.0, 30.0),
		],
		vec![json!({ "id": 9600, "name": "Moth Wing", "quality": 1, "kind": "item", "spell": null, "reqLevel": null,
			"sources": [{ "type": "drop", "npc": 9512, "chance": 60, "from": ["questie"] }] })],
		vec![
			quest(9701, "Boars at the Gate", 20, 9500, 9500, json!([kill(9510, 6, "Thornback Boar")]), VALE),
			quest(9702, "Word for the Keeper", 20, 9500, 9501, json!([]), VALE),
			quest(9703, "Hounds and Moths", 20, 9500, 9500, json!([kill(9511, 5, "Cinder Hound"), { "type": "item", "id": 9600, "count": 4, "text": "Moth Wing" }]), HOLLOW),
			quest(9704, "Old Rats", 5, 9500, 9500, json!([kill(9513, 4, "Dusk Rat")]), VALE),
			quest(9705, "Into the Crypt", 22, 9500, 9500, json!([kill(5013, 1, "Lord Ashcroft")]), VALE),
		],
	)
}

const LOG: &str = r#"
w.onQuest(9701, { { required = 6, type = "monster" } }, "Boars at the Gate")
w.onQuest(9702, {}, "Word for the Keeper")
w.onQuest(9703, { { required = 5, type = "monster" }, { required = 4, type = "item" } }, "Hounds and Moths")
w.onQuest(9704, { { required = 4, type = "monster" } }, "Old Rats")
w.onQuest(9705, { { required = 1, type = "monster" } }, "Into the Crypt")
w.onQuest(9799, { { required = 1, type = "monster" } }, "A Quest Nobody Knows")
"#;

#[test]
fn the_log_route_takes_every_quest_objectives_before_turn_ins_shares_an_ender_and_lists_what_it_leaves_out() {
	let c = log_ctx();
	let out = run(
		&c,
		LOG,
		r#"
local id, why = Polestar.ForkLogRoute.Open()
emit(describe(id) or { why = why or false })
local left = {}
for _, q in ipairs(Polestar.ForkLogRoute.LeftOut()) do left[#left + 1] = { quest = q.quest, why = q.why, grey = q.grey or false } end
emit(left)
-- The Quest room's list of them: Abandon only on the grey one.
Polestar.UI.ShowQuestRoom("logroute")
local F, rows = _G.PolestarQuestRoom, {}
for i, r in ipairs(F.rows) do
	if r:IsShown() then rows[#rows + 1] = { quest = r.Abandon.psQuest, abandon = r.Abandon:IsShown() } end
end
emit({ rows = rows, logRoute = F.LogRoute:IsShown(), zones = F.Zones:IsShown() })
"#,
	);
	let g = &out[0];
	assert_eq!(g["id"], "lookup/questlog/all", "{g}");
	let goals = &g["goals"];
	for q in [9701, 9703] {
		work_before_turnin(goals, q);
	}
	// 9702 is finished (no objectives): only its turn-in, at the other zone's keeper.
	let (t2, _) = at(goals, "turnin", 9702);
	assert_eq!(goals[t2]["map"], HOLLOW);
	// 9701 and 9703 are both handed in to Warden Brisk: one step.
	let (t1, _) = at(goals, "turnin", 9701);
	let (t3, _) = at(goals, "turnin", 9703);
	assert_eq!(goals[t1]["step"], goals[t3]["step"], "one stop for the shared ender");
	assert!(g["steps"][0]["note"].as_str().unwrap().contains("3 quests"), "{}", g["steps"][0]["note"]);
	// Left out, each with its reason; the grey one can be abandoned.
	assert_eq!(
		out[1],
		json!([
			{ "quest": 9704, "why": "grey", "grey": true },
			{ "quest": 9705, "why": "dungeon", "grey": false },
			{ "quest": 9799, "why": "nodata", "grey": false },
		])
	);
	assert_eq!(out[2]["rows"], json!([{ "quest": 9704, "abandon": true }, { "quest": 9705, "abandon": false }, { "quest": 9799, "abandon": false }]));
	assert_eq!(out[2]["logRoute"], true);
	assert_eq!(out[2]["zones"], true);
}

#[test]
fn the_log_route_plays_to_the_end_and_the_slash_command_opens_it() {
	let c = log_ctx();
	let out = run(
		&c,
		LOG,
		&format!(
			r#"
Polestar.RunCommand("emptylog")
local g = Polestar.Engine.GetGuide()
emit(g and g.id or false)
SIM_GUIDE = g
{SIMULATE}"#
		),
	);
	assert_eq!(out[0], "lookup/questlog/all");
	let sim = &out[1];
	assert!(sim["stuck"].is_null() || sim["stuck"] == false, "stuck: {}", sim["stuck"]);
	assert_eq!(sim["done"], true, "{sim}");
	assert_eq!(sim["missing"], json!({}), "every turn-in has a place");
}

// ---------------------------------------------------------------------------
// The zone completionist
// ---------------------------------------------------------------------------

fn zone_ctx() -> Ctx {
	let mut q = vec![
		// A chain in the zone.
		quest(9801, "First Patrol", 18, 9500, 9500, json!([kill(9510, 4, "Thornback Boar")]), VALE),
		quest(9802, "Second Patrol", 19, 9500, 9502, json!([kill(9513, 4, "Dusk Rat")]), VALE),
		// Needs a quest of the next zone first.
		quest(9803, "Letters from Afar", 19, 9502, 9500, json!([kill(9512, 3, "Gloom Moth")]), VALE),
		quest(9811, "The Keeper's Errand", 18, 9501, 9501, json!([kill(9511, 3, "Cinder Hound")]), HOLLOW),
		// Not for an Alliance character: not counted.
		quest(9804, "Horde Business", 18, 9500, 9500, json!([]), VALE),
		// Too low level for now.
		quest(9805, "The High Ridge", 34, 9500, 9500, json!([kill(9513, 2, "Dusk Rat")]), VALE),
		// Done before.
		quest(9806, "Old News", 18, 9500, 9500, json!([]), VALE),
		// A breadcrumb to 9808: handed in where 9808 starts; taking 9808 closes it.
		quest(9807, "Seek the Ranger", 18, 9500, 9502, json!([]), VALE),
		quest(9808, "Ranger's Request", 19, 9502, 9502, json!([kill(9510, 3, "Thornback Boar")]), VALE),
		// Exclusive alternatives with different givers: one is kept.
		quest(9809, "Side with the Miller", 19, 9500, 9500, json!([]), VALE),
		quest(9810, "Side with the Farmer", 19, 9502, 9502, json!([]), VALE),
		// Needs the level-locked quest: left out.
		quest(9812, "Beyond the Ridge", 20, 9500, 9500, json!([]), VALE),
		// One of two: the Horde one or the zone's First Patrol.
		quest(9813, "Either Way", 20, 9500, 9500, json!([]), VALE),
		quest(9814, "Horde Prelude", 18, 9501, 9501, json!([]), HOLLOW),
	];
	let set = |q: &mut Vec<Value>, id: i64, k: &str, v: Value| {
		let e = q.iter_mut().find(|e| e["id"] == id).unwrap();
		e[k] = v;
	};
	set(&mut q, 9802, "pre", json!([9801]));
	set(&mut q, 9803, "pre", json!([9811]));
	set(&mut q, 9804, "faction", json!("H"));
	set(&mut q, 9814, "faction", json!("H"));
	set(&mut q, 9807, "closedBy", json!([9808]));
	set(&mut q, 9809, "closedBy", json!([9810]));
	set(&mut q, 9810, "closedBy", json!([9809]));
	set(&mut q, 9812, "pre", json!([9805]));
	set(&mut q, 9813, "preAny", json!([9814, 9801]));
	ctx(
		vec![
			npc(9500, "Warden Brisk", VALE, 48.0, 50.0),
			npc(9501, "Keeper Moss", HOLLOW, 50.0, 50.0),
			npc(9502, "Ranger Fallow", VALE, 70.0, 60.0),
			npc(9510, "Thornback Boar", VALE, 20.0, 20.0),
			npc(9511, "Cinder Hound", HOLLOW, 30.0, 30.0),
			npc(9512, "Gloom Moth", VALE, 80.0, 80.0),
			npc(9513, "Dusk Rat", VALE, 60.0, 30.0),
		],
		vec![],
		q,
	)
}

#[test]
fn a_zone_guide_does_every_quest_it_can_prerequisites_and_breadcrumbs_first_and_says_what_it_leaves_out() {
	let c = zone_ctx();
	let out = run(
		&c,
		"w.complete({ 9806 })",
		&format!(
			r#"
local ZQ = Polestar.ForkZoneQuests
emit({{ find = ZQ.Find("amber") or false, part = #select(2, ZQ.Find("e")) }})
local zones = {{}}
for _, z in ipairs(ZQ.Zones()) do zones[#zones + 1] = {{ map = z.map, done = z.done, total = z.total }} end
emit(zones)
local id, why = ZQ.Open({VALE})
emit(describe(id) or {{ why = why or false }})
local plan = ZQ.Last({VALE})
local left = {{}}
for _, q in ipairs(plan.leftOut) do left[#left + 1] = {{ quest = q.quest, why = q.why }} end
table.sort(left, function(a, b) return a.quest < b.quest end)
emit({{ total = plan.total, done = plan.done, routed = plan.routed, away = plan.away, left = left, doneList = #plan.doneList }})
"#
		),
	);
	assert_eq!(out[0]["find"], VALE);
	assert_eq!(
		out[1],
		json!([{ "map": VALE, "done": 1, "total": 11 }, { "map": HOLLOW, "done": 0, "total": 1 }]),
		"Horde quests are not counted"
	);
	let g = &out[2];
	assert_eq!(g["id"], format!("lookup/zone/{VALE}"), "{g}");
	assert_eq!(g["title"], "Amber Vale: every quest");
	let goals = &g["goals"];
	for q in [9801, 9802, 9803, 9811, 9807, 9808, 9813] {
		let (accept, _) = at(goals, "accept", q);
		let (turnin, _) = at(goals, "turnin", q);
		assert!(accept < turnin, "quest {q}: accept before turn-in");
		work_before_turnin(goals, q);
	}
	let after = |q: i64, pre: i64| {
		let (accept, _) = at(goals, "accept", q);
		let (turnin, _) = at(goals, "turnin", pre);
		assert!(turnin < accept, "{q} is taken after {pre} is handed in");
	};
	after(9802, 9801);
	after(9803, 9811); // from the next zone
	after(9808, 9807); // the breadcrumb first
	after(9813, 9801); // the one of its preAny this character can do
	// The next zone's prerequisite is marked.
	let (a11, _) = at(goals, "accept", 9811);
	let step = goals[a11]["step"].as_u64().unwrap() as usize - 1;
	assert_eq!(g["steps"][step]["away"], true, "{}", g["steps"][step]);
	assert!(g["steps"][step]["note"].as_str().unwrap().starts_with("Outside Amber Vale"), "{}", g["steps"][step]["note"]);
	// One of the exclusive pair, never both.
	let has = |q: i64| goals.as_array().unwrap().iter().any(|x| x["quest"] == q);
	assert!(has(9809) ^ has(9810), "one of two exclusive quests");
	assert!(!has(9804) && !has(9805) && !has(9806) && !has(9812) && !has(9814));
	let s = &out[3];
	assert_eq!((s["total"].clone(), s["done"].clone(), s["routed"].clone(), s["away"].clone(), s["doneList"].clone()), (json!(11), json!(1), json!(8), json!(1), json!(1)));
	assert_eq!(s["left"], json!([{ "quest": 9805, "why": "level" }, { "quest": 9810, "why": "exclusive" }, { "quest": 9812, "why": "prereq" }]));
	assert!(g["steps"][0]["note"].as_str().unwrap().contains("1 of 11 quests done"), "{}", g["steps"][0]["note"]);
}

#[test]
fn a_zone_guide_plays_to_the_end_and_the_slash_command_picks_the_zone_by_name() {
	let c = zone_ctx();
	let out = run(
		&c,
		"w.complete({ 9806 })",
		&format!(
			r#"
Polestar.RunCommand("zone amber vale")
local g = Polestar.Engine.GetGuide()
emit({{ id = g and g.id or false, picker = _G.PolestarZonePicker and _G.PolestarZonePicker:IsShown() or false }})
SIM_GUIDE = g
{SIMULATE}"#
		),
	);
	assert_eq!(out[0], json!({ "id": format!("lookup/zone/{VALE}"), "picker": true }));
	let sim = &out[1];
	assert!(sim["stuck"].is_null() || sim["stuck"] == false, "stuck: {}", sim["stuck"]);
	assert_eq!(sim["done"], true, "{sim}");
	assert_eq!(sim["missing"], json!({}), "every accept and turn-in has a place");
}

#[test]
fn the_zone_list_shows_each_zone_with_its_progress_and_a_zone_s_detail_says_why() {
	let c = zone_ctx();
	let out = run(
		&c,
		"w.complete({ 9806 })",
		&format!(
			r#"
local UI = Polestar.UI
UI.ShowZonePicker()
local F = _G.PolestarZonePicker
local function rows()
	local out = {{}}
	for _, r in ipairs(F.rows) do
		if r:IsShown() then out[#out + 1] = {{ title = r.Title:GetText(), why = r.Why:IsShown() and r.Why:GetText() or false, go = r.Go:IsShown() }} end
	end
	return out
end
emit(rows())
UI.ShowZonePicker({VALE})
emit({{ title = F.Title:GetText(), rows = rows(), guide = F.GuideMe:IsShown(), back = F.Back:IsShown() }})
"#
		),
	);
	let list = out[0].as_array().unwrap();
	assert_eq!(list[0]["title"], "Where you are");
	assert_eq!(list[1], json!({ "title": "Amber Vale", "why": "1 of 11 done  \u{b7}  levels 18-34", "go": true }));
	let d = &out[1];
	assert_eq!(d["title"], "Amber Vale: 1 of 11 quests done");
	assert_eq!(d["guide"], true);
	assert_eq!(d["back"], true);
	let titles: Vec<&str> = d["rows"].as_array().unwrap().iter().map(|r| r["title"].as_str().unwrap()).collect();
	let mut left = titles[1..4].to_vec();
	left.sort();
	assert_eq!((titles[0], left, titles[4], titles[5]), ("Left out (3)", vec!["Beyond the Ridge", "Side with the Farmer", "The High Ridge"], "Already done (1): skipped", "Old News"), "{titles:?}");
	let ridge = d["rows"].as_array().unwrap().iter().find(|r| r["title"] == "The High Ridge").unwrap();
	assert_eq!(ridge["why"], "Requires level 30");
}

// ---------------------------------------------------------------------------
// The order itself: random stops and dependencies
// ---------------------------------------------------------------------------

#[test]
fn the_route_order_keeps_every_dependency_and_two_opt_never_makes_it_longer() {
	let c = log_ctx();
	let out = run(
		&c,
		"",
		r#"
local Kit = Polestar.ForkRoute
assert(Polestar.Codex.Load(), "the Codex places the Era-frame points")
local seed = 12345
local function rand(n)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n + 1
end
local results = {}
for trial = 1, 40 do
	local n = 5 + rand(40)
	local stops = {}
	for i = 1, n do
		local map = rand(3) == 1 and 9002 or 9001
		local p = { map = map, x = rand(100), y = rand(100), f = "e" }
		local deps = {}
		-- Each stop may need one to three earlier stops (a turn-in after its objectives, an accept after a prerequisite).
		if i > 1 and rand(3) > 1 then
			for _ = 1, rand(3) do
				local d = rand(i - 1)
				local dup = false
				for _, e in ipairs(deps) do if e == d then dup = true end end
				if not dup then deps[#deps + 1] = d end
			end
		end
		stops[i] = { key = "s" .. i, inP = p, outP = p, deps = deps }
	end
	local from = { map = 9001, x = 50, y = 50, f = "e" }
	local pts = { from }
	for _, s in ipairs(stops) do pts[#pts + 1] = s.inP end
	local travel = Kit.Travel(pts)
	local function cost(o)
		local c, at = 0, from
		for _, i in ipairs(o) do
			c = c + travel(at, stops[i].inP)
			at = stops[i].outP
		end
		return c
	end
	local base = Polestar.Dungeons.OrderStops(stops, from, nil, "forkTest", "t" .. trial, { travel = travel })
	local better = Kit.TwoOpt(stops, base, from, travel)
	local order = Kit.Order(stops, from, "forkTest", "u" .. trial, travel)
	results[#results + 1] = { valid = Kit.Valid(stops, order) and Kit.Valid(stops, better) and true or false,
		longer = cost(better) > cost(base) + 1, n = n }
end
emit(results)
"#,
	);
	for (i, r) in out[0].as_array().unwrap().iter().enumerate() {
		assert_eq!(r["valid"], true, "trial {i} ({} stops) broke a dependency", r["n"]);
		assert_eq!(r["longer"], false, "trial {i}: 2-opt made it longer");
	}
}

#[test]
fn a_big_zone_of_chained_quests_keeps_every_prerequisite_and_objective_in_order() {
	// 80 quests, every third one needing the one before it, spread over the zone and the next one: far past
	// ForkRoute.SMALL, so the greedy order, Or-opt and 2-opt place the stops.
	let mut npcs = vec![npc(9500, "Warden Brisk", VALE, 48.0, 50.0), npc(9501, "Keeper Moss", HOLLOW, 50.0, 50.0)];
	let mut quests = Vec::new();
	for k in 0..80i64 {
		let mob = 9900 + k;
		let (map, x, y) = if k % 5 == 0 { (HOLLOW, 10.0 + (k % 9) as f64 * 9.0, 15.0 + (k % 7) as f64 * 11.0) } else { (VALE, 5.0 + (k * 37 % 90) as f64, 5.0 + (k * 53 % 90) as f64) };
		npcs.push(npc(mob, &format!("Wild Beast {k}"), map, x, y));
		let giver = if k % 2 == 0 { 9500 } else { 9501 };
		let mut q = quest(10000 + k, &format!("Chore {k}"), 20, giver, if k % 3 == 0 { 9501 } else { 9500 }, json!([kill(mob, 2, &format!("Wild Beast {k}"))]), VALE);
		if k % 3 != 0 {
			q["pre"] = json!([10000 + k - 1]);
		}
		quests.push(q);
	}
	let c = ctx(npcs, vec![], quests);
	let out = run(
		&c,
		"",
		&format!(
			r#"
local id = Polestar.ForkZoneQuests.Open({VALE})
emit(describe(id))
local plan = Polestar.ForkZoneQuests.Last({VALE})
emit({{ stops = #plan.stops, routed = plan.routed }})
"#
		),
	);
	let goals = &out[0]["goals"];
	assert_eq!(out[1]["routed"], 80);
	assert!(out[1]["stops"].as_i64().unwrap() > 30, "{}", out[1]);
	for k in 0..80i64 {
		let q = 10000 + k;
		let (accept, _) = at(goals, "accept", q);
		let (turnin, _) = at(goals, "turnin", q);
		assert!(accept < turnin, "quest {q}");
		work_before_turnin(goals, q);
		if k % 3 != 0 {
			let (pre, _) = at(goals, "turnin", q - 1);
			assert!(pre < accept, "{q} is taken after {} is handed in", q - 1);
		}
	}
}
