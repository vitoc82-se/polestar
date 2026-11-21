-- Polestar Plus (the fork, FORK.md): the zone completionist's zone list. A
-- window in the Quest room's style (UI/QuestRoom.lua): every zone with
-- quests for this character, grouped by continent and sorted by level, each
-- with "X of Y done" and its own Guide me (ForkZoneQuests.Open); the zone
-- the player stands in first. A row opens its zone's detail: the progress,
-- the quests the guide leaves out with why, and the ones already done.
--
--   UI.ShowZonePicker()      -- the list
--   UI.ShowZonePicker(map)   -- one zone's detail
--   /polestar zone           -- the list (Fork/ZoneQuests.lua)
--
-- Built on first use; colours are Theme tokens only.

local ADDON, ns = ...
local UI, Theme, W, Anim = ns.UI, ns.Theme, ns.Widgets, ns.Anim
local L = ns.L

local format = string.format

local WIDTH = 420
local PAD = 24
local HEAD_H = 56
local ROW_H = 36
local HEAD_ROW_H = 24
local ROW_GAP = 6
local MAX_ROWS = 10
local MARGIN = 24
local BUTTON_H = 28

local F

local function build()
	F = CreateFrame("Frame", "PolestarZonePicker", ns.UIParent)
	F:SetFrameStrata("DIALOG")
	F:SetToplevel(true)
	F:SetClampedToScreen(true)
	F:EnableMouse(true)
	F:SetMovable(true)
	F:SetWidth(WIDTH)
	F:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	F:Hide()
	Theme.Skin(F, "window")

	local head = CreateFrame("Frame", nil, F)
	head:SetPoint("TOPLEFT", F, "TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", F, "TOPRIGHT", -1, -1)
	head:SetHeight(HEAD_H)
	ns.DragWindow(head, F)
	F.Band = Theme.Band(head, "BACKGROUND", -5)
	F.Band:SetAllPoints(head)
	F.Band:SetTexCoord(Theme.BandCoords(WIDTH - 2, HEAD_H))
	F.Close = W.IconButton(head, "close", 28, L["Close"], function() F:Hide() end, 14)
	F.Close:SetPoint("TOPRIGHT", head, "TOPRIGHT", -12, -14)
	W.FrameClose(F, F.Close)
	F.Title = W.Text(head, "title", "text")
	F.Title:SetPoint("LEFT", head, "LEFT", PAD, 0)
	F.Title:SetPoint("RIGHT", F.Close, "LEFT", -8, 0)
	F.Title:SetJustifyH("LEFT")
	F.Title:SetWordWrap(true)
	F.Title:SetMaxLines(2)

	F.Hint = W.Text(F, "note", "textDim")
	F.Hint:SetPoint("TOPLEFT", F, "TOPLEFT", PAD, -(HEAD_H + 12))
	F.Hint:SetWidth(WIDTH - PAD * 2)
	F.Hint:SetJustifyH("LEFT")
	F.Hint:SetWordWrap(true)

	F.List = W.Scroll(F)
	F.List.Child:SetWidth(WIDTH - PAD * 2)

	F.GuideMe = W.Button(F, L["Guide me"], function()
		if F.psMap then ns.ForkZoneQuests.Open(F.psMap) end
		UI.LayoutZonePicker()
	end, { height = BUTTON_H })
	F.GuideMe:Hide()
	F.Back = W.Button(F, L["All zones"], function() UI.ShowZonePicker() end, { ghost = true, height = BUTTON_H })
	F.Back:Hide()

	F.rows = {}
	F:SetScript("OnShow", function(self) Anim.To(self, "alpha", 0, 1, Anim.FAST, "out") end)
	ns.CloseOnEscape("PolestarZonePicker")
	if ns.Gamepad and ns.Gamepad.Register then ns.Gamepad.Register(F, {}) end
end

local function rowEnter(self)
	if self.Title:IsTruncated() or self.Why:IsTruncated() then
		W.Tooltip(self, "ANCHOR_RIGHT", self.Title:GetText(), { self.Why:GetText() })
	end
end

local function row(i)
	local r = F.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, F.List.Child)
	r:SetHeight(ROW_H)
	r:EnableMouse(true)
	r:SetScript("OnEnter", rowEnter)
	r:SetScript("OnLeave", function(self) W.HideTooltip(self) end)
	r:SetScript("OnClick", function(self)
		if self.psMap and not F.psMap then UI.ShowZonePicker(self.psMap) end
	end)
	r.Title = W.Text(r, "label", "text")
	r.Title:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -2)
	r.Title:SetJustifyH("LEFT")
	r.Title:SetWordWrap(false)
	r.Why = W.Text(r, "note", "textDim")
	r.Why:SetPoint("TOPLEFT", r.Title, "BOTTOMLEFT", 0, -2)
	r.Why:SetJustifyH("LEFT")
	r.Why:SetWordWrap(false)
	r.Go = W.Button(r, L["Guide me"], function(self)
		if self.psMap then ns.ForkZoneQuests.Open(self.psMap) end
	end, { ghost = true, height = 24 })
	r.Go:SetPoint("RIGHT", r, "RIGHT", 0, 0)
	r.Abandon = W.Button(r, L["Abandon"], function(self)
		if not ns.Compat.AskAbandonQuest(self.psQuest) then ns.Print(L["Abandon it from your quest log."]) end
	end, { ghost = true, danger = true, height = 24 })
	r.Abandon:SetPoint("RIGHT", r, "RIGHT", 0, 0)
	F.rows[i] = r
	return r
end

local function levels(z)
	if z.minLevel and z.maxLevel and z.minLevel ~= z.maxLevel then return format(L["levels %d-%d"], z.minLevel, z.maxLevel) end
	if z.minLevel then return format(L["level %d"], z.minLevel) end
	return nil
end

-- The rows to show: { header = text } | { title, why, map, go, quest, abandon }.
local function zoneRows()
	local out = {}
	local zones = ns.ForkZoneQuests.Zones()
	local here = ns.PlayerPoint()
	local hereMap = here and here.map
	local group
	for _, z in ipairs(zones) do
		if z.map == hereMap then
			out[#out + 1] = { header = L["Where you are"] }
			out[#out + 1] = { title = z.name, why = format(L["%d of %d done"], z.done, z.total) .. (levels(z) and ("  \194\183  " .. levels(z)) or ""), map = z.map, go = true }
		end
	end
	for _, z in ipairs(zones) do
		if z.continentName ~= group then
			group = z.continentName
			out[#out + 1] = { header = group }
		end
		out[#out + 1] = { title = z.name, why = format(L["%d of %d done"], z.done, z.total) .. (levels(z) and ("  \194\183  " .. levels(z)) or ""), map = z.map, go = z.done < z.total }
	end
	return out, #zones
end

local function detailRows(plan)
	local out = {}
	if #plan.leftOut > 0 then out[#out + 1] = { header = format(L["Left out (%d)"], #plan.leftOut) } end
	for _, q in ipairs(plan.leftOut) do
		local grey = ns.ForkRoute.Grey(q.quest, (ns.Compat.GetPlayerInfo() or {}).level)
		out[#out + 1] = { title = q.title, why = q.text, quest = q.quest, abandon = grey and ns.Compat.IsOnQuest(q.quest) }
	end
	if #plan.doneList > 0 then out[#out + 1] = { header = format(L["Already done (%d): skipped"], #plan.doneList) } end
	for _, q in ipairs(plan.doneList) do
		out[#out + 1] = { title = q.title, why = L["Done"] }
	end
	return out
end

function UI.LayoutZonePicker()
	if not (F and F:IsShown()) then return end
	local list, hint
	local ZQ = ns.ForkZoneQuests
	if F.psMap then
		local plan = ZQ.Last(F.psMap)
		if not plan then
			F.Title:SetText(L["Zone completionist"])
			F.Hint:SetText(L["No quests are known for that zone."])
			list = {}
		else
			F.Title:SetText(format(L["%s: %d of %d quests done"], plan.name, plan.done, plan.total))
			hint = format(L["Guide me opens one guide for the %d quests you can do here now (%d of their steps outside the zone, marked). Below: what it leaves out, and why."], plan.routed, plan.away)
			if plan.routed == 0 then hint = plan.done >= plan.total and L["Every quest of this zone you can do is done."] or L["Nothing in this zone can be routed now: here is why."] end
			F.Hint:SetText(hint)
			list = detailRows(plan)
		end
	else
		local n
		list, n = zoneRows()
		F.Title:SetText(L["Zone completionist"])
		F.Hint:SetText(n > 0 and L["Pick a zone: one guide for every quest there your character can do, with pick-ups, objectives, turn-ins and the chains in order. X of Y: quests done of those for you."]
			or L["The quest data isn't loaded (Polestar_Codex)."])
	end
	local top = HEAD_H + 12 + F.Hint:GetStringHeight() + 12
	local rowW = WIDTH - PAD * 2
	local y = 0
	for i, u in ipairs(list) do
		local r = row(i)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", F.List.Child, "TOPLEFT", 0, -y)
		r:SetWidth(rowW)
		r.psMap = u.map
		r.Go.psMap = u.map
		r.Abandon.psQuest = u.quest
		if u.header then
			r:SetHeight(HEAD_ROW_H)
			r.Title:SetText(u.header)
			r.Why:SetText("")
			r.Why:Hide()
			r.Go:Hide()
			r.Abandon:Hide()
			y = y + HEAD_ROW_H + ROW_GAP
		else
			r:SetHeight(ROW_H)
			r.Title:SetText(u.title or "")
			r.Why:SetText(u.why or "")
			r.Why:Show()
			r.Go:SetShown(u.go and true or false)
			r.Abandon:SetShown(u.abandon and true or false)
			y = y + ROW_H + ROW_GAP
		end
		local button = (r.Go:IsShown() and r.Go) or (r.Abandon:IsShown() and r.Abandon) or nil
		local textW = rowW - (button and (button:GetWidth() + 8) or 0)
		r.Title:SetWidth(textW)
		r.Why:SetWidth(textW)
		r:Show()
	end
	for i = #list + 1, #F.rows do F.rows[i]:Hide() end
	local detail = F.psMap ~= nil
	local foot = detail and (BUTTON_H + ROW_GAP) or 0
	local screen = UIParent:GetHeight() or 0
	local view = math.min(y, MAX_ROWS * (ROW_H + ROW_GAP))
	if screen > 0 then view = math.min(view, math.max(ROW_H + ROW_GAP, screen - MARGIN * 2 - top - foot - (PAD - 6))) end
	F.List:ClearAllPoints()
	F.List:SetPoint("TOPLEFT", F, "TOPLEFT", PAD, -top)
	F.List:SetPoint("TOPRIGHT", F, "TOPRIGHT", -1, -top)
	F.List:SetHeight(math.max(1, view))
	F.List.Child:SetWidth(rowW)
	W.SetScrollContent(F.List, y, view)
	local under = top + view
	F.GuideMe:ClearAllPoints()
	F.GuideMe:SetPoint("TOPRIGHT", F, "TOPRIGHT", -PAD, -under)
	local plan = detail and ZQ.Last(F.psMap)
	F.GuideMe:SetShown(detail and plan and plan.routed > 0 or false)
	F.Back:ClearAllPoints()
	F.Back:SetPoint("TOPLEFT", F, "TOPLEFT", PAD - 8, -under)
	F.Back:SetShown(detail)
	F:SetHeight(under + foot + PAD - 6)
end

function UI.ShowZonePicker(map)
	if not F then build() end
	F.psMap = tonumber(map)
	F:Show()
	F:Raise()
	UI.LayoutZonePicker()
end

ns.RegisterEvent("QUEST_TURNED_IN", function() UI.LayoutZonePicker() end)
