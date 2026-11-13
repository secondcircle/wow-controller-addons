-- Party Diamond: moves the normal Blizzard party frames into a diamond that matches
-- the controller face buttons:  top = Y, right = B, bottom = A, left = X
-- (raid-style party frames also put you in the middle).
-- Which member goes where comes from your "Target Party Member N" bindings
-- (e.g. LB+Y = party 1 -> top). Unbound members fill the free spots in Y,B,A,X order.
--
-- Blizzard re-stacks its party frames when the group changes. Frames can only be moved
-- out of combat, so if that happens mid-fight they sit in a column until combat ends.
-- A light check every 0.5s (out of combat) puts them back.
--
-- Everything is configurable: Options > AddOns > Party Diamond, or "/pdiamond help".

local function Print(msg) print("|cff33ff99PartyDiamond|r: " .. msg) end

local ORDER = { "up", "right", "down", "left" }
local LETTER = { up = "Y", right = "B", down = "A", left = "X", center = "you" }
local PAD_DIR = {
  PAD4 = "up", PAD2 = "right", PAD1 = "down", PAD3 = "left",          -- Y B A X
  PADDUP = "up", PADDRIGHT = "right", PADDDOWN = "down", PADDLEFT = "left",
}

-- Settings (saved in PartyDiamondDB). The option list near the end of the file describes each one.
local DEFAULTS = {
  enabled = true,      -- arrange the party frames at all
  scale = 1.2,         -- size of the party frames
  gap = 4,             -- space between frames
  slot1 = "auto", slot2 = "auto", slot3 = "auto", slot4 = "auto", -- where each party member goes
  hideExtras = true,   -- hide the "Party" title and other leftovers
  freeze = true,       -- stop Blizzard re-stacking the frames in combat
  hideRole = true,     -- hide role icons
  hideAggro = true,    -- hide the red threat border
  firstName = true,    -- first name only
  centerNames = true,  -- centre the names
  nameScale = 0.65,    -- name text size (1 = Blizzard's size)
}
local DEFAULT_X, DEFAULT_Y = -420, 0

local function Opt(key)
  local v = PartyDiamondDB and PartyDiamondDB[key]
  if v == nil then return DEFAULTS[key] end
  return v
end

local BuildPanel -- defined with the options at the end of the file

----------------------------------------------------------------------
-- Anchor (invisible; "/pdiamond move" shows a handle to drag it)
----------------------------------------------------------------------
local holder = CreateFrame("Frame", "PartyDiamondHolder", UIParent, "BackdropTemplate")
holder:SetSize(60, 20)
holder:SetMovable(true)
holder:SetClampedToScreen(true)
holder:EnableMouse(false)
holder:RegisterForDrag("LeftButton")
holder.text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
holder.text:SetPoint("CENTER")
holder.text:SetText("drag me")
holder.text:Hide()
holder:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
holder:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local hx, hy = self:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if hx and ux then
    PartyDiamondDB.point = { x = hx - ux, y = hy - uy }
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", hx - ux, hy - uy)
  end
end)

local function SetMoveMode(on)
  holder:EnableMouse(on)
  holder.text:SetShown(on)
  if holder.SetBackdrop then
    if on then
      holder:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
      holder:SetBackdropColor(0, 0.6, 1, 0.6)
    else
      holder:SetBackdrop(nil)
    end
  end
end

----------------------------------------------------------------------
-- Find Blizzard's party frames (names differ between client versions)
----------------------------------------------------------------------
local function CompactActive()
  return CompactPartyFrame and CompactPartyFrame:IsShown()
end

-- returns list of { frame = f, unit = "party1" / "player" }, and a mode label
local function FindFrames()
  local list = {}
  if CompactActive() then
    for i = 1, 5 do
      local f = _G["CompactPartyFrameMember" .. i]
      if f and f.unit then list[#list + 1] = { frame = f, unit = f.unit } end
    end
    return list, "raid-style"
  end
  for i = 1, 4 do
    local f = (PartyFrame and PartyFrame["MemberFrame" .. i]) or _G["PartyMemberFrame" .. i]
    if f then list[#list + 1] = { frame = f, unit = f.unit or ("party" .. i) } end
  end
  return list, "standard"
end

----------------------------------------------------------------------
-- Which direction each party member gets
----------------------------------------------------------------------
local function DirForParty(i)
  for _, k in ipairs({ GetBindingKey("TARGETPARTYMEMBER" .. i) }) do
    local pad = k:match("(PAD%a*%d?)$")
    if pad and PAD_DIR[pad] then return PAD_DIR[pad] end
  end
end

local VALID_DIR = { up = true, right = true, down = true, left = true }

local function Directions()
  local taken, dirs = {}, {}
  for i = 1, 4 do -- 1) spots picked in the options
    local d = Opt("slot" .. i)
    if VALID_DIR[d] and not taken[d] then taken[d] = true; dirs["party" .. i] = d end
  end
  for i = 1, 4 do -- 2) spots from the "Target Party Member N" bindings
    if not dirs["party" .. i] then
      local d = DirForParty(i)
      if d and not taken[d] then taken[d] = true; dirs["party" .. i] = d end
    end
  end
  -- 3) everyone else fills the free spots in Y, B, A, X order
  for i = 1, 4 do
    if not dirs["party" .. i] then
      for _, d in ipairs(ORDER) do
        if not taken[d] then taken[d] = true; dirs["party" .. i] = d; break end
      end
    end
  end
  dirs.player = "center"
  return dirs
end

----------------------------------------------------------------------
-- Place them
----------------------------------------------------------------------
local function Offset(dir, w, h, hasCenter)
  if dir == "center" then return 0, 0 end
  local GAP = Opt("gap")
  local dx = hasCenter and (w + GAP) or (w / 2 + GAP)
  local dy = hasCenter and (h + GAP) or (h / 2 + GAP)
  if dir == "up" then return 0, dy end
  if dir == "down" then return 0, -dy end
  if dir == "left" then return -dx, 0 end
  if dir == "right" then return dx, 0 end
end

-- a plain usable number (not nil, not a hidden "secret" value - frame sizes/points can be secret
-- in dungeons on this client, and doing math on them errors)
local function Num(v)
  return type(v) == "number" and not (issecretvalue and issecretvalue(v))
end

-- true for a hidden ("secret") value of any type: comparing one errors
local function Hidden(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function InPlace(f, x, y)
  local p, rel, rp, px, py = f:GetPoint(1)
  local n = f:GetNumPoints()
  if not (Num(px) and Num(py) and Num(n)) then return false end
  if Hidden(p) or Hidden(rp) then return false end -- can't tell: just re-anchor
  return n == 1 and p == "CENTER" and rel == holder and rp == "CENTER"
     and math.abs(px - x) < 0.5 and math.abs(py - y) < 0.5
end

-- Hide everything on the party container that isn't a member frame
-- (the "Party" title, borders, gamepad hint...). Alpha only, so nothing secure is touched.
local hiddenExtras = {}
local function HideExtras()
  local container = CompactActive() and CompactPartyFrame or PartyFrame
  if not container then return end
  local keep = {}
  for i = 1, 5 do
    local c = _G["CompactPartyFrameMember" .. i]; if c then keep[c] = true end
  end
  for i = 1, 4 do
    local m = (PartyFrame and PartyFrame["MemberFrame" .. i]) or _G["PartyMemberFrame" .. i]
    if m then keep[m] = true end
  end
  -- also keep any frame that holds a member frame (hiding it would hide the member too)
  for m in pairs(keep) do
    local p = m:GetParent()
    while p and p ~= container and p ~= UIParent do keep[p] = true; p = p:GetParent() end
  end
  for _, child in ipairs({ container:GetChildren() }) do
    if not keep[child] then
      -- no GetAlpha() comparison: alpha can be a secret value (errored in the Barrens, 2026-11-08)
      if not hiddenExtras[child] then child:SetAlpha(0) end
      hiddenExtras[child] = true
    end
  end
  for _, r in ipairs({ container:GetRegions() }) do
    if not hiddenExtras[r] then r:SetAlpha(0) end
    hiddenExtras[r] = true
  end
end

local function ShowExtras()
  for r in pairs(hiddenExtras) do pcall(r.SetAlpha, r, 1) end
  wipe(hiddenExtras)
end

----------------------------------------------------------------------
-- Look: optional hidden role icons / threat border, and smaller, first-name-only, centred names.
-- Hiding is alpha 0 (survives Blizzard's Show/Hide). Names are re-done right after Blizzard sets
-- them (hooks on CompactUnitFrame_UpdateName / UnitFrame_Update), only on our member frames.
----------------------------------------------------------------------
local isMember = setmetatable({}, { __mode = "k" })
local baseFont = setmetatable({}, { __mode = "k" })
local centeredName = setmetatable({}, { __mode = "k" })
local hidByUs = setmetatable({}, { __mode = "k" })

-- hide with alpha 0; show again only what we hid ourselves
local function SetHidden(obj, hide)
  if not (obj and obj.SetAlpha) then return end
  if hide then
    obj:SetAlpha(0); hidByUs[obj] = true
  elseif hidByUs[obj] then
    obj:SetAlpha(1); hidByUs[obj] = nil
  end
end

local function FirstName(frame, fs)
  local unit = frame.unit
  local first
  if unit and NameUtil and NameUtil.GetUnitFirstName then
    local ok, n = pcall(NameUtil.GetUnitFirstName, unit)
    if ok and type(n) == "string" and not (issecretvalue and issecretvalue(n)) and n ~= "" then first = n end
  end
  if not first then
    local t = fs:GetText()
    if type(t) ~= "string" or (issecretvalue and issecretvalue(t)) then return end
    first = t:match("^(%S+)")
  end
  return first
end

local function Restyle(frame)
  if not isMember[frame] then return end
  local on = Opt("enabled")
  SetHidden(frame.roleIcon or (frame.PartyMemberOverlay and frame.PartyMemberOverlay.RoleIcon), on and Opt("hideRole"))
  -- red threat/aggro border (raid-style: aggroHighlight; standard: Flash)
  SetHidden(frame.aggroHighlight, on and Opt("hideAggro"))
  SetHidden(frame.Flash, on and Opt("hideAggro"))
  local fs = frame.name or frame.Name
  if not (fs and fs.GetFont) then return end
  if not baseFont[fs] then
    local font, size, flags = fs:GetFont()
    if font and Num(size) then baseFont[fs] = { font, size, flags } end
  end
  local b = baseFont[fs]
  if b then
    local nameScale = on and Opt("nameScale") or 1
    local want = (nameScale == 1) and b[2] or math.max(6, math.floor(b[2] * nameScale + 0.5))
    local _, cur = fs:GetFont()
    if not Num(cur) or math.abs(cur - want) > 0.1 then fs:SetFont(b[1], want, b[3]) end
  end
  if on and Opt("firstName") then
    local first = FirstName(frame, fs)
    if first then
      local curText = fs:GetText()
      if Hidden(curText) or curText ~= first then fs:SetText(first) end
    end
  end
  -- centred names. Raid-style: span the full top edge. Anchors only out of combat.
  if on and Opt("centerNames") then
    if fs.SetJustifyH then fs:SetJustifyH("CENTER") end
    if frame.name == fs and not InCombatLockdown() then
      local p1, rel = fs:GetPoint(1)
      local n = fs:GetNumPoints()
      if Hidden(p1) or not (p1 == "TOPLEFT" and rel == frame and Num(n) and n == 2 and centeredName[fs]) then
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
        fs:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
        centeredName[fs] = true
      end
    end
  end
end

local function SafeRestyle(frame) pcall(Restyle, frame) end
if CompactUnitFrame_UpdateName then hooksecurefunc("CompactUnitFrame_UpdateName", SafeRestyle) end
if UnitFrame_Update then hooksecurefunc("UnitFrame_Update", SafeRestyle) end

local lastPlan = {}
local knownSize = setmetatable({}, { __mode = "k" }) -- kept here, not on Blizzard's frames (taint)
local function Apply()
  if not Opt("enabled") or InCombatLockdown() then return end
  local list, mode = FindFrames()
  if #list == 0 then return end
  local dirs = Directions()
  local hasCenter = false
  for _, e in ipairs(list) do if e.unit == "player" then hasCenter = true end end
  lastPlan = { mode = mode }
  for _, e in ipairs(list) do
    local f, dir = e.frame, dirs[e.unit]
    isMember[f] = true
    SafeRestyle(f)
    -- Offsets below are in the frame's own (scaled) units, so the diamond spacing scales with it.
    local scale = Opt("scale")
    if Num(f:GetScale()) and math.abs(f:GetScale() - scale) > 0.001 then f:SetScale(scale) end
    if dir then
      local w, h = f:GetWidth(), f:GetHeight()
      -- hidden/unknown size: use the last size we saw for this frame (or a sane default)
      if Num(w) and Num(h) and w > 0 and h > 0 then
        knownSize[f] = { w, h }
      else
        local s = knownSize[f] or { 72, 36 }
        w, h = s[1], s[2]
      end
      do
        local x, y = Offset(dir, w, h, hasCenter)
        -- the empty top-left / top-right cells of the grid, in holder units, so other addons
        -- can dock an icon there (see PartyDiamond_GetCorner)
        local cx, cy = Offset("left", w, h, hasCenter), select(2, Offset("up", w, h, hasCenter))
        PartyDiamondDB.corner = { x = cx * scale, y = cy * scale }
        PartyDiamondDB.cornerTR = { x = -cx * scale, y = cy * scale }
        if not InPlace(f, x, y) then
          f:ClearAllPoints()
          f:SetPoint("CENTER", holder, "CENTER", x, y)
        end
        lastPlan[#lastPlan + 1] = ("%s -> %s (%s)"):format(e.unit, dir, LETTER[dir])
      end
    end
  end
  if Opt("hideExtras") then HideExtras() end
end

-- Never turns itself off on an error: it keeps retrying and prints each distinct error once.
local shownErr = {}
-- For other addons: the anchor frame + offset of the grid's empty top-left cell, or the
-- top-right one with which == "topright"; nil if unknown.
function PartyDiamond_GetCorner(which)
  local c = PartyDiamondDB and (which == "topright" and PartyDiamondDB.cornerTR or PartyDiamondDB.corner)
  if c and Opt("enabled") then return holder, c.x, c.y end
end

local function SafeApply()
  local ok, err = pcall(Apply)
  if not ok then
    err = tostring(err)
    if not shownErr[err] then -- each distinct error once per session (no spam)
      shownErr[err] = true
      Print("error (will keep retrying): " .. err)
    end
  end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
-- Freeze in combat. Blizzard's
-- CompactPartyFrame and PartyFrame re-lay out on every GROUP_ROSTER_UPDATE (fires mid-fight, e.g.
-- a hunter pet dying/being summoned) and we can't move them back until combat ends. So when combat
-- starts, those two frames stop listening to GROUP_ROSTER_UPDATE; when it ends they listen again.
-- The member frames themselves keep updating health etc. (they have their own unit events).
-- Missed changes (someone joined/left mid-fight) show at the next roster update after combat.
local frozen = {}
local function Freeze()
  if not (Opt("enabled") and Opt("freeze")) then return end
  for _, name in ipairs({ "CompactPartyFrame", "PartyFrame" }) do -- by name: either may not exist
    local fr = _G[name]
    if fr and fr.IsEventRegistered and fr:IsEventRegistered("GROUP_ROSTER_UPDATE") then
      if pcall(fr.UnregisterEvent, fr, "GROUP_ROSTER_UPDATE") then frozen[fr] = true end
    end
  end
end
local function Unfreeze()
  for fr in pairs(frozen) do pcall(fr.RegisterEvent, fr, "GROUP_ROSTER_UPDATE") end
  wipe(frozen)
end

local compactHooked = false -- kept here, not as a field on Blizzard's CompactPartyFrame
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_DISABLED" then Freeze(); return end
  if event == "PLAYER_REGEN_ENABLED" then Unfreeze() end
  if event == "PLAYER_LOGIN" then
    PartyDiamondDB = PartyDiamondDB or {}
    local db = PartyDiamondDB
    if db.restyle == false then -- setting from before the look was split into separate options
      db.hideRole, db.hideAggro, db.firstName, db.centerNames, db.nameScale = false, false, false, false, 1
    end
    db.restyle = nil
    local pt = db.point
    holder:ClearAllPoints()
    holder:SetPoint("CENTER", UIParent, "CENTER", pt and pt.x or DEFAULT_X, pt and pt.y or DEFAULT_Y)
    if BuildPanel then
      local ok, err = pcall(BuildPanel)
      if not ok then Print("options panel not available (" .. tostring(err) .. "); use /pdiamond help.") end
    end
    for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "UPDATE_BINDINGS",
                         "PLAYER_REGEN_ENABLED", "EDIT_MODE_LAYOUTS_UPDATED" }) do
      pcall(ev.RegisterEvent, ev, e)
    end
    -- Re-apply right after each Blizzard re-layout (same frame = no flicker). From the Forever UI
    -- source: CompactPartyFrameMixin:RefreshMembers -> :UpdateLayout -> CompactRaidGroup_UpdateLayout,
    -- and PartyFrameMixin:UpdatePaddingAndLayout/:Layout for the standard frames.
    local function Now() if not InCombatLockdown() then SafeApply() end end
    if CompactRaidGroup_UpdateLayout then
      hooksecurefunc("CompactRaidGroup_UpdateLayout", function(frame)
        if frame == CompactPartyFrame then Now() end
      end)
    end
    local function HookMethods(frame, ...)
      if not frame then return end
      for _, m in ipairs({ ... }) do
        if type(frame[m]) == "function" then hooksecurefunc(frame, m, Now) end
      end
    end
    HookMethods(CompactPartyFrame, "UpdateLayout", "RefreshMembers")
    HookMethods(PartyFrame, "Layout", "UpdatePaddingAndLayout", "UpdatePartyFrames")
    if CompactPartyFrame_Generate then
      -- CompactPartyFrame may be created later (when raid-style frames are first used)
      hooksecurefunc("CompactPartyFrame_Generate", function()
        if CompactPartyFrame and not compactHooked then
          compactHooked = true
          HookMethods(CompactPartyFrame, "UpdateLayout", "RefreshMembers")
        end
        Now()
      end)
    end
    if CompactPartyFrame then compactHooked = true end
    C_Timer.NewTicker(0.5, SafeApply) -- backup for anything the hooks miss
  end
  C_Timer.After(0.1, SafeApply)
end)

----------------------------------------------------------------------
-- Options: one list drives the saved settings, the slash command and the options panel.
----------------------------------------------------------------------
local moving = false
local function ToggleMove()
  if InCombatLockdown() then Print("not in combat."); return end
  moving = not moving
  SetMoveMode(moving)
  Print(moving and "drag the blue box, then /pdiamond move again to lock." or "locked.")
end

local function ResetPosition()
  if InCombatLockdown() then Print("not in combat."); return end
  PartyDiamondDB.point = nil
  holder:ClearAllPoints()
  holder:SetPoint("CENTER", UIParent, "CENTER", DEFAULT_X, DEFAULT_Y)
  SafeApply()
  Print("position reset.")
end

local SLOTS = {
  { "auto", "Auto (from your key bindings)" },
  { "up", "Top (Y)" }, { "right", "Right (B)" }, { "down", "Bottom (A)" }, { "left", "Left (X)" },
}
local SLOT_TIP = "Auto uses your \"Target Party Member\" binding (Y/B/A/X or the d-pad); members without one fill the free spots in Y, B, A, X order."

local OPTIONS = {
  { header = "Layout" },
  { key = "enabled", type = "bool", name = "Arrange party frames in a diamond",
    tip = "Turn the whole addon on or off. After turning it off, /reload puts Blizzard's own layout back." },
  { key = "scale", type = "number", min = 0.5, max = 3, step = 0.05, name = "Frame size",
    tip = "Size of the party frames (1 = Blizzard's size)." },
  { key = "gap", type = "number", min = 0, max = 60, step = 1, name = "Gap between frames" },
  { key = "freeze", type = "bool", name = "Keep the layout in combat",
    tip = "Frames can't be moved in combat, so this stops Blizzard from re-stacking them mid-fight. Members who join or leave during a fight show up after it." },
  { key = "hideExtras", type = "bool", name = "Hide the party title and leftovers",
    tip = "Hides the \"Party\" title and other bits of Blizzard's party container that no longer line up." },
  { button = "Move", name = "Position", click = ToggleMove,
    tip = "Shows a blue box to drag. Click again (or /pdiamond move) to lock." },
  { button = "Reset", name = "Reset position", click = ResetPosition },

  { header = "Who goes where" },
  { key = "slot1", type = "choice", choices = SLOTS, name = "Party member 1", tip = SLOT_TIP },
  { key = "slot2", type = "choice", choices = SLOTS, name = "Party member 2", tip = SLOT_TIP },
  { key = "slot3", type = "choice", choices = SLOTS, name = "Party member 3", tip = SLOT_TIP },
  { key = "slot4", type = "choice", choices = SLOTS, name = "Party member 4", tip = SLOT_TIP },

  { header = "Look" },
  { key = "hideRole", type = "bool", name = "Hide role icons" },
  { key = "hideAggro", type = "bool", name = "Hide the red threat border" },
  { key = "firstName", type = "bool", name = "First name only",
    tip = "Shows only the first word of each name." },
  { key = "centerNames", type = "bool", name = "Centre names",
    tip = "After turning this off, /reload puts the names back where Blizzard had them." },
  { key = "nameScale", type = "number", min = 0.4, max = 1.5, step = 0.05, name = "Name text size",
    tip = "1 = Blizzard's size." },
}

local byCmd = {}
for _, o in ipairs(OPTIONS) do
  if o.key then byCmd[o.key:lower()] = o end
end

local function OnChanged(key)
  if (key == "hideExtras" and not Opt("hideExtras")) or (key == "enabled" and not Opt("enabled")) then
    ShowExtras()
  end
  if key == "enabled" and not Opt("enabled") then
    Unfreeze()
    Print("off. /reload puts Blizzard's own party layout back.")
  end
  for f in pairs(isMember) do SafeRestyle(f) end
  SafeApply() -- does nothing in combat; the 0.5s check applies it afterwards
end

-- turn user input (slash text or a panel value) into a valid value: returns true, value / false
local function Clean(o, v)
  if o.type == "bool" then
    if v == true or v == "on" or v == "true" or v == "1" or v == "yes" then return true, true end
    if v == false or v == "off" or v == "false" or v == "0" or v == "no" then return true, false end
    if v == "" or v == "toggle" then return true, not Opt(o.key) end
  elseif o.type == "number" then
    local n = tonumber(v)
    if n then
      n = math.min(o.max, math.max(o.min, n))
      n = math.floor(n / o.step + 0.5) * o.step
      return true, tonumber(("%.2f"):format(n))
    end
  elseif o.type == "choice" then
    for _, c in ipairs(o.choices) do
      if c[1] == v then return true, v end
    end
  end
  return false
end

local function SetOption(o, raw)
  local ok, v = Clean(o, raw)
  if not ok or not PartyDiamondDB then return false end
  if PartyDiamondDB[o.key] ~= v then
    PartyDiamondDB[o.key] = v
    OnChanged(o.key)
  end
  return true
end

local function Shown(o)
  local v = Opt(o.key)
  if o.type == "bool" then return v and "on" or "off" end
  return tostring(v)
end

local function Usage(o)
  if o.type == "bool" then return "on|off" end
  if o.type == "number" then return o.min .. "-" .. o.max end
  local t = {}
  for _, c in ipairs(o.choices) do t[#t + 1] = c[1] end
  return table.concat(t, "|")
end

-- Options > AddOns > Party Diamond
local panelCategory
BuildPanel = function()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then return end
  local category, layout = Settings.RegisterVerticalLayoutCategory("Party Diamond")
  local function Add(initializer)
    if layout and layout.AddInitializer then layout:AddInitializer(initializer)
    elseif Settings.RegisterInitializer then Settings.RegisterInitializer(category, initializer) end
  end
  for _, o in ipairs(OPTIONS) do
    local ok, err = pcall(function()
      if o.header then
        Add(CreateSettingsListSectionHeaderInitializer(o.header))
      elseif o.button then
        Add(CreateSettingsButtonInitializer(o.name, o.button, o.click, o.tip, true))
      else
        local vtype = (o.type == "bool" and "boolean") or (o.type == "number" and "number") or "string"
        local setting = Settings.RegisterProxySetting(category, "PartyDiamond_" .. o.key, vtype, o.name,
          DEFAULTS[o.key], function() return Opt(o.key) end, function(v) SetOption(o, v) end)
        if o.type == "bool" then
          Settings.CreateCheckbox(category, setting, o.tip)
        elseif o.type == "number" then
          local opts = Settings.CreateSliderOptions(o.min, o.max, o.step)
          if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            local fmt = o.step < 1 and "%.2f" or "%d"
            opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return fmt:format(v) end)
          end
          Settings.CreateSlider(category, setting, opts, o.tip)
        else
          Settings.CreateDropdown(category, setting, function()
            local c = Settings.CreateControlTextContainer()
            for _, ch in ipairs(o.choices) do c:Add(ch[1], ch[2]) end
            return c:GetData()
          end, o.tip)
        end
      end
    end)
    if not ok and not shownErr[tostring(err)] then
      shownErr[tostring(err)] = true
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
  Print("couldn't open the options panel; use /pdiamond help.")
end

----------------------------------------------------------------------
-- /pdiamond            show what goes where
-- /pdiamond config     open the options panel
-- /pdiamond help       list every setting
-- /pdiamond move       show a handle to drag the diamond (again to lock)
-- /pdiamond <setting> <value>
----------------------------------------------------------------------
local LOOK = { "hideRole", "hideAggro", "firstName", "centerNames" }

SLASH_PARTYDIAMOND1 = "/pdiamond"
SLASH_PARTYDIAMOND2 = "/partydiamond"
SlashCmdList.PARTYDIAMOND = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  if not PartyDiamondDB then return end
  if cmd == "what" then
    -- name every small visible frame under the mouse, with its parents
    local function Name(f)
      local n = f.GetDebugName and f:GetDebugName() or f:GetName()
      return n or "(unnamed)"
    end
    local found, f = 0, EnumerateFrames()
    while f do
      local ok, over = pcall(function()
        return f:IsVisible() and f:GetEffectiveAlpha() > 0 and f:IsMouseOver()
           and (f:GetWidth() or 999) < 200 and (f:GetHeight() or 999) < 200
      end)
      if ok and over then
        found = found + 1
        local p = f:GetParent()
        Print(("  %s  (parent: %s)"):format(Name(f), p and Name(p) or "none"))
      end
      f = EnumerateFrames(f)
    end
    Print(found == 0 and "nothing small under the mouse." or "those are the frames under the mouse.")
    return
  elseif cmd == "move" then
    ToggleMove()
    return
  elseif cmd == "reset" then
    ResetPosition()
    return
  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    OpenPanel()
    return
  elseif cmd == "help" or cmd == "?" then
    Print("/pdiamond config (options panel), /pdiamond move, /pdiamond reset, /pdiamond (status). Settings:")
    for _, o in ipairs(OPTIONS) do
      if o.key then
        Print(("  /pdiamond %s %s  - %s (now %s)"):format(o.key:lower(), Usage(o), o.name, Shown(o)))
      end
    end
    return
  elseif cmd == "extras" or cmd == "names" then
    -- older command names
    local ok, v = Clean({ type = "bool", key = cmd == "extras" and "hideExtras" or "firstName" }, rest)
    if not ok then Print("usage: /pdiamond " .. cmd .. " on|off"); return end
    if cmd == "extras" then
      SetOption(byCmd.hideextras, v)
    else
      for _, k in ipairs(LOOK) do SetOption(byCmd[k:lower()], v) end
      SetOption(byCmd.namescale, v and DEFAULTS.nameScale or 1)
    end
    Print(cmd .. ": " .. (v and "on" or "off"))
    return
  elseif byCmd[cmd] then
    local o = byCmd[cmd]
    if rest == "" and o.type ~= "bool" then
      Print(("%s is %s. Usage: /pdiamond %s %s"):format(o.name, Shown(o), cmd, Usage(o)))
    elseif SetOption(o, rest) then
      Print(("%s: %s%s"):format(o.name, Shown(o), InCombatLockdown() and " (applies after combat)" or ""))
    else
      Print(("usage: /pdiamond %s %s"):format(cmd, Usage(o)))
    end
    return
  end
  SafeApply()
  local list, mode = FindFrames()
  Print(("%s; using %s party frames, %d found."):format(Opt("enabled") and "on" or "OFF", mode, #list))
  for i = 1, 4 do
    local keys = { GetBindingKey("TARGETPARTYMEMBER" .. i) }
    Print(("  party%d: spot %s, bindings: %s"):format(i, Opt("slot" .. i), #keys > 0 and table.concat(keys, ", ") or "none"))
  end
  for _, line in ipairs(lastPlan) do Print("  " .. line) end
  for _, e in ipairs(list) do
    local f = e.frame
    local alpha = f:GetEffectiveAlpha()
    Print(("  %s: shown=%s alpha=%s parent=%s"):format(f:GetName() or "?", tostring(f:IsShown()),
      Num(alpha) and ("%.2f"):format(alpha) or "hidden", (f:GetParent() and f:GetParent():GetName()) or "?"))
  end
  Print("/pdiamond config for options, /pdiamond help for commands.")
end
