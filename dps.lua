local ADDON = ...
local f = CreateFrame("Frame")

-- Config
local UPDATE_INTERVAL = 0.15
local BAR_HEIGHT = 10
local BAR_INSET = 2
local FONT_SIZE = 9

-- Combat state
local inCombat = false
local combatStart = 0
local snapshotTime = 0 -- frozen at combat end

-- guidStats[guid] = { damage, t0, dps }
local guidStats = {}
local guidToUnit = {}

-- Ownership (pets / guardians)
local ownerBySummon = {}
local ownerByUnitGUID = {}

-- Frame registry (CompactUnitFrame only)
local frameWidgets = {}

-- PlayerFrame widget (solo visibility)
local playerWidget = nil

local function Now()
  return GetTime()
end

local function Round(x)
  return (x and x > 0) and math.floor(x + 0.5) or 0
end

local function FormatDPS(dps)
  if dps >= 1e6 then
    return string.format("%.2fm", dps / 1e6)
  elseif dps >= 1e3 then
    return string.format("%.1fk", dps / 1e3)
  else
    return tostring(Round(dps))
  end
end

local function ResetCombat()
  inCombat = true
  combatStart = Now()
  snapshotTime = combatStart
  guidStats = {}
  guidToUnit = {}
  wipe(ownerBySummon)
  wipe(ownerByUnitGUID)
end

local function EndCombat()
  inCombat = false
  snapshotTime = Now() -- freeze DPS
end

local function GetOrCreateStat(guid)
  local s = guidStats[guid]
  if not s then
    s = { damage = 0, t0 = nil, dps = 0 }
    guidStats[guid] = s
  end
  return s
end

local function IsUnitFrameEligible(unit)
  return unit == "player"
    or unit and unit:match("^party%d$")
    or unit and unit:match("^raid%d+$")
end

local function ResolveOwnerGUID(srcGUID)
  return ownerByUnitGUID[srcGUID]
      or ownerBySummon[srcGUID]
      or srcGUID
end

-- ---------- Frames (Compact) ----------

local function AttachBarToCompactUnitFrame(cuf)
  if not cuf or frameWidgets[cuf] then return end
  if not cuf.unit or not IsUnitFrameEligible(cuf.unit) then return end

  local holder = CreateFrame("Frame", nil, cuf)
  holder:SetFrameLevel((cuf:GetFrameLevel() or 0) + 10)
  holder:SetAllPoints(cuf)

  local bar = CreateFrame("StatusBar", nil, holder)
  bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  bar:SetMinMaxValues(0, 1)
  bar:SetPoint("BOTTOMLEFT", cuf, "BOTTOMLEFT", BAR_INSET, BAR_INSET)
  bar:SetPoint("BOTTOMRIGHT", cuf, "BOTTOMRIGHT", -BAR_INSET, BAR_INSET)
  bar:SetHeight(BAR_HEIGHT)
  bar:SetStatusBarColor(0.2, 0.8, 0.2, 0.85)

  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(bar)
  bg:SetTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  bg:SetVertexColor(0, 0, 0, 0.45)

  local txt = bar:CreateFontString(nil, "OVERLAY")
  txt:SetPoint("CENTER", bar)
  txt:SetFont("Fonts\\FRIZQT__.TTF", FONT_SIZE, "OUTLINE")
  txt:SetText("0")

  frameWidgets[cuf] = {
    bar = bar,
    text = txt,
    unit = cuf.unit,
  }
end

-- ---------- Frames (PlayerFrame) ----------

local function AttachBarToPlayerFrame()
  if playerWidget or not PlayerFrame then return end

  local holder = CreateFrame("Frame", nil, PlayerFrame)
  holder:SetFrameLevel((PlayerFrame:GetFrameLevel() or 0) + 10)
  holder:SetAllPoints(PlayerFrame)

  local bar = CreateFrame("StatusBar", nil, holder)
  bar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  bar:SetMinMaxValues(0, 1)
  bar:SetPoint("BOTTOMLEFT", PlayerFrame, "BOTTOMLEFT", 55, 5)
  bar:SetPoint("BOTTOMRIGHT", PlayerFrame, "BOTTOMRIGHT", -20, 5)
  bar:SetHeight(BAR_HEIGHT)
  bar:SetStatusBarColor(0.2, 0.8, 0.2, 0.85)

  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(bar)
  bg:SetTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  bg:SetVertexColor(0, 0, 0, 0.45)

  local txt = bar:CreateFontString(nil, "OVERLAY")
  txt:SetPoint("CENTER", bar)
  txt:SetFont("Fonts\\FRIZQT__.TTF", FONT_SIZE, "OUTLINE")
  txt:SetText("0")

  playerWidget = {
    bar = bar,
    text = txt,
    unit = "player",
  }
end

local function EnsureBarsForVisibleFrames()
  -- PlayerFrame for solo visibility
  AttachBarToPlayerFrame()

  -- Blizzard compact party/raid
  if CompactPartyFrame and CompactPartyFrame.memberFrames then
    for _, cuf in ipairs(CompactPartyFrame.memberFrames) do
      AttachBarToCompactUnitFrame(cuf)
    end
  end
  if CompactRaidFrameContainer and CompactRaidFrameContainer.memberFrames then
    for _, cuf in ipairs(CompactRaidFrameContainer.memberFrames) do
      AttachBarToCompactUnitFrame(cuf)
    end
  end
end

local function RefreshUnitGuidMappings()
  wipe(guidToUnit)

  -- Always map player if it exists (needed when solo)
  local pGuid = UnitGUID("player")
  if pGuid then
    guidToUnit[pGuid] = "player"
  end

  for cuf, w in pairs(frameWidgets) do
    if cuf.unit and IsUnitFrameEligible(cuf.unit) then
      w.unit = cuf.unit
      local guid = UnitGUID(cuf.unit)
      if guid then
        guidToUnit[guid] = cuf.unit
      end
    end
  end
end

local function RefreshPetGuidMappings()
  wipe(ownerByUnitGUID)

  local function map(owner, pet)
    local og = UnitGUID(owner)
    local pg = UnitGUID(pet)
    if og and pg then ownerByUnitGUID[pg] = og end
  end

  map("player", "pet")

  for i = 1, 4 do
    map("party"..i, "party"..i.."pet")
  end
  for i = 1, 40 do
    map("raid"..i, "raid"..i.."pet")
  end
end

-- ---------- DPS ----------

local function ComputeAllDPS()
  local t = inCombat and Now() or snapshotTime
  local maxDPS = 0

  for _, s in pairs(guidStats) do
    if s.t0 then
      local dt = t - s.t0
      s.dps = (dt > 0) and (s.damage / dt) or 0
      if s.dps > maxDPS then maxDPS = s.dps end
    else
      s.dps = 0
    end
  end

  return maxDPS > 0 and maxDPS or 1
end

local function UpdateOneWidget(widget, maxDPS)
  if not widget then return end
  local unit = widget.unit
  if not unit or not UnitExists(unit) then
    widget.bar:Hide()
    return
  end

  local guid = UnitGUID(unit)
  local s = guid and guidStats[guid]
  local dps = s and s.dps or 0

  widget.bar:SetValue(dps / maxDPS)
  widget.text:SetText(FormatDPS(dps))
  widget.bar:Show()
end

local function UpdateBars()
  if inCombat then snapshotTime = Now() end

  EnsureBarsForVisibleFrames()
  RefreshUnitGuidMappings()
  RefreshPetGuidMappings()

  local maxDPS = ComputeAllDPS()

  -- PlayerFrame widget always gets updated
  if PlayerFrame and PlayerFrame:IsShown() then
    UpdateOneWidget(playerWidget, maxDPS)
  elseif playerWidget then
    playerWidget.bar:Hide()
  end

  -- Compact frames
  for cuf, w in pairs(frameWidgets) do
    if w.unit and UnitExists(w.unit) and cuf:IsShown() then
      UpdateOneWidget(w, maxDPS)
    else
      w.bar:Hide()
    end
  end
end

-- ---------- Combat log ----------

local DAMAGE_EVENTS = {
  SWING_DAMAGE = true,
  RANGE_DAMAGE = true,
  SPELL_DAMAGE = true,
  SPELL_PERIODIC_DAMAGE = true,
  DAMAGE_SHIELD = true,
  DAMAGE_SPLIT = true,
}

local function OnCombatLogEvent()
  if not inCombat then return end

  local _, subevent,
    _, srcGUID, _, _, _,
    destGUID = CombatLogGetCurrentEventInfo()

  if subevent == "SPELL_SUMMON" and srcGUID and destGUID then
    ownerBySummon[destGUID] = srcGUID
    return
  end

  if not DAMAGE_EVENTS[subevent] or not srcGUID then return end

  local amount = (subevent == "SWING_DAMAGE")
    and select(12, CombatLogGetCurrentEventInfo())
    or  select(15, CombatLogGetCurrentEventInfo())

  if not amount or amount <= 0 then return end

  local ownerGUID = ResolveOwnerGUID(srcGUID)
  if not guidToUnit[ownerGUID] then return end

  local s = GetOrCreateStat(ownerGUID)
  if not s.t0 then s.t0 = Now() end
  s.damage = s.damage + amount
end

-- ---------- Events ----------

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("COMPACT_UNIT_FRAME_PROFILES_LOADED")
f:RegisterEvent("UNIT_PET")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

local elapsed = 0
f:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed >= UPDATE_INTERVAL then
    elapsed = 0
    UpdateBars()
  end
end)

f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_DISABLED" then
    ResetCombat()
  elseif event == "PLAYER_REGEN_ENABLED" then
    EndCombat()
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLogEvent()
    return
  end

  EnsureBarsForVisibleFrames()
  RefreshUnitGuidMappings()
  RefreshPetGuidMappings()
  UpdateBars()
end)

hooksecurefunc("CompactUnitFrame_SetUnit", function(cuf, unit)
  if unit and IsUnitFrameEligible(unit) then
    AttachBarToCompactUnitFrame(cuf)
  end
end)
