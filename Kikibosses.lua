local function print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local function ClearTable(t)
  for k in pairs (t) do
    t[k] = nil
  end
end

local function GetArLength(arr) -- get array length
  if arr then
    return table.getn(arr)
  else
    return 0
  end
end

local function HasDebuff(unit_id, debuff)
  for i=1,16 do
    local icon_link = UnitDebuff(unit_id, i)
    if not icon_link then
      break
    end
    if icon_link == debuff then
      return true
    end
  end
  return false
end

local function EOHeal(unitIDs_cache, unitIDs, value, target)
  local unitID = GetUnitID(unitIDs_cache, unitIDs, target)
  local eheal = 0
  local oheal = 0
  if unitID then
    eheal = math.min(UnitHealthMax(unitID) - UnitHealth(unitID), value)
    oheal = value-eheal
  end
  return eheal, oheal
end

local function ParseHealers(args, healers) -- SR data
  args = args.."#" -- add # so last argument will be matched as well
  local pattern = "(%w+)#"
  local idx = 1
  local rw_text = "Healer rotation: "
  for healer in string.gfind(args, pattern) do
    healers[idx] = healer
    idx = idx+1
    rw_text = rw_text..healer.." -> "
  end
  SendChatMessage(rw_text, "RAID_WARNING")
end

local function GetUnitID(unitIDs_cache, unitIDs, name)
  if unitIDs_cache[name] and UnitName(unitIDs_cache[name]) == name then
    return unitIDs_cache[name]
  end
  for _,unitID in pairs(unitIDs) do
    if UnitName(unitID) == name then
      unitIDs_cache[name] = unitID
      return unitID
    end
  end
end

local function InTable(val, tbl)
  for _, value in pairs(tbl) do
    if value == val then
        return true
    end
  end
  return false
end

----------
-- Init --
----------
local player_name = UnitName("player")
local unitIDs = {"player"} -- unitID player
for i=2,5 do unitIDs[i] = "party"..i-1 end -- unitIDs party
for i=6,45 do unitIDs[i] = "raid"..i-5 end -- unitIDs raid
local unitIDs_cache = {} -- init unitIDs_cache[name] = unitID

local boss_mode = ""
local loatheb = {}
local horsemen = {}

---------------------------------
-- Horsemen Healing Rotation --
---------------------------------
horsemen.update_frame = CreateFrame("Frame")
horsemen.event_frame = CreateFrame("Frame")
horsemen.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE") -- horsemen mark event
horsemen.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE") -- horsemen mark event
horsemen.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE") -- horsemen mark event
horsemen.ti_mark_start = -1
horsemen.ct_marks = 0
horsemen.ti_mark_interval = 12
horsemen.bosses = {"THANE", "BLAUMEUX", "ZELIEK", "MOGRAINE"}
horsemen.bosses_idx = {
  T=1,
  B=2,
  Z=3,
  M=4
}

horsemen.update_frame:SetScript("OnUpdate", function()
  if (boss_mode=="horsemen") and (horsemen.ti_mark_start>0) and (GetTime() > horsemen.ti_mark_start + horsemen.ti_mark_interval*horsemen.ct_marks) then
    if (math.mod(horsemen.ct_marks, 3)+1)==horsemen.mark_player then
      horsemen.boss_idx = math.mod(horsemen.boss_idx, 4)+1
      print("Mark: "..(horsemen.ct_marks+1).." MOVE TO "..horsemen.bosses[horsemen.boss_idx].."!")
      -- PlaySoundFile("Interface\\AddOns\\Kikibosses\\SFX\\horsemen_move.mp3")
      PlaySoundFile("Interface\\AddOns\\Kikibosses\\SFX\\horsemen_move"..horsemen.boss_idx..".mp3")
    else
      print("Mark: "..(horsemen.ct_marks+1).." STAY AT "..horsemen.bosses[horsemen.boss_idx].."!")
    end
    horsemen.ct_marks = horsemen.ct_marks + 1
  end
end)

horsemen.event_frame:SetScript("OnEvent", function()
  if (boss_mode == "horsemen") and (horsemen.ti_mark_start<0) then
    if string.find(arg1, " afflicted by Mark of ") then
      horsemen.ti_mark_start = GetTime()
      horsemen.ct_marks = 0
    end
  end
end)


------------------------------
-- Loatheb Healing Rotation --
------------------------------
loatheb.healers = {}
loatheb.spells = {"Greater Heal", "Healing Touch", "Healing Wave", "Holy Light"}
loatheb.event_frame = CreateFrame("Frame")
loatheb.update_frame = CreateFrame("Frame")
loatheb.debuff_timer = -1
loatheb.rw_text = ""
-- DETECT HEALS
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_PARTY_BUFF")
loatheb.event_frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS")

local function MakeGfindReady(template) -- changes global string to fit gfind pattern
  template = gsub(template, "%%s", "(.+)") -- % is escape: %%s = %s raw
  return gsub(template, "%%d", "(%%d+)")
end

local combatlog_patterns = {} -- parser for combat log, order = {source, attack, target, value, school}, if not presenst = nil; parse order matters!!
-- ####### HEAL SOURCE:ME TARGET:ME
combatlog_patterns[1] = {string=MakeGfindReady(HEALEDCRITSELFSELF), order={nil, 1, nil, 2, nil}, kind="heal"} -- Your %s critically heals you for %d. (parse before Your %s heals you for %d.)
combatlog_patterns[2] = {string=MakeGfindReady(HEALEDSELFSELF), order={nil, 1, nil, 2, nil}, kind="heal"} -- Your %s heals you for %d.
-- combatlog_patterns[6] = {string=MakeGfindReady(PERIODICAURAHEALSELFSELF), order={nil, 2, nil, 1, nil}, kind="heal"} -- You gain %d health from %s.
-- ####### HEAL SOURCE:OTHER TARGET:ME
combatlog_patterns[3] = {string=MakeGfindReady(HEALEDCRITOTHERSELF), order={1, 2, nil, 3, nil}, kind="heal"} -- %s's %s critically heals you for %d. (parse before %s's %s critically heals %s for %d.)
combatlog_patterns[4] = {string=MakeGfindReady(HEALEDOTHERSELF), order={1, 2, nil, 3, nil}, kind="heal"} -- %s's %s heals you for %d.
-- combatlog_patterns[3] = {string=MakeGfindReady(PERIODICAURAHEALOTHERSELF), order={2, 3, nil, 1, nil}, kind="heal"} -- You gain %d health from %s's %s. (parse before You gain %d health from %s.)
-- ####### HEAL SOURCE:ME TARGET:OTHER
combatlog_patterns[5] = {string=MakeGfindReady(HEALEDCRITSELFOTHER), order={nil, 1, 2, 3, nil}, kind="heal"} -- Your %s critically heals %s for %d. (parse before Your %s heals %s for %d.)
combatlog_patterns[6] = {string=MakeGfindReady(HEALEDSELFOTHER), order={nil, 1, 2, 3, nil}, kind="heal"} -- Your %s heals %s for %d.
-- combatlog_patterns[9] = {string=MakeGfindReady(PERIODICAURAHEALSELFOTHER), order={nil, 3, 1, 2, nil}, kind="heal"} -- %s gains %d health from your %s.
-- ####### HEAL SOURCE:OTHER TARGET:OTHER
combatlog_patterns[7] = {string=MakeGfindReady(HEALEDCRITOTHEROTHER), order={1, 2, 3, 4, nil}, kind="heal"} -- %s's %s critically heals %s for %d.
combatlog_patterns[8] = {string=MakeGfindReady(HEALEDOTHEROTHER), order={1, 2, 3, 4, nil}, kind="heal"} -- %s's %s heals %s for %d.
-- combatlog_patterns[12] = {string=MakeGfindReady(PERIODICAURAHEALOTHEROTHER), order={3, 4, 1, 2, nil}, kind="heal"} -- %s gains %d health from %s's %s.

loatheb.update_frame:SetScript("OnUpdate", function()
  if (boss_mode=="loatheb") and (loatheb.debuff_timer>0) and (GetTime() > loatheb.debuff_timer + 0.2) then -- check debuff 200ms after heal has been cast (there's a bit of a delay for it to get applied)
    for idx, healer in ipairs(loatheb.healers) do -- always start at 1 in the list and search first healer that can heal (so you can prioritise strong healers)
      local healer_id = GetUnitID(unitIDs_cache, unitIDs, healer)
      local healer_debuff = HasDebuff(healer_id, "Interface\\Icons\\Spell_Shadow_AuraOfDarkness") -- only works with icon link, idk
      -- local healer_debuff = HasDebuff(healer_id, "Interface\\Icons\\Spell_Holy_AshesToAshes") -- priest shield debuff for testing
      local healer_dead = UnitIsDeadOrGhost(healer_id)

      if (not healer_debuff) and (not healer_dead) then
        loatheb.rw_text = loatheb.rw_text.." -> "..healer.." next"
        break
      elseif idx == loatheb.num_healers then
        loatheb.rw_text = loatheb.rw_text.." -> no healer available (heal as soon as you can)"
      end
    end
    SendChatMessage(loatheb.rw_text, "RAID_WARNING")
    loatheb.debuff_timer = -1
  end
end)


loatheb.event_frame:SetScript("OnEvent", function()
  if boss_mode=="loatheb" then
    local pars = {}
    for _,combatlog_pattern in ipairs(combatlog_patterns) do
      for par_1, par_2, par_3, par_4, par_5 in string.gfind(arg1, combatlog_pattern.string) do
        pars = {par_1, par_2, par_3, par_4, par_5}
        local source = pars[combatlog_pattern.order[1]]
        local spell = pars[combatlog_pattern.order[2]]
        local target = pars[combatlog_pattern.order[3]]
        local value = pars[combatlog_pattern.order[4]]
        local school = pars[combatlog_pattern.order[5]]

        -- Default values, e.g. for "You hit xyz for 15"
        if not source then
          source = player_name
        end
        if not spell then
          spell = "Hit"
        end
        if not target then
          target = player_name
        end
        if not value then
          value = 0
        end

        if InTable(source, loatheb.healers) and InTable(spell, loatheb.spells)  then
          local eheal, oheal = EOHeal(unitIDs_cache, unitIDs, value, target)
          local ra_text = source.." used "..spell.." to heal "..target.." for "..eheal.." (+"..oheal..")"
          SendChatMessage(ra_text, "RAID")
          loatheb.rw_text = source.." healed"
          loatheb.debuff_timer = GetTime()
        end
        return
      end
    end
  end
end)

--------------------
-- Slash Commands --
--------------------

SLASH_KIKIBOSSES1 = "/kikibosses"
SlashCmdList["KIKIBOSSES"] = function(msg)
  local _, _, cmd, args = string.find(msg, "%s?(%w+)%s?(.*)")
  if (msg == "" or msg == nil) then
    print("/kikibosses loatheb Kikidora#Slewdem#...")
    print("/kikibosses Z2")
  elseif cmd == "loatheb" then
    if boss_mode == "loatheb" then
      boss_mode = ""
      print("Kikibosses: Loatheb deactivated.")
    else
      boss_mode = "loatheb"
      ClearTable(loatheb.healers)
      ParseHealers(args, loatheb.healers)
      loatheb.num_healers = GetArLength(loatheb.healers)
      print("Kikibosses: Loatheb activated.")
    end
  elseif cmd == "horsemen" then
    if boss_mode == "horsemen" then
      boss_mode = ""
      print("Kikibosses: Horsemen deactivated.")
    else
      boss_mode = "horsemen"
      horsemen.boss_idx = horsemen.bosses_idx[string.sub(args,1,1)] -- translates T=1, B=2, Z=3, M=4
      horsemen.mark_player = tonumber(string.sub(args,2,2))
      horsemen.ti_mark_start = -1
      horsemen.ti_mark_interval = 12
      horsemen.ct_marks = 0
      print("Kikibosses: Horsemen activated.")
    end
  elseif cmd == "horsementest" then
    if boss_mode == "horsemen" then
      boss_mode = ""
      print("Kikibosses: Horsemen deactivated.")
    else
      boss_mode = "horsemen"
      horsemen.boss_idx = horsemen.bosses_idx[string.sub(args,1,1)]
      horsemen.mark_player = tonumber(string.sub(args,2,2))
      horsemen.ti_mark_start = GetTime()
      horsemen.ti_mark_interval = 2
      horsemen.ct_marks = 0
      print("Kikibosses: Horsemen activated. Test enabled!")
    end
  end
end