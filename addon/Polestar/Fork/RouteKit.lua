-- Polestar Plus (the fork, FORK.md): what the quest log route (Fork/LogRoute.lua)
-- and the zone completionist (Fork/ZoneQuests.lua) share: the route's travel
-- costs, its order and the guide steps it becomes, and why a quest is left
-- out. Both are Lookup planner kinds (Lookup/Guide.lua): their guides are
-- built from the Codex, opened in a tab and rebuilt after /reload.
--
--   Kit.Travel(points) -> travel(a, b)
--       seconds between two points, grouped by zone: on one map a straight
--       run (ns.DirectTravelCost); between maps the travel planner's estimate
--       (ns.TravelCost: flights, boats, portals) between the maps' hubs (the
--       point nearest each map's centre among `points`), once per pair of
--       maps, plus the runs to and from the hubs; never more than the
--       straight run where that is shorter. The planner runs a route search
--       per estimate: per zone pair keeps a log or a zone of 200 stops from
--       freezing the game.
--   Kit.Order(stops, from, field, key, travel, cap) -> order
--       stops = { { key, inP, outP, deps = { index, ... }, log }, ... }:
--       up to SMALL stops Dungeons.PlanStops (exact up to 12, else
--       nearest-next and cheapest insertion improved by moving runs); more,
--       nearest-next among the ready stops improved by Or-opt (runs of one
--       to three moved within a window); then a 2-opt pass that reverses runs
--       with no dependency inside them where that shortens the path. Every
--       stop stays after the stops it depends on, the log within `cap`. The
--       order is kept per character as CharState()[field][key], for a
--       rebuild without a position (after /reload).
--   Kit.Steps(stops, order, opts) -> steps
--       one step per stop, consecutive stops at the same NPC or object (or
--       within SAME_PLACE yards) merged into one; opts.zone marks the steps
--       outside it ("Outside <zone>").
--   Kit.ObjectiveGoals(step) -> accept, objectives, turnin
--       a Lookup.QuestStep's goals split in three
--   Kit.Dungeon(rec) -> instance name | nil   -- its work is inside a dungeon or raid
--   Kit.Elite(goals, level) -> group | nil    -- an elite the character should not solo
--   Kit.Grey(q, level) -> bool                -- no experience any more
--   Kit.Holiday(q) -> bool                    -- a holiday's quest (the quest database's `holiday`)

local ADDON, ns = ...
local L = ns.L

local Kit = {}
ns.ForkRoute = Kit

local type, ipairs, pairs, format = type, ipairs, pairs, string.format

local SAME_PLACE = 30 -- yards: stops this close become one step
local SOLO_MARGIN = 5 -- levels above an elite's that make it soloable
local FAR = 1e9

local function located(p)
	return type(p) == "table" and p.map ~= nil and p.x ~= nil and p.y ~= nil
end
Kit.Located = located

---------------------------------------------------------------------------
-- Travel
---------------------------------------------------------------------------

function Kit.Travel(points)
	local direct, planned = ns.DirectTravelCost, ns.TravelCost or ns.DirectTravelCost
	-- Each map's hub: the point nearest the mean of its points.
	local sums, hubs = {}, {}
	for _, p in ipairs(points or {}) do
		if located(p) then
			local s = sums[p.map]
			if not s then
				s = { x = 0, y = 0, n = 0, pts = {} }
				sums[p.map] = s
			end
			s.x, s.y, s.n = s.x + p.x, s.y + p.y, s.n + 1
			s.pts[#s.pts + 1] = p
		end
	end
	for map, s in pairs(sums) do
		local cx, cy, best, bd = s.x / s.n, s.y / s.n, nil, nil
		for _, p in ipairs(s.pts) do
			local d = (p.x - cx) ^ 2 + (p.y - cy) ^ 2
			if not bd or d < bd then best, bd = p, d end
		end
		hubs[map] = best
	end
	local memo = {}
	return function(a, b)
		if not (located(a) and located(b)) then return nil end
		local straight = direct(a, b)
		if a.map == b.map then return straight end
		local ha, hb = hubs[a.map] or a, hubs[b.map] or b
		local k = a.map .. ">" .. b.map
		local t = memo[k]
		if t == nil then
			t = planned(ha, hb) or false
			memo[k] = t
		end
		if not t then return straight end
		local via = t + (direct(a, ha) or 0) + (direct(hb, b) or 0)
		if straight and straight < via then return straight end
		return via
	end
end

---------------------------------------------------------------------------
-- Order
---------------------------------------------------------------------------

-- Travel memoised by the point tables (each stop's points are its own tables).
local function memoised(travel)
	local memo = {}
	return function(a, b)
		if a == nil or b == nil then return FAR end
		if a == b then return 0 end
		local row = memo[a]
		if not row then
			row = {}
			memo[a] = row
		end
		local t = row[b]
		if t == nil then
			t = travel(a, b) or FAR
			row[b] = t
		end
		return t
	end
end

local function dependsOf(stops)
	local depends = {} -- stop -> set of stops it depends on
	for i, s in ipairs(stops) do
		local set = {}
		for _, d in ipairs(s.deps or {}) do set[d] = true end
		depends[i] = set
	end
	return depends
end

local function capOkOf(stops, cap)
	return function(x)
		if not cap then return true end
		local open = 0
		for _, i in ipairs(x) do
			open = open + (stops[i].log or 0)
			if open > cap then return false end
		end
		return true
	end
end

-- A 2-opt pass over `order` (stop indices): reverse o[i..j] (at most MAX_RUN
-- stops) when no stop in the run depends on another in it (the reversal
-- would swap them) and the path gets shorter; the log's room (cap) holds.
local MAX_RUN = 30
local function twoOpt(stops, order, from, travel, cap, T)
	local o = {}
	for i, v in ipairs(order) do o[i] = v end
	local n = #o
	if n < 4 then return o end
	T = T or memoised(travel)
	local capOk = capOkOf(stops, cap)
	local depends = dependsOf(stops)
	local function outAt(k) return k == 0 and from or stops[o[k]].outP end
	local function inAt(k) return stops[o[k]].inP end
	local rounds, improved = 0, true
	while improved and rounds < 8 do
		improved, rounds = false, rounds + 1
		local i = 1
		while i <= n - 1 do
			-- Forward and backward costs inside the run as it grows.
			local fwd, bwd = 0, 0
			local members = { o[i] }
			local moved = false
			for j = i + 1, math.min(n, i + MAX_RUN) do
				local ok = true
				for _, m in ipairs(members) do
					if depends[o[j]][m] or depends[m][o[j]] then ok = false; break end
				end
				if not ok then break end
				fwd = fwd + T(outAt(j - 1), inAt(j))
				bwd = bwd + T(stops[o[j]].outP, inAt(j - 1))
				members[#members + 1] = o[j]
				local before = T(outAt(i - 1), inAt(i)) + fwd + (j < n and T(outAt(j), inAt(j + 1)) or 0)
				local after = T(outAt(i - 1), inAt(j)) + bwd + (j < n and T(stops[o[i]].outP, inAt(j + 1)) or 0)
				if after + 0.5 < before then
					local x = {}
					for k = 1, n do x[k] = o[k] end
					for k = 0, j - i do x[i + k] = o[j - k] end
					if capOk(x) then
						o = x
						improved, moved = true, true
						break
					end
				end
			end
			if not moved then i = i + 1 end
		end
	end
	return o
end
Kit.TwoOpt = twoOpt

-- Nearest-next among the stops whose deps are behind (and that fit the log's
-- room; none fitting, any ready one). -> order
local function greedy(stops, from, T, cap)
	local n, order, placed = #stops, {}, {}
	local waiting = {} -- stop -> deps not placed yet
	local dependents = {}
	for i, s in ipairs(stops) do
		waiting[i] = 0
		for _, d in ipairs(s.deps or {}) do
			waiting[i] = waiting[i] + 1
			dependents[d] = dependents[d] or {}
			dependents[d][#dependents[d] + 1] = i
		end
	end
	local here, open = from, 0
	for _ = 1, n do
		local bi, bc, any, ac
		for i = 1, n do
			if not placed[i] and waiting[i] == 0 then
				local c = T(here, stops[i].inP)
				if not ac or c < ac then any, ac = i, c end
				local log = stops[i].log or 0
				if (not cap or log <= 0 or open + log <= cap) and (not bc or c < bc) then bi, bc = i, c end
			end
		end
		bi = bi or any
		if not bi then break end -- a dependency cycle
		placed[bi] = true
		order[#order + 1] = bi
		open = open + (stops[bi].log or 0)
		here = stops[bi].outP or stops[bi].inP
		for _, d in ipairs(dependents[bi] or {}) do waiting[d] = waiting[d] - 1 end
	end
	return order
end

-- Or-opt: runs of one to three stops moved up to WINDOW places away while
-- that shortens the path, every stop still after its deps, the room kept.
local WINDOW = 40
local function orOpt(stops, order, from, T, cap)
	local o = {}
	for i, v in ipairs(order) do o[i] = v end
	local n = #o
	local depends = dependsOf(stops)
	local capOk = capOkOf(stops, cap)
	local function outAt(k) return k <= 0 and from or stops[o[k]].outP end
	local function inAt(k) return stops[o[k]].inP end
	local function edge(k) return k < n and T(outAt(k), inAt(k + 1)) or 0 end
	local function movable(a, L, b)
		if b < a then
			for q = b + 1, a - 1 do
				for s = a, a + L - 1 do
					if depends[o[s]][o[q]] then return false end
				end
			end
		else
			for q = a + L, b do
				for s = a, a + L - 1 do
					if depends[o[q]][o[s]] then return false end
				end
			end
		end
		return true
	end
	local function moved(a, L, b)
		local x, run = {}, {}
		for k = a, a + L - 1 do run[#run + 1] = o[k] end
		for k = 0, n do
			if k > 0 and (k < a or k >= a + L) then x[#x + 1] = o[k] end
			if k == b then
				for _, v in ipairs(run) do x[#x + 1] = v end
			end
		end
		return x
	end
	for _ = 1, 6 do
		local any = false
		for L = 1, 3 do
			local a = 1
			while a <= n - L + 1 do
				local z = a + L - 1
				local out = (z < n and T(outAt(a - 1), inAt(z + 1)) or 0) - T(outAt(a - 1), inAt(a)) - edge(z)
				local done = false
				for b = math.max(0, a - 1 - WINDOW), math.min(n, z + WINDOW) do
					if b < a - 1 or b > z then
						local into = T(outAt(b), inAt(a)) + (b < n and T(outAt(z), inAt(b + 1)) or 0) - edge(b)
						if out + into < -0.5 and movable(a, L, b) then
							local x = moved(a, L, b)
							if capOk(x) then
								o, any, done = x, true, true
								break
							end
						end
					end
				end
				if not done then a = a + 1 end
			end
		end
		if not any then break end
	end
	return o
end

-- Every stop after its deps? -> true | false, index
function Kit.Valid(stops, order)
	local pos = {}
	for p, i in ipairs(order) do pos[i] = p end
	for p, i in ipairs(order) do
		for _, d in ipairs(stops[i].deps or {}) do
			if not pos[d] or pos[d] > p then return false, i end
		end
	end
	return #order == #stops
end

-- The kept order of a route (stop keys), for a rebuild without a position.
local function kept(stops, field, key)
	local s = ns.CharState and ns.CharState() or {}
	local all = type(s[field]) == "table" and s[field] or nil
	local keys = all and all[key]
	if type(keys) ~= "table" then return nil end
	local rank = {}
	for i, k in ipairs(keys) do rank[k] = i end
	local idx = {}
	for i = 1, #stops do idx[i] = i end
	table.sort(idx, function(a, b)
		local ra, rb = rank[stops[a].key] or (1e6 + a), rank[stops[b].key] or (1e6 + b)
		return ra < rb
	end)
	return idx
end

local function keep(stops, order, field, key)
	if not (ns.CharState and field and key) then return end
	local s = ns.CharState()
	if type(s[field]) ~= "table" then s[field] = {} end
	local keys = {}
	for i, k in ipairs(order) do keys[i] = stops[k].key end
	s[field][key] = keys
end

-- Up to SMALL stops, Dungeons.PlanStops (exact up to 12); more, the greedy
-- order improved by Or-opt (PlanStops' improvement over the whole route is
-- quadratic per move and does not finish for a zone's 200 stops). Both then
-- 2-opt.
local SMALL = 30
Kit.SMALL = SMALL

local function inOwnOrder(stops)
	local order, placed = {}, {}
	for _ = 1, #stops do
		for i, s in ipairs(stops) do
			if not placed[i] then
				local ok = true
				for _, d in ipairs(s.deps or {}) do ok = ok and placed[d] end
				if ok then
					placed[i] = true
					order[#order + 1] = i
					break
				end
			end
		end
	end
	return order
end

function Kit.Order(stops, from, field, key, travel, cap)
	local order
	if not from then
		order = kept(stops, field, key)
		if not (order and Kit.Valid(stops, order)) then order = inOwnOrder(stops) end
		return order
	end
	local T = memoised(travel)
	local D = ns.Dungeons
	if #stops <= SMALL and D and D.PlanStops then
		order = D.PlanStops(stops, from, nil, T, { cap = cap })
	end
	if not order or not Kit.Valid(stops, order) then
		order = greedy(stops, from, T, cap)
		if Kit.Valid(stops, order) then order = orOpt(stops, order, from, T, cap) end
	end
	if not Kit.Valid(stops, order) then order = inOwnOrder(stops) end
	order = twoOpt(stops, order, from, travel, cap, T)
	keep(stops, order, field, key)
	return order
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local function placeKey(g)
	if g.npc and (g.t == "accept" or g.t == "turnin" or g.t == "talk") then return "n" .. g.npc end
	if g.object and (g.t == "accept" or g.t == "turnin") then return "o" .. g.object end
	return nil
end

local function near(a, b)
	if not (located(a) and located(b)) or a.map ~= b.map then return false end
	local t = ns.DirectTravelCost(a, b)
	return t ~= nil and t * 7 <= SAME_PLACE
end

-- stops (each { title, goals, inP, outP, note }) in `order` -> steps.
function Kit.Steps(stops, order, opts)
	local zone = opts and opts.zone
	local steps, last, lastKey, lastAt = {}, nil, nil, nil
	for _, i in ipairs(order) do
		local s = stops[i]
		local first = s.goals[1]
		local k = first and placeKey(first)
		local at = s.inP
		local merge = last and ((k and k == lastKey) or (not k and not lastKey and near(at, lastAt)))
		if merge then
			for _, g in ipairs(s.goals) do last.goals[#last.goals + 1] = g end
			if s.note and not (last.note or ""):find(s.note, 1, true) then last.note = last.note and (last.note .. " " .. s.note) or s.note end
		else
			last = { title = s.title, goals = {}, note = s.note }
			for _, g in ipairs(s.goals) do last.goals[#last.goals + 1] = g end
			if zone and located(at) and at.map ~= zone then
				local where = ns.Compat.MapName(at.map) or "?"
				last.note = format(L["Outside %s: this part of the chain is in %s."], ns.Compat.MapName(zone) or "?", where) .. (last.note and (" " .. last.note) or "")
				last.title = format(L["%s (%s)"], last.title or "?", where)
				last.away = true
			end
			steps[#steps + 1] = last
		end
		lastKey, lastAt = k, s.outP or at
	end
	return steps
end

-- A Lookup.QuestStep's goals: its accept, the work between, its turn-in.
function Kit.ObjectiveGoals(step)
	local goals = step and step.goals or {}
	local accept, turnin, work = nil, nil, {}
	for _, g in ipairs(goals) do
		if g.t == "accept" and not accept then accept = g
		elseif g.t == "turnin" then turnin = g
		elseif g.t ~= "note" then work[#work + 1] = g end
	end
	return accept, work, turnin
end

-- Goals at one place, for a stop: { title, goals, inP, outP }.
function Kit.Point(g)
	if not located(g) then return nil end
	return { map = g.map, x = g.x, y = g.y, f = g.f }
end

---------------------------------------------------------------------------
-- Why a quest is left out
---------------------------------------------------------------------------

local function instanceOfNpc(id)
	local C = ns.Codex
	local npc = id and C.Npc(id)
	if not npc then return nil end
	if npc.instance and npc.instance ~= "" then return npc.instance end
	return nil
end

local function instanceName(key)
	local C, D = ns.Codex, ns.Dungeons
	local inst = (D and D.Get and D.Get(key)) or (C.Instance and C.Instance(key))
	return inst and inst.name or key
end

-- The dungeon or raid a quest's work is in: a kill or talk whose NPC stands
-- only inside one, an object only inside one, or an item every placed
-- source of which is inside one. -> name | nil
function Kit.Dungeon(rec)
	local C = ns.Codex
	if not (C and rec) then return nil end
	for _, o in ipairs(rec.objectives or {}) do
		local key
		if (o.type == "kill" or o.type == "talk") and o.id then
			key = instanceOfNpc(o.id)
		elseif o.type == "object" and o.id then
			local obj = C.Object(o.id)
			key = obj and obj.instance and (#(obj.spawns or {}) == 0) and obj.instance or nil
		elseif o.type == "item" and o.id then
			local item = C.Item(o.id)
			local inside, outside = nil, false
			for _, src in ipairs(item and item.sources or {}) do
				if src.type == "drop" and src.npc then
					local k = instanceOfNpc(src.npc)
					if k then inside = inside or k else
						local npc = C.Npc(src.npc)
						if npc and #(npc.spawns or {}) > 0 then outside = true end
					end
				elseif src.type == "object" then
					if src.instance then inside = inside or src.instance else outside = true end
				elseif src.type == "vendor" or src.type == "craft" then
					outside = true
				end
			end
			if inside and not outside then key = inside end
		end
		if key then return instanceName(key) end
	end
	return nil
end

-- The first `group` (an elite target, Lookup.QuestStep) the character is not
-- SOLO_MARGIN levels above. -> group | nil
function Kit.Elite(goals, level)
	for _, g in ipairs(goals or {}) do
		local grp = g.group
		if type(grp) == "table" and grp.kind == "elite" then
			if not (grp.lvl and level and level >= grp.lvl + SOLO_MARGIN) then return grp end
		end
	end
	return nil
end

function Kit.Grey(q, level)
	local C = ns.Compat
	local qlvl = level and C.GetQuestLevel and C.GetQuestLevel(q)
	if not qlvl then
		local rec = ns.Codex and ns.Codex.Quest(q)
		qlvl = rec and rec.level
	end
	return (qlvl and level and C.IsQuestTrivial and C.IsQuestTrivial(qlvl, level)) and true or false
end

-- A holiday's quest (Lunar Festival, Hallow's End): only while it runs. The
-- quest database knows (Polestar_QuestDB's `holiday`), loaded once for it.
local triedDB = false
function Kit.Holiday(q)
	local Q = ns.QuestDB
	if not Q then return false end
	if not Q.IsLoaded() and not triedDB and ns.Data and ns.Data.Pack then
		triedDB = true
		pcall(ns.Data.Pack, Q.ADDON)
	end
	local r = Q.IsLoaded() and Q.QuestRecord(q)
	return (r and r[Q.F.HOLIDAY] ~= nil) and true or false
end
