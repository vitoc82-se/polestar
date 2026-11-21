-- Polestar Plus (the fork, FORK.md): the zone completionist. The player picks
-- a zone (the zone list, Fork/ZonePicker.lua, or /polestar zone <name>) and
-- gets one guide that does every quest of that zone this character can do:
-- each pick-up, its objectives and its turn-in, follow-ups after the quests
-- they need, in an order that keeps every prerequisite before the quest it
-- opens (Lookup planner kind "zone", id the zone's map: "lookup/zone/<map>").
--
-- A zone's quests are the Codex quests whose `zone` is its map. For this
-- character each one is:
--   * not for them (faction, race, class: Lookup.QuestBlock), or a
--     holiday's (ForkRoute.Holiday): not counted;
--   * done (the client's completed quests): counted, said, left out;
--   * left out with its reason: a level it doesn't have yet, a profession,
--     closed for good by a quest it took (`closedBy`), the other one of an
--     exclusive pair, inside a dungeon or raid, an elite it should not solo,
--     a start item it doesn't have, no data, or a prerequisite it can't do
--     (any of these, in the zone or elsewhere);
--   * routed. A prerequisite in another zone (Lookup.QuestChain: all of
--     `pre`, one of `preAny`) comes into the route too, its steps marked
--     "Outside <zone>" (ForkRoute.Steps).
-- Breadcrumbs (a quest whose taking another closes, handed in where that one
-- starts) stay, before the quest they lead to. The order: accept, objectives,
-- turn-in per quest; each accept after the turn-ins of its prerequisites;
-- the log's room kept (Compat.GetLogCap); ForkRoute.Order over
-- ForkRoute.Travel from where the player stands.
--
--   ZQ.Zones() -> { { map, name, continent, total, done, minLevel, maxLevel }, ... }
--   ZQ.Find(text) -> map | nil, matches     -- a zone by name (case and accents aside)
--   ZQ.Plan(map) -> plan | nil, reason
--       plan = { map, name, total, done, routed, away, stops, from,
--                doneList = { { quest, title } }, leftOut = { { quest, title, why, text } } }
--   ZQ.Open(map) -> guideId | nil, reason
--   /polestar zone [name]

local ADDON, ns = ...
local L = ns.L

local ZQ = {}
ns.ForkZoneQuests = ZQ

local Kit = ns.ForkRoute
local type, ipairs, pairs, format, sort = type, ipairs, pairs, string.format, table.sort

local KIND = "zone"
local FIELD = "forkZoneRoute"
local LOG_SPARE = 1
local NOT_FOR = { faction = true, race = true, class = true }

local WHY = {
	level = L["Requires level %d"],
	profession = "%s",
	closed = L["No longer offered: you took %s"],
	exclusive = L["Either this or %s: the route takes the other"],
	dungeon = L["Inside %s: do it with a group"],
	elite = L["Elite: group advised"],
	item = L["Starts from an item you don't have: %s"],
	nodata = L["No quest data: Polestar doesn't know where it is done"],
	prereq = L["Needs %s first: %s"],
}

---------------------------------------------------------------------------
-- The zones' quests (read once a session: the Codex doesn't change)
---------------------------------------------------------------------------

local byZone -- map -> { questId, ... }

local function index()
	if byZone then return byZone end
	local X = ns.Codex
	if not (X and X.Load()) then return nil end
	byZone = {}
	X.Each("quest", function(id)
		local rec = X.Quest(id)
		local z = rec and rec.zone
		if z then
			local list = byZone[z]
			if not list then
				list = {}
				byZone[z] = list
			end
			list[#list + 1] = id
		end
	end)
	for _, list in pairs(byZone) do sort(list) end
	return byZone
end
ZQ.Index = index

local function zoneName(map)
	local X = ns.Codex
	local z = X and X.Zone(map)
	return (z and z.name) or ns.Compat.MapName(map) or (L["Zone"] .. " " .. map)
end

local CONTINENT = { [0] = L["Eastern Kingdoms"], [1] = L["Kalimdor"] }

-- Counted for this character: of its side, race and class.
local function forMe(rec, p)
	local why = ns.Lookup.QuestBlock(rec, p)
	return not NOT_FOR[why] and not Kit.Holiday(rec.id)
end

function ZQ.Zones()
	local idx = index()
	if not idx then return {} end
	local X, C, p = ns.Codex, ns.Compat, ns.Lookup.PlayerInfo()
	local out = {}
	for map, list in pairs(idx) do
		local z = X.Zone(map)
		if z then
			local total, done, lo, hi = 0, 0, nil, nil
			for _, id in ipairs(list) do
				local rec = X.Quest(id)
				if rec and forMe(rec, p) then
					total = total + 1
					if C.IsQuestCompleted(id) then done = done + 1 end
					local lv = rec.level
					if lv and lv > 0 then
						lo = (not lo or lv < lo) and lv or lo
						hi = (not hi or lv > hi) and lv or hi
					end
				end
			end
			if total > 0 then
				local c = C.MapToWorld(map, 50, 50)
				out[#out + 1] = { map = map, name = zoneName(map), continent = c, continentName = CONTINENT[c] or L["Elsewhere"],
					total = total, done = done, minLevel = lo, maxLevel = hi }
			end
		end
	end
	sort(out, function(a, b)
		local ca, cb = a.continent or 99, b.continent or 99
		if ca ~= cb then return ca < cb end
		if (a.minLevel or 0) ~= (b.minLevel or 0) then return (a.minLevel or 0) < (b.minLevel or 0) end
		return a.name < b.name
	end)
	return out
end

local function fold(s)
	s = (s or ""):lower():gsub("[%s%p]", "")
	return s
end

function ZQ.Find(text)
	local want = fold(text)
	if want == "" then return nil, {} end
	local exact, part = nil, {}
	for _, z in ipairs(ZQ.Zones()) do
		local f = fold(z.name)
		if f == want then exact = z.map end
		if f:find(want, 1, true) then part[#part + 1] = z end
	end
	if exact then return exact, part end
	if #part == 1 then return part[1].map, part end
	return nil, part
end

---------------------------------------------------------------------------
-- The plan
---------------------------------------------------------------------------

local function done(id) return ns.Compat.IsQuestCompleted(id) and true or false end
local function inLog(id) return ns.Compat.IsOnQuest(id) and true or false end

local function titleOf(id)
	local rec = ns.Codex.Quest(id)
	return (rec and rec.title) or ns.Compat.GetQuestTitle(id) or (L["Quest"] .. " " .. id)
end

-- A breadcrumb: taking `target` closes `crumb`, which is handed in where
-- `target` is given.
local function breadcrumb(crumb, target)
	local ends, starts = crumb["end"] or {}, target.start or {}
	for _, a in ipairs(ends.npc or {}) do
		for _, b in ipairs(starts.npc or {}) do
			if a == b then return true end
		end
	end
	for _, a in ipairs(ends.object or {}) do
		for _, b in ipairs(starts.object or {}) do
			if a == b then return true end
		end
	end
	return false
end

-- Why the character can't do quest rec now (not counting prerequisites), or nil.
local function blocked(rec, p)
	local why, text = ns.Lookup.QuestBlock(rec, p)
	if NOT_FOR[why] or Kit.Holiday(rec.id) then return "notfor", text end
	if why == "done" then return "done" end
	if why == "level" then return "level", format(WHY.level, rec.minLevel or 0) end
	if why == "profession" then return "profession", text end
	if not inLog(rec.id) then
		for _, by in ipairs(rec.closedBy or {}) do
			if done(by) or inLog(by) then return "closed", format(WHY.closed, ns.Quoted(titleOf(by)) or "?") end
		end
	end
	local dungeon = not ns.Compat.IsQuestReadyForTurnIn(rec.id) and Kit.Dungeon(rec)
	if dungeon then return "dungeon", format(WHY.dungeon, dungeon) end
	return nil
end

function ZQ.Plan(map)
	map = tonumber(map)
	local X, C, Lk = ns.Codex, ns.Compat, ns.Lookup
	if not (X and Lk and Lk.QuestStep) then return nil, "missing" end
	local idx = index()
	if not idx then return nil, "missing" end
	if not map or not idx[map] then return nil, "unknown" end
	local p = Lk.PlayerInfo()
	local from = ns.PlayerPoint()
	local plan = { map = map, name = zoneName(map), total = 0, done = 0, routed = 0, away = 0, doneList = {}, leftOut = {}, stops = {}, from = from }
	local leftOut, reasons = plan.leftOut, {} -- reasons: id -> text of why it can't be done
	local function leave(id, why, text)
		if reasons[id] then return end
		reasons[id] = text or why
		leftOut[#leftOut + 1] = { quest = id, title = titleOf(id), why = why, text = text or WHY[why] }
	end
	-- The zone's quests: counted, done, left out or candidates.
	local want, order = {}, {} -- want[id] = rec (in the route), order: ids in the order met
	local zoneSet = {}
	for _, id in ipairs(idx[map]) do
		local rec = X.Quest(id)
		if rec then
			zoneSet[id] = true
			local why, text = blocked(rec, p)
			if why ~= "notfor" then plan.total = plan.total + 1 end
			if why == "done" then
				plan.done = plan.done + 1
				plan.doneList[#plan.doneList + 1] = { quest = id, title = rec.title }
			elseif why and why ~= "notfor" then
				leave(id, why, text)
			elseif not why then
				want[id] = rec
				order[#order + 1] = id
			end
		end
	end
	-- Exclusive pairs: taking one closes the other. A breadcrumb stays before
	-- the quest it leads to; of two true alternatives the route keeps the one
	-- in the log, else the lower id.
	local crumbs = {} -- target id -> { crumb id, ... }
	for _, id in ipairs(order) do
		local rec = want[id]
		for _, by in ipairs(rec and rec.closedBy or {}) do
			local other = want[by]
			if other and rec then
				if breadcrumb(rec, other) then
					crumbs[by] = crumbs[by] or {}
					crumbs[by][#crumbs[by] + 1] = id
				elseif not breadcrumb(other, rec) then
					local keep = (inLog(id) and id) or (inLog(by) and by) or math.min(id, by)
					local drop = keep == id and by or id
					want[drop] = nil
					leave(drop, "exclusive", format(WHY.exclusive, ns.Quoted(titleOf(keep)) or "?"))
					if drop == id then break end
				end
			end
		end
	end
	-- Prerequisites, to a fixed point: every open one comes into the route
	-- (from another zone too), or the quest needing it is left out.
	local away = {}
	local changed = true
	while changed do
		changed = false
		for _, id in ipairs(order) do
			local rec = want[id]
			if rec and not inLog(id) then
				for _, r in ipairs(Lk.QuestChain(id, p)) do
					local rid = r.id
					if rid ~= id and not done(rid) and not want[rid] then
						local why, text = blocked(r, p)
						if not why and not reasons[rid] then
							want[rid] = r
							order[#order + 1] = rid
							if not zoneSet[rid] then away[rid] = true end
							changed = true
						else
							want[id] = nil
							leave(id, "prereq", format(WHY.prereq, ns.Quoted(r.title) or "?", reasons[rid] or text or WHY.nodata))
							changed = true
							break
						end
					end
				end
			end
		end
	end
	-- The quests' goals.
	local steps = {}
	local level = p.level or 1
	for _, id in ipairs(order) do
		local rec = want[id]
		if rec then
			local step = Lk.QuestStep(rec, from, { direct = true })
			local accept, work, turnin = Kit.ObjectiveGoals(step)
			local held, ready = inLog(id), C.IsQuestReadyForTurnIn(id)
			if not turnin or not Kit.Located(turnin) or (not held and not accept) then
				want[id] = nil
				leave(id, "nodata")
			elseif not held and accept and not Kit.Located(accept) and accept.item and (C.GetItemCount(accept.item, true) or 0) == 0 then
				want[id] = nil
				leave(id, "item", format(WHY.item, accept.itemName or ("#" .. accept.item)))
			elseif not ready and Kit.Elite(work, level) then
				want[id] = nil
				local e = Kit.Elite(work, level)
				leave(id, "elite", e.lvl and (WHY.elite .. " (" .. format(L["level %d"], e.lvl) .. ")") or nil)
			else
				steps[id] = { accept = not held and accept or nil, work = not ready and work or {}, turnin = turnin, note = step.note }
			end
		end
	end
	-- A quest left out above takes the quests that needed it with it.
	changed = true
	while changed do
		changed = false
		for _, id in ipairs(order) do
			local rec = want[id]
			if rec and not inLog(id) then
				for _, pid in ipairs(rec.pre or {}) do
					if not done(pid) and not want[pid] then
						want[id], steps[id] = nil, nil
						leave(id, "prereq", format(WHY.prereq, ns.Quoted(titleOf(pid)) or "?", reasons[pid] or WHY.nodata))
						changed = true
						break
					end
				end
				local any = rec.preAny or {}
				if want[id] and #any > 0 then
					local ok = false
					for _, pid in ipairs(any) do
						if done(pid) or want[pid] then ok = true; break end
					end
					if not ok then
						want[id], steps[id] = nil, nil
						leave(id, "prereq", format(WHY.prereq, ns.Quoted(titleOf(any[1])) or "?", reasons[any[1]] or WHY.nodata))
						changed = true
					end
				end
			end
		end
	end
	-- Stops: A(q) its accept, W(q) its work, T(q) its turn-in.
	local stops, A, T = plan.stops, {}, {}
	local function add(s)
		s.deps = s.deps or {}
		stops[#stops + 1] = s
		return #stops
	end
	for _, id in ipairs(order) do
		local s = steps[id]
		if s then
			local rec, held = want[id], inLog(id)
			local first
			if s.accept then
				local p0 = Kit.Point(s.accept)
				local g = s.accept
				local placed = p0 or Kit.Point(s.work[1] or {}) or Kit.Point(s.turnin)
				A[id] = add({ key = "a" .. id, title = g.npcName or g.objName or rec.title, goals = { g }, inP = placed, outP = placed, log = 1, quest = id })
				first = A[id]
			end
			local work = {}
			local unplaced = {}
			for k, g in ipairs(s.work) do
				local pt = Kit.Point(g)
				if pt then
					work[#work + 1] = add({ key = "w" .. id .. ":" .. k, title = rec.title, goals = { g }, inP = pt, outP = pt, note = #work == 0 and s.note or nil, deps = first and { first } or {}, quest = id })
				else
					unplaced[#unplaced + 1] = g
				end
			end
			local goals = {}
			for _, g in ipairs(unplaced) do goals[#goals + 1] = g end
			goals[#goals + 1] = s.turnin
			local tp = Kit.Point(s.turnin)
			local deps = {}
			if first then deps[1] = first end
			for _, w in ipairs(work) do deps[#deps + 1] = w end
			T[id] = add({ key = "t" .. id, title = s.turnin.npcName or s.turnin.objName or rec.title, goals = goals, inP = tp, outP = tp, log = held and 0 or (s.accept and -1 or 0), deps = deps, quest = id })
			plan.routed = plan.routed + 1
			if away[id] then plan.away = plan.away + 1 end
		end
	end
	-- An accept after the turn-ins it needs: all of `pre`, the routed one of
	-- `preAny` (when none is done), a breadcrumb's.
	for _, id in ipairs(order) do
		local a, rec = A[id], want[id]
		if a and rec then
			local deps = stops[a].deps
			for _, pid in ipairs(rec.pre or {}) do
				if T[pid] then deps[#deps + 1] = T[pid] end
			end
			local any = rec.preAny or {}
			local anyDone = false
			for _, pid in ipairs(any) do
				if done(pid) then anyDone = true; break end
			end
			if not anyDone then
				for _, pid in ipairs(any) do
					if T[pid] then deps[#deps + 1] = T[pid]; break end
				end
			end
			for _, cid in ipairs(crumbs[id] or {}) do
				if T[cid] then deps[#deps + 1] = T[cid] end
			end
			if #deps == 0 then stops[a].deps = {} end
		end
	end
	return plan
end

-- The log's room the route may fill: the cap, less what is in the log and a spare.
local function room()
	local C = ns.Compat
	return math.max(1, (C.GetLogCap and C.GetLogCap() or 25) - #(C.GetLogQuests() or {}) - LOG_SPARE)
end

local last = {} -- map -> the last plan, for the zone list's detail view

local function guide(map)
	local plan, reason = ZQ.Plan(map)
	if not plan then return nil, reason end
	last[plan.map] = plan
	if #plan.stops == 0 then return nil, plan.done >= plan.total and "complete" or "leftout" end
	local points = { plan.from }
	for _, s in ipairs(plan.stops) do points[#points + 1] = s.inP end
	local travel = Kit.Travel(points)
	local order = Kit.Order(plan.stops, plan.from, FIELD, tostring(plan.map), travel, room())
	local steps = Kit.Steps(plan.stops, order, { zone = plan.map })
	local head = format(L["%s: %d of %d quests done. This route does %d more (%d outside the zone)."], plan.name, plan.done, plan.total, plan.routed, plan.away)
	if #plan.leftOut > 0 then head = head .. " " .. format(L["%d left out: the zone list says why."], #plan.leftOut) end
	steps[1].note = steps[1].note and (head .. " " .. steps[1].note) or head
	return { title = format(L["%s: every quest"], plan.name), steps = steps, category = "Lookup" }
end
ZQ.Guide = guide

if ns.Lookup and ns.Lookup.RegisterPlanner then ns.Lookup.RegisterPlanner(KIND, guide) end

-- The last plan of a zone (built when there is none).
function ZQ.Last(map)
	map = tonumber(map)
	if map and not last[map] then last[map] = ZQ.Plan(map) end
	return map and last[map] or nil
end

function ZQ.Open(map)
	local gid, why = ns.Lookup.Guide(KIND, map)
	local plan = ZQ.Last(map)
	if plan then
		ns.Print(format(L["%s: %d of %d quests done; %d to do in this route, %d left out."], plan.name, plan.done, plan.total, plan.routed, #plan.leftOut))
	end
	if not gid then
		if why == "tabs" then
			ns.Print(L["Six tabs is the limit. Close one to open another."])
		elseif why == "complete" then
			ns.Print(L["Every quest of this zone you can do is done."])
		elseif why == "leftout" then
			ns.Print(L["Nothing in this zone can be routed now: the zone list says why."])
		elseif why == "unknown" then
			ns.Print(L["No quests are known for that zone."])
		else
			ns.Print(L["The quest data isn't loaded (Polestar_Codex)."])
		end
	end
	return gid, why
end

-- Turned in or levelled: the counts move.
local function forget() last = {} end
ns.RegisterEvent("QUEST_TURNED_IN", forget)
ns.RegisterEvent("PLAYER_LEVEL_UP", forget)

ns.RegisterCommand("zone", function(rest)
	rest = rest or ""
	if rest == "" then
		if ns.UI and ns.UI.ShowZonePicker then ns.UI.ShowZonePicker() end
		return
	end
	local map, matches = ZQ.Find(rest)
	if map then
		ZQ.Open(map)
		if ns.UI and ns.UI.ShowZonePicker then ns.UI.ShowZonePicker(map) end
	elseif #matches > 1 then
		local names = {}
		for i, z in ipairs(matches) do
			if i > 8 then break end
			names[#names + 1] = z.name
		end
		ns.Print(format(L["More than one zone matches: %s"], table.concat(names, ", ")))
	else
		ns.Print(format(L["No zone called %s."], ns.Quoted(rest) or rest))
	end
end, L["Every quest of a zone in one guide: /polestar zone <name>, or the zone list"])
