-- Polestar Plus (the fork, FORK.md): "Empty your quest log", one route that
-- finishes and hands in every quest in the log (Lookup planner kind
-- "questlog", id "all": guide "lookup/questlog/all").
--
-- It grows the Quest room's hand-in guide (UI/QuestRoom.lua carriedGuide:
-- the finished quests no route hands in, one stop per ender, nearest first)
-- to the whole log, whatever the routes in the tabs do:
--   * an unfinished quest: its objectives (Lookup.QuestStep: kill, collect,
--     use, talk and interact goals at their spawn areas, the objective
--     markers' spots) as stops of their own, each before its turn-in;
--   * every quest: its turn-in (RoutePlan.Ender for a finished one, the
--     QuestStep's for the rest); quests handed in to one NPC or object
--     share one stop, after the objectives of each of them;
--   * the order: ForkRoute.Order over ForkRoute.Travel (zones grouped, the
--     travel planner's flights and boats between them; nearest-next and
--     cheapest insertion improved by moving runs, then 2-opt; every
--     objective before its quest's turn-in), from where the player stands.
-- What it cannot route is listed, never dropped (LR.LeftOut, the Quest
-- room's "logroute" list): no data, no place known for its work or its
-- turn-in, inside a dungeon or raid, an elite the character should not solo,
-- and grey unfinished quests (with the Quest room's Abandon). A grey quest
-- that is finished is still handed in.
--
--   LR.Plan() -> plan | nil, reason
--       plan = { stops, quests (routed count), zones, leftOut = { { quest, title, why, text, grey } } }
--   LR.LeftOut() -> the list of the last plan (built when nil)
--   LR.Open() -> guideId | nil, reason   -- builds, opens the tab, says what it left out
--   /polestar emptylog (also /polestar logroute)

local ADDON, ns = ...
local L = ns.L

local LR = {}
ns.ForkLogRoute = LR

local Kit = ns.ForkRoute
local type, ipairs, format = type, ipairs, string.format

local KIND, ID = "questlog", "all"
local FIELD = "forkLogRoute"
local MERGE_YARDS = 100 -- a quest's objectives this close are one stop

local last -- the last plan's leftOut

local WHY = {
	nodata = L["No quest data: Polestar doesn't know where it is done"],
	noplace = L["Where its work is done is not known"],
	noend = L["Where it is turned in is not known"],
	dungeon = L["Inside %s: do it with a group"],
	elite = L["Elite: group advised"],
	grey = L["Grey: no XP any more"],
}

local function leave(list, q, title, why, text, grey)
	list[#list + 1] = { quest = q, title = title or ns.Compat.GetQuestTitle(q) or (L["Quest"] .. " " .. q), why = why, text = text or WHY[why], grey = grey or nil }
end

local function enderKey(g)
	if g.npc then return "n" .. g.npc end
	if g.object then return "o" .. g.object end
	return nil
end

local function close(a, b)
	if not (Kit.Located(a) and Kit.Located(b)) or a.map ~= b.map then return false end
	local t = ns.DirectTravelCost(a, b)
	return t ~= nil and t * 7 <= MERGE_YARDS
end

function LR.Plan()
	local C, X, Lk, P = ns.Compat, ns.Codex, ns.Lookup, ns.RoutePlan
	if not (X and Lk and Lk.QuestStep) then return nil, "missing" end
	local loaded, reason = X.Load()
	if not loaded then return nil, reason or "missing" end
	local level = (C.GetPlayerInfo() or {}).level or 1
	local from = ns.PlayerPoint()
	local stops, enders, leftOut, routed = {}, {}, {}, 0
	local function add(s)
		s.deps = s.deps or {}
		stops[#stops + 1] = s
		return #stops
	end
	for _, q in ipairs(C.GetLogQuests() or {}) do
		local rec = X.Quest(q)
		local title = (rec and rec.title) or C.GetQuestTitle(q)
		local ready = C.IsQuestReadyForTurnIn(q)
		local grey = Kit.Grey(q, level)
		local turnin, work, note
		if not rec then
			leave(leftOut, q, title, "nodata")
		elseif not ready and grey then
			leave(leftOut, q, title, "grey", nil, true)
		else
			local dungeon = not ready and Kit.Dungeon(rec)
			if dungeon then
				leave(leftOut, q, title, "dungeon", format(WHY.dungeon, dungeon))
			else
				if ready then
					local e = P and P.Ender(q)
					if e then
						turnin = { t = "turnin", quest = q, title = title, npc = e.npc, npcName = e.npc and e.name or nil,
							object = e.object, objName = e.object and e.name or nil, map = e.map, x = e.x, y = e.y, f = e.f }
						if e.inside then note = format(L["%s: inside %s."], e.name or "?", e.zone or "?") end
					end
					work = {}
				else
					local step = Lk.QuestStep(rec, from, { direct = true })
					local _
					_, work, turnin = Kit.ObjectiveGoals(step)
					note = step and step.note
					local elite = Kit.Elite(work, level)
					if elite then
						leave(leftOut, q, title, "elite", elite.lvl and (WHY.elite .. " (" .. format(L["level %d"], elite.lvl) .. ")") or nil)
						turnin = false
					end
				end
				if turnin == nil or (turnin and not Kit.Located(turnin)) then
					leave(leftOut, q, title, "noend")
				elseif turnin then
					local placed, unplaced = {}, {}
					for _, g in ipairs(work) do
						if Kit.Located(g) then placed[#placed + 1] = g else unplaced[#unplaced + 1] = g end
					end
					if not ready and #work > 0 and #placed == 0 then
						leave(leftOut, q, title, "noplace")
					else
						-- The quest's objective stops: goals close together share one.
						local mine = {}
						for _, g in ipairs(placed) do
							local s
							for _, i in ipairs(mine) do
								if close(stops[i].inP, g) then s = stops[i]; break end
							end
							if s then
								s.goals[#s.goals + 1] = g
							else
								local p = Kit.Point(g)
								mine[#mine + 1] = add({ key = "o" .. q .. ":" .. (#mine + 1), title = title, goals = { g }, inP = p, outP = p, note = #mine == 0 and note or nil })
							end
						end
						-- Its turn-in: the stop of its ender, with every quest it takes.
						local key = enderKey(turnin) or ("q" .. q)
						local e = enders[key]
						if not e then
							local p = Kit.Point(turnin)
							e = add({ key = "t" .. key, title = turnin.npcName or turnin.objName or L["Quest giver"], goals = {}, inP = p, outP = p, note = ready and note or nil })
							enders[key] = e
						end
						local es = stops[e]
						-- Work with no known place is done before the turn-in, where the quest log says.
						for _, g in ipairs(unplaced) do es.goals[#es.goals + 1] = g end
						es.goals[#es.goals + 1] = turnin
						for _, i in ipairs(mine) do es.deps[#es.deps + 1] = i end
						routed = routed + 1
					end
				end
			end
		end
	end
	last = leftOut
	-- Kept in the character's saved variables too, so the list can be read
	-- outside the game after a /reload (quest id, title, reason).
	if ns.CharState then
		local kept = {}
		for i, o in ipairs(leftOut) do kept[i] = { quest = o.quest, title = o.title, why = o.why, text = o.text } end
		ns.CharState().forkLogLeftOut = kept
	end
	local zones, seen = 0, {}
	for _, s in ipairs(stops) do
		if not seen[s.inP.map] then
			seen[s.inP.map] = true
			zones = zones + 1
		end
	end
	return { stops = stops, quests = routed, zones = zones, leftOut = leftOut, from = from }
end

-- The last plan's left-out quests still in the log (one abandoned or handed
-- in since drops off without a new plan: the Quest room lays out on every
-- QUEST_LOG_UPDATE).
function LR.LeftOut()
	if last == nil then LR.Plan() end
	local out = {}
	for _, q in ipairs(last or {}) do
		if ns.Compat.IsOnQuest(q.quest) then out[#out + 1] = q end
	end
	return out
end

local function guide()
	local plan, reason = LR.Plan()
	if not plan then return nil, reason end
	if #plan.stops == 0 then return nil, #plan.leftOut > 0 and "leftout" or "nothing" end
	local points = { plan.from }
	for _, s in ipairs(plan.stops) do points[#points + 1] = s.inP end
	local travel = Kit.Travel(points)
	local order = Kit.Order(plan.stops, plan.from, FIELD, ID, travel)
	local steps = Kit.Steps(plan.stops, order)
	local head = format(L["Every quest in your log, in one route: %d quests in %d zones."], plan.quests, plan.zones)
	if #plan.leftOut > 0 then head = head .. " " .. format(L["%d left out: /polestar emptylog lists them."], #plan.leftOut) end
	steps[1].note = steps[1].note and (head .. " " .. steps[1].note) or head
	return { title = L["Empty your quest log"], steps = steps }
end
LR.Guide = guide

if ns.Lookup and ns.Lookup.RegisterPlanner then ns.Lookup.RegisterPlanner(KIND, guide) end

-- Builds and opens the route; the quests it left out open in the Quest room.
function LR.Open()
	local Lk = ns.Lookup
	local gid, why = Lk.Guide(KIND, ID)
	local out = last or {}
	if gid then
		ns.Print(format(L["Quest log route opened: %d left out."], #out))
	elseif why == "tabs" then
		ns.Print(L["Six tabs is the limit. Close one to open another."])
	elseif why == "nothing" then
		ns.Print(L["Your quest log is empty."])
	elseif why == "leftout" then
		ns.Print(L["None of the quests in your log can be routed."])
	else
		ns.Print(L["The quest data isn't loaded (Polestar_Codex)."])
	end
	if #out > 0 and ns.UI and ns.UI.ShowQuestRoom then ns.UI.ShowQuestRoom("logroute") end
	return gid, why
end

ns.RegisterCommand("emptylog", function() LR.Open() end, L["One route that finishes and hands in every quest in your log"])
ns.RegisterCommand("logroute", function() LR.Open() end, nil, true)
