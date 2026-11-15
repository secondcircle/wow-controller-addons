-- SoftTarget: FFXIV-style soft targeting for the gamepad action bars.
--
-- LB + party button (Blizzard's "friendly targeting bar") no longer changes
-- your target. It marks that ally as the soft target (gold border). The next
-- helpful spell pressed on the action bar is cast on them, and your real
-- target never changes. Pressing LB + the SAME ally again targets them for
-- real.
--
-- Everything is configurable: Options > AddOns > SoftTarget, or "/soft help".
--
-- How (from the Blizzard UI source, Blizzard_GamepadActionBars):
--  * Friendly bar buttons are type="target" SecureActionButtons clicked with
--    :Click(). Blizzard re-SetScripts their OnClick often, so we wrap
--    PreClick instead (untouched by SetScript) and switch the button's
--    "type" attribute to a no-op while we take the press.
--  * Action buttons pass their "unit" attribute to UseAction(action, unit).
--    A wrapped OnClick sets unit = soft ally for helpful spells only, and the
--    post-snippet clears it again.
--  * Macros ignore that unit. For a macro on the bar, a copy of its text
--    with [@unit] added to its helpful /cast and /use lines is prepared out
--    of combat; at the press the button runs that text instead.
--  * Addon code cannot change secure state in combat, so the soft target is
--    used up at the PRESS of a helpful spell, not when the cast lands.

local ADDON = ...
local header
local db
local wrapped = {}
local setupDone = false
local pendingApply = false
local currentUnit

-- Settings (saved in SoftTargetDB). The option list near the end of the file
-- describes each one.
local DEFAULTS = {
	on = true,                -- soft targeting at all
	keep = true,              -- sticky: keep the soft target after a cast
	again = "target",         -- LB + the same ally again: target | clear | keep
	friendWins = true,        -- a friendly real target beats the soft target
	softSelf = true,          -- LB + self is a soft pick too
	softPet = true,           -- LB + pet is a soft pick too
	items = true,             -- helpful items (bandages...) use the soft target
	macros = true,            -- macros with helpful /cast or /use lines use the soft target
	-- spells that go to the soft target even when your real target is friendly
	always = "dispel magic, cure disease, abolish disease, purify, cleanse, remove curse, remove lesser curse, cure poison, abolish poison",
	hardBorder = false,       -- show Blizzard's border on your real target's party frame
	borderColor = "ffffd100", -- soft target border colour (aarrggbb)
	borderSize = 3,           -- soft target border thickness
	label = true,             -- "Soft: name" text when there is no frame to put a border on
}

local function Opt(key)
	local v = db and db[key]
	if v == nil then return DEFAULTS[key] end
	return v
end

local BuildPanel -- defined with the options at the end of the file

local function Print(msg)
	print("|cffffd200SoftTarget:|r " .. tostring(msg))
end

local function IsSecret(v)
	return issecretvalue and issecretvalue(v)
end

---------------------------------------------------------------------------
-- Secure snippets
---------------------------------------------------------------------------

-- PreClick on the friendly targeting bar buttons (LB + button).
local FRIENDLY_PRE = [[
	local t = self:GetAttribute("type")
	if t ~= "target" and t ~= "softskip" then
		return
	end
	local u = self:GetAttribute("unit")
	if not control:GetAttribute("soft-on") or not u or u == "targettarget"
		or (u == "player" and not control:GetAttribute("soft-self"))
		or (u == "pet" and not control:GetAttribute("soft-pet")) then
		if t == "softskip" then
			self:SetAttribute("type", "target")
		end
		return
	end
	if down then
		if control:GetAttribute("soft-unit") == u then
			-- second press on the same ally
			local again = control:GetAttribute("soft-again")
			if again == "target" then
				-- really target them
				control:SetAttribute("soft-unit", nil)
				control:SetAttribute("soft-hard", true)
				control:CallMethod("SoftChanged", nil)
			elseif again == "clear" then
				control:SetAttribute("soft-unit", nil)
				control:SetAttribute("soft-hard", nil)
				control:CallMethod("SoftChanged", nil)
			end
		else
			control:SetAttribute("soft-unit", u)
			control:SetAttribute("soft-hard", nil)
			control:CallMethod("SoftChanged", u)
		end
	end
	if control:GetAttribute("soft-hard") then
		if t ~= "target" then
			self:SetAttribute("type", "target")
		end
	else
		if t ~= "softskip" then
			self:SetAttribute("type", "softskip")
		end
	end
]]

-- OnClick (before) on the normal action buttons.
local ACTION_PRE = [[
	local u = control:GetAttribute("soft-unit")
	if not u or not control:GetAttribute("soft-on") then
		return
	end
	local helpful, macro, always
	local t = self:GetAttribute("type")
	if t == "spell" then
		local s = self:GetAttribute("spell")
		if s and s ~= 0 then
			helpful = IsSpellHelpful(s)
		end
	elseif t == "action" then
		local slot
		local id = self:GetID()
		if id and id > 0 then
			local page = self:GetEffectiveAttribute("actionpage", button) or GetActionBarPage()
			slot = id + ((page - 1) * 12)
		else
			slot = self:GetAttribute("action")
		end
		if slot and slot > 0 then
			-- set out of combat (RefreshMacros) for the "always" spells
			always = control:GetAttribute("soft-always-" .. slot)
			local kind, sid = GetActionInfo(slot)
			if kind == "spell" and sid then
				helpful = always or IsSpellHelpful(sid)
			elseif kind == "item" and sid and control:GetAttribute("soft-items") then
				helpful = IsHelpfulItem(sid)
			elseif kind == "macro" then
				-- text prepared out of combat (RefreshMacros), if this
				-- macro has helpful lines
				macro = control:GetAttribute("soft-macro-" .. slot)
			end
		end
	end
	-- A friendly real target wins over the soft target (optional), except
	-- for the "always" spells (dispels).
	if not always and control:GetAttribute("soft-friendwins") and UnitExists("target") and PlayerCanAssist("target") then
		return
	end
	if (helpful or macro) and UnitExists(u) and PlayerCanAssist(u) then
		if macro then
			-- run the prepared text instead of the bar's macro, this press only
			self:SetAttribute("type", "macro")
			self:SetAttribute("macrotext", gsub(macro, "@SOFTUNIT", "@" .. u))
		else
			self:SetAttribute("unit", u)
		end
		if down and not control:GetAttribute("soft-sticky") then
			control:SetAttribute("soft-unit", nil)
			control:CallMethod("SoftChanged", nil)
		end
		return nil, macro and "macro" or "clear"
	end
]]

-- OnClick (after): never leave a unit (or our macro text) on the button.
local ACTION_POST = [[
	self:SetAttribute("unit", nil)
	if message == "macro" then
		self:SetAttribute("type", "action")
		self:SetAttribute("macrotext", nil)
	end
]]

---------------------------------------------------------------------------
-- Soft target border
---------------------------------------------------------------------------

local border, label
local edges = {}

-- "aarrggbb" or "rrggbb" -> r, g, b (0-1)
local function ColorRGB(hex)
	local r, g, b = tostring(hex or ""):match("(%x%x)(%x%x)(%x%x)$")
	if not r then return 1, 0.82, 0 end
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

local function StyleBorder()
	if not border then return end
	local r, g, b = ColorRGB(Opt("borderColor"))
	local size = Opt("borderSize")
	for _, e in ipairs(edges) do
		e.tx:SetColorTexture(r, g, b, 1)
		if e.horizontal then e.tx:SetHeight(size) else e.tx:SetWidth(size) end
	end
	label:SetTextColor(r, g, b)
end

local function MakeBorder()
	border = CreateFrame("Frame", nil, UIParent)
	border:Hide()
	local function Edge(p1, p2, horizontal)
		local tx = border:CreateTexture(nil, "OVERLAY")
		tx:SetPoint(p1)
		tx:SetPoint(p2)
		edges[#edges + 1] = { tx = tx, horizontal = horizontal }
	end
	Edge("TOPLEFT", "TOPRIGHT", true)
	Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
	Edge("TOPLEFT", "BOTTOMLEFT", false)
	Edge("TOPRIGHT", "BOTTOMRIGHT", false)

	label = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	label:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
	label:Hide()
	StyleBorder()
end

local function FindUnitFrame(unit)
	if CompactPartyFrame and CompactPartyFrame:IsShown() then
		for i = 1, 5 do
			local f = _G["CompactPartyFrameMember" .. i]
			if f then
				local fu = f.unit
				if fu and not IsSecret(fu) and fu == unit then
					return f
				end
			end
		end
	end
	if unit == "player" then return PlayerFrame end
	if unit == "pet" then return PetFrame end
	local n = unit:match("^party(%d)$")
	if n then
		return (PartyFrame and PartyFrame["MemberFrame" .. n]) or _G["PartyMemberFrame" .. n]
	end
end

local function ShowBorder(unit)
	if not border then MakeBorder() end
	border:Hide()
	label:Hide()
	if not unit then return end

	local ok, f = pcall(FindUnitFrame, unit)
	if ok and f then
		local placed = pcall(function()
			border:SetParent(f)
			border:ClearAllPoints()
			border:SetAllPoints(f)
			border:SetFrameStrata("HIGH")
			border:Show()
		end)
		if placed then return end
		border:Hide()
	end

	-- No frame to put the border on: show a small text label instead.
	if not Opt("label") then return end
	local name = UnitName(unit)
	if not name or IsSecret(name) then name = unit end
	label:SetText("Soft: " .. name)
	label:Show()
end

-- Blizzard's own highlight around the party frame of your real (hard)
-- target. Hidden by default so the only border on the party frames is the
-- soft target.
local function HideHardBorder()
	local alpha = Opt("hardBorder") and 1 or 0
	for i = 1, 5 do
		local f = _G["CompactPartyFrameMember" .. i]
		local hl = f and f.selectionHighlight
		if hl and hl.SetAlpha then
			pcall(hl.SetAlpha, hl, alpha)
		end
	end
end

---------------------------------------------------------------------------
-- Macros
--
-- A macro on the bar ignores the button's unit, so the secure code runs a
-- rewritten copy of its text instead. The copies are made here, out of
-- combat, one header attribute per action slot ("soft-macro-<slot>").
-- Only /cast and /use lines with a helpful spell or item and no [conditions]
-- of their own are changed; "@SOFTUNIT" is swapped for the ally at the press.
---------------------------------------------------------------------------

local MACRO_LIMIT = 255 -- stay inside the normal macro length
local macroSlots = {}   -- slot -> text now on the header
local alwaysSlots = {}  -- slot -> true for the "always" spells (and macros casting them)
local pendingMacros = false
local macroQueued = false

local function Truthy(ok, v)
	return ok and v and not IsSecret(v)
end

-- "!Greater Heal(Rank 2)" -> "Greater Heal"
local function PlainName(what)
	return what:gsub("^!", ""):gsub("%s*%(.-%)%s*$", ""):match("^%s*(.-)%s*$")
end

-- the "always" setting as a set of lower-case spell names
local function AlwaysSet()
	local set = {}
	for name in tostring(Opt("always") or ""):gmatch("[^,]+") do
		name = name:lower():match("^%s*(.-)%s*$")
		if name ~= "" then set[name] = true end
	end
	return set
end

local function HelpfulName(cmd, what)
	what = PlainName(what)
	if what == "" or tonumber(what) then return false end
	if C_Spell and C_Spell.IsSpellHelpful and Truthy(pcall(C_Spell.IsSpellHelpful, what)) then return true end
	if IsHelpfulSpell and Truthy(pcall(IsHelpfulSpell, what)) then return true end
	if cmd == "/use" then
		if C_Item and C_Item.IsHelpfulItem and Truthy(pcall(C_Item.IsHelpfulItem, what)) then return true end
		if IsHelpfulItem and Truthy(pcall(IsHelpfulItem, what)) then return true end
	end
	return false
end

-- macro body -> text with the placeholder unit, or nil if nothing to change
-- also returns true when one of the changed lines is an "always" spell
local function SoftMacro(body, always)
	if type(body) ~= "string" or IsSecret(body) then return end
	local out, changed, forced = {}, 0, false
	for line in (body .. "\n"):gmatch("(.-)\r?\n") do
		local cmd, rest = line:match("^%s*(/%a+)%s+(.+)$")
		local c = cmd and cmd:lower()
		if (c == "/cast" or c == "/use") and rest:sub(1, 1) ~= "[" and not rest:find(";", 1, true) then
			local isAlways = always and always[PlainName(rest):lower()]
			if isAlways or HelpfulName(c, rest) then
				line = cmd .. " [@SOFTUNIT] " .. rest
				changed = changed + 1
				forced = forced or isAlways or false
			end
		end
		out[#out + 1] = line
	end
	if changed == 0 then return end
	local text = table.concat(out, "\n"):gsub("%s+$", "")
	-- "@SOFTUNIT" becomes "@player" / "@party1" (2 shorter) at the press
	if #text - 2 * changed > MACRO_LIMIT then return end
	return text, forced
end

-- one action slot -> macro text (or nil), is-an-"always"-spell
local function SlotSoft(slot, always, macrosOn)
	local kind, id = GetActionInfo(slot)
	if kind == "spell" then
		if type(id) ~= "number" or not next(always) then return end
		local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id))
			or (GetSpellInfo and GetSpellInfo(id))
		if type(name) == "string" and not IsSecret(name) and always[name:lower()] then
			return nil, true
		end
		return
	end
	if kind ~= "macro" or not macrosOn then return end
	local getText = (C_ActionBar and C_ActionBar.GetActionText) or GetActionText
	local name = getText and getText(slot)
	if type(name) ~= "string" or IsSecret(name) or name == "" then return end
	local _, _, body = GetMacroInfo(name)
	return SoftMacro(body, always)
end

local function SyncSlots(prefix, current, found)
	for slot, old in pairs(current) do
		if found[slot] ~= old then
			header:SetAttribute(prefix .. slot, nil)
			current[slot] = nil
		end
	end
	for slot, v in pairs(found) do
		if current[slot] ~= v then
			header:SetAttribute(prefix .. slot, v)
			current[slot] = v
		end
	end
end

local function RefreshMacros()
	if not db then return end
	if InCombatLockdown() then
		pendingMacros = true
		return
	end
	pendingMacros = false
	local found, foundAlways = {}, {}
	if Opt("on") then
		local always, macrosOn = AlwaysSet(), Opt("macros")
		local function Scan(first, last)
			for slot = first, last do
				local ok, text, isAlways = pcall(SlotSoft, slot, always, macrosOn)
				if ok then
					if text then found[slot] = text end
					if isAlways then foundAlways[slot] = true end
				end
			end
		end
		Scan(1, 180)
		-- The gamepad bars keep their actions in their own storage slots,
		-- after the normal ones (3 pages of 32, for each stance bar).
		local ok, first = pcall(function() return C_GamepadUI.GetFirstGamepadActionStorageSlotIndex() end)
		if ok and type(first) == "number" and not IsSecret(first) then
			Scan(math.max(first, 181), first + 96 * 6 - 1)
		end
	end
	SyncSlots("soft-macro-", macroSlots, found)
	SyncSlots("soft-always-", alwaysSlots, foundAlways)
end

local function QueueMacros()
	if macroQueued then return end
	macroQueued = true
	C_Timer.After(0.3, function()
		macroQueued = false
		RefreshMacros()
	end)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function ApplySettings()
	if InCombatLockdown() then
		pendingApply = true
		return
	end
	pendingApply = false
	local on = Opt("on")
	header:SetAttribute("soft-on", on and true or nil)
	header:SetAttribute("soft-sticky", Opt("keep") and true or nil)
	header:SetAttribute("soft-again", Opt("again"))
	header:SetAttribute("soft-friendwins", Opt("friendWins") and true or nil)
	header:SetAttribute("soft-self", Opt("softSelf") and true or nil)
	header:SetAttribute("soft-pet", Opt("softPet") and true or nil)
	header:SetAttribute("soft-items", Opt("items") and true or nil)
	if not on then
		header:SetAttribute("soft-unit", nil)
		header:SetAttribute("soft-hard", nil)
		currentUnit = nil
		ShowBorder(nil)
	end
	RefreshMacros()
end

local function IsStaticTargetBar(bar)
	-- Friendly / Hostile / Shortcuts bars (StaticOverrideActionBarMixin)
	return type(bar.SetUpDpadLeft) == "function"
end

local function WrapBar(bar, friendlyBar)
	local buttons = bar.actionButtons
	if type(buttons) ~= "table" then return 0 end
	local n = 0
	for _, b in pairs(buttons) do
		if type(b) == "table" and not wrapped[b] and b.IsProtected and b:IsProtected() then
			if bar ~= friendlyBar and IsStaticTargetBar(bar) then
				-- Hostile / Shortcuts bar: leave alone (their Left/Right
				-- sub-frames list the same buttons again, so mark them).
				wrapped[b] = "skip"
			elseif bar == friendlyBar then
				SecureHandlerWrapScript(b, "PreClick", header, FRIENDLY_PRE)
				wrapped[b] = "friendly"
				n = n + 1
			elseif not IsStaticTargetBar(bar) and b.GetGamepadPageUnitSlotID then
				SecureHandlerWrapScript(b, "OnClick", header, ACTION_PRE, ACTION_POST)
				wrapped[b] = "action"
				n = n + 1
			end
		end
	end
	return n
end

local function FindBars(frame, out, depth, state)
	if depth > 8 or not frame or (frame.IsForbidden and frame:IsForbidden()) then return end
	if type(frame.actionButtons) == "table" then
		out[#out + 1] = frame
	end
	if frame.FriendlyTargetingActionBar then
		state.friendly = frame.FriendlyTargetingActionBar
	end
	if frame.GetChildren then
		for _, child in ipairs({ frame:GetChildren() }) do
			FindBars(child, out, depth + 1, state)
		end
	end
end

local function Setup()
	if setupDone then return true end
	if InCombatLockdown() then return false end
	local main = _G.GamepadMainActionBarFrame
	if not main then return false end

	local bars, state = {}, {}
	FindBars(main, bars, 0, state)
	if not state.friendly then return false end

	local counts = { friendly = 0, action = 0 }
	for _, bar in ipairs(bars) do
		WrapBar(bar, state.friendly)
	end
	for _, kind in pairs(wrapped) do
		counts[kind] = (counts[kind] or 0) + 1
	end
	header.counts = counts
	setupDone = counts.friendly > 0 and counts.action > 0
	ApplySettings()
	return setupDone
end

---------------------------------------------------------------------------
-- Header + events
---------------------------------------------------------------------------

header = CreateFrame("Frame", "SoftTargetHeader", UIParent, "SecureHandlerBaseTemplate")

-- Called from the secure snippets (runs as normal addon code).
function header:SoftChanged(unit)
	currentUnit = unit
	ShowBorder(unit)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
-- macros on the bar: rebuild their soft copies when the bar, the macros or
-- the known spells change
ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
ev:RegisterEvent("UPDATE_MACROS")
ev:RegisterEvent("SPELLS_CHANGED")
ev:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		SoftTargetDB = SoftTargetDB or {}
		db = SoftTargetDB
		if BuildPanel then
			local ok, err = pcall(BuildPanel)
			if not ok then Print("options panel not available (" .. tostring(err) .. "); use /soft help.") end
		end
	end
	if not db then return end

	if event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_MACROS" or event == "SPELLS_CHANGED" then
		QueueMacros()
		return
	end
	if event == "PLAYER_ENTERING_WORLD" or pendingMacros then
		QueueMacros()
	end

	HideHardBorder()

	if event == "GROUP_ROSTER_UPDATE" then
		if currentUnit then ShowBorder(currentUnit) end
		return
	end

	if not setupDone then
		local ok, res = pcall(Setup)
		if not ok and not header.errShown then
			header.errShown = true
			Print("setup failed: " .. tostring(res))
		end
	elseif pendingApply then
		ApplySettings()
	end
end)

---------------------------------------------------------------------------
-- Options: one list drives the saved settings, the slash command and the
-- options panel.
---------------------------------------------------------------------------

local OPTIONS = {
	{ header = "Soft targeting" },
	{ key = "on", cmd = "enabled", type = "bool", name = "Enable soft targeting",
		tip = "Off: LB + party button targets normally, as if the addon wasn't there." },
	{ key = "keep", cmd = "sticky", type = "bool", name = "Sticky soft target",
		tip = "On: the soft target stays until you pick someone else. Off: it is used up by the next helpful spell you press." },
	{ key = "again", cmd = "again", type = "choice", name = "LB + the same ally again",
		choices = {
			{ "target", "Target them for real" },
			{ "clear", "Clear the soft target" },
			{ "keep", "Do nothing" },
		},
		tip = "What a second press on the ally who is already your soft target does." },
	{ key = "friendWins", cmd = "friendwins", type = "bool", name = "Friendly target beats the soft target",
		tip = "On: while your real target is friendly, helpful spells go to them and the soft target waits. Off: the soft target always gets them." },
	{ key = "always", cmd = "always", type = "text", name = "Spells that always use the soft target",
		tip = "Spell names separated by commas (\"none\" for no spells). These go to the soft target even while your real target is friendly." },
	{ key = "softSelf", cmd = "self", type = "bool", name = "Soft-pick yourself",
		tip = "Off: LB + self targets you normally." },
	{ key = "softPet", cmd = "pet", type = "bool", name = "Soft-pick your pet",
		tip = "Off: LB + pet targets your pet normally." },
	{ key = "items", cmd = "items", type = "bool", name = "Helpful items use the soft target",
		tip = "Bandages and other helpful items on the action bar." },
	{ key = "macros", cmd = "macros", type = "bool", name = "Macros use the soft target",
		tip = "Macros on the action bar: /cast and /use lines with a helpful spell or item go to the soft target. Lines that already have [conditions] are left alone." },

	{ header = "Look" },
	{ key = "borderColor", cmd = "color", type = "color", name = "Soft target border colour" },
	{ key = "borderSize", cmd = "size", type = "number", min = 1, max = 10, step = 1, name = "Soft target border thickness" },
	{ key = "label", cmd = "label", type = "bool", name = "Show a text label when there is no frame",
		tip = "If the soft target has no party frame to put a border on, show \"Soft: name\" on screen instead." },
	{ key = "hardBorder", cmd = "targetborder", type = "bool", name = "Show Blizzard's target border on party frames",
		tip = "Blizzard's own highlight around the party frame of your real target (raid-style party frames)." },
}

local byCmd = {}
for _, o in ipairs(OPTIONS) do
	if o.key then byCmd[o.cmd] = o end
end

local function OnChanged()
	ApplySettings()
	StyleBorder()
	HideHardBorder()
	if currentUnit then ShowBorder(currentUnit) end
end

-- turn user input (slash text or a panel value) into a valid value:
-- returns true, value / false
local function Clean(o, v)
	if o.type == "bool" then
		if v == true or v == "on" or v == "true" or v == "1" or v == "yes" then return true, true end
		if v == false or v == "off" or v == "false" or v == "0" or v == "no" then return true, false end
		if v == "" or v == "toggle" then return true, not Opt(o.key) end
	elseif o.type == "number" then
		local n = tonumber(v)
		if n then
			n = math.min(o.max, math.max(o.min, n))
			return true, math.floor(n / o.step + 0.5) * o.step
		end
	elseif o.type == "choice" then
		for _, c in ipairs(o.choices) do
			if c[1] == v then return true, v end
		end
	elseif o.type == "text" then
		if type(v) == "string" and v ~= "" then
			if v == "none" then return true, "" end
			return true, v
		end
	elseif o.type == "color" then
		local hex = type(v) == "string" and v:lower():match("^#?(%x+)$")
		if hex and #hex == 8 then hex = hex:sub(3) end
		if hex and #hex == 6 then return true, "ff" .. hex end
	end
	return false
end

local function SetOption(o, raw)
	local ok, v = Clean(o, raw)
	if not ok or not db then return false end
	if db[o.key] ~= v then
		db[o.key] = v
		OnChanged()
	end
	return true
end

local function Shown(o)
	local v = Opt(o.key)
	if o.type == "bool" then return v and "on" or "off" end
	if o.type == "color" then return tostring(v):sub(3) end
	if o.type == "text" and v == "" then return "none" end
	return tostring(v)
end

local function Usage(o)
	if o.type == "bool" then return "on|off" end
	if o.type == "number" then return o.min .. "-" .. o.max end
	if o.type == "color" then return "rrggbb" end
	if o.type == "text" then return "name, name, ...|none" end
	local t = {}
	for _, c in ipairs(o.choices) do t[#t + 1] = c[1] end
	return table.concat(t, "|")
end

-- Options > AddOns > SoftTarget
local panelCategory
local panelErr = {}
BuildPanel = function()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then return end
	local category, layout = Settings.RegisterVerticalLayoutCategory("SoftTarget")
	local function Add(initializer)
		if layout and layout.AddInitializer then layout:AddInitializer(initializer)
		elseif Settings.RegisterInitializer then Settings.RegisterInitializer(category, initializer) end
	end
	for _, o in ipairs(OPTIONS) do
		local ok, err = pcall(function()
			if o.header then
				Add(CreateSettingsListSectionHeaderInitializer(o.header))
				return
			end
			if o.type == "text" then return end -- slash only
			if o.type == "color" and not Settings.CreateColorSwatch then return end -- slash only
			local vtype = (o.type == "bool" and "boolean") or (o.type == "number" and "number") or "string"
			local setting = Settings.RegisterProxySetting(category, "SoftTarget_" .. o.key, vtype, o.name,
				DEFAULTS[o.key], function() return Opt(o.key) end, function(v) SetOption(o, v) end)
			if o.type == "bool" then
				Settings.CreateCheckbox(category, setting, o.tip)
			elseif o.type == "number" then
				local opts = Settings.CreateSliderOptions(o.min, o.max, o.step)
				if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
					opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return ("%d"):format(v) end)
				end
				Settings.CreateSlider(category, setting, opts, o.tip)
			elseif o.type == "color" then
				Settings.CreateColorSwatch(category, setting, o.tip)
			else
				Settings.CreateDropdown(category, setting, function()
					local c = Settings.CreateControlTextContainer()
					for _, ch in ipairs(o.choices) do c:Add(ch[1], ch[2]) end
					return c:GetData()
				end, o.tip)
			end
		end)
		if not ok and not panelErr[tostring(err)] then
			panelErr[tostring(err)] = true
			Print("options panel: " .. tostring(err))
		end
	end
	Settings.RegisterAddOnCategory(category)
	panelCategory = category
end

local function OpenPanel()
	if panelCategory and Settings and Settings.OpenToCategory then
		local ok = pcall(Settings.OpenToCategory, panelCategory:GetID())
		if ok then return end
	end
	Print("couldn't open the options panel; use /soft help.")
end

---------------------------------------------------------------------------
-- /soft              status
-- /soft config       open the options panel
-- /soft help         list every setting
-- /soft on|off
-- /soft <setting> <value>
---------------------------------------------------------------------------

SLASH_SOFTTARGET1 = "/soft"
SLASH_SOFTTARGET2 = "/softtarget"
SlashCmdList.SOFTTARGET = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if not db then return end
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	local after = function() return pendingApply and " (applies after combat)" or "" end

	if cmd == "on" or cmd == "off" then
		SetOption(byCmd.enabled, cmd)
		Print(cmd .. after())
	elseif cmd == "config" or cmd == "options" or cmd == "settings" then
		OpenPanel()
	elseif cmd == "help" or cmd == "?" then
		Print("/soft config (options panel), /soft on|off, /soft (status). Settings:")
		for _, o in ipairs(OPTIONS) do
			if o.key then
				Print(("  /soft %s %s  - %s (now %s)"):format(o.cmd, Usage(o), o.name, Shown(o)))
			end
		end
	elseif byCmd[cmd] then
		local o = byCmd[cmd]
		if rest == "" and o.type ~= "bool" then
			Print(("%s is %s. Usage: /soft %s %s"):format(o.name, Shown(o), cmd, Usage(o)))
		elseif SetOption(o, rest) then
			Print(("%s: %s%s"):format(o.name, Shown(o), after()))
		else
			Print(("usage: /soft %s %s"):format(cmd, Usage(o)))
		end
	else
		if not setupDone and not InCombatLockdown() then pcall(Setup) end
		local c = header.counts or {}
		local nMacros, nAlways = 0, 0
		for _ in pairs(macroSlots) do nMacros = nMacros + 1 end
		for _ in pairs(alwaysSlots) do nAlways = nAlways + 1 end
		Print(("Buttons with an always-soft spell: %d."):format(nAlways))
		Print(("%s, sticky %s. Hooked %d targeting buttons and %d action buttons%s. Macros on the bar using the soft target: %d. Soft target: %s"):format(
			Opt("on") and "on" or "off",
			Opt("keep") and "on" or "off",
			c.friendly or 0, c.action or 0,
			setupDone and "" or " (NOT set up - gamepad bars not found?)",
			nMacros,
			currentUnit or "none"))
		Print("/soft config for options, /soft help for commands.")
	end
end
