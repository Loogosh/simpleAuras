local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")
f:SetScript("OnEvent", function()
	
		---------------------------------------------------
		-- SavedVariables Initialization
		---------------------------------------------------

		-- Ensure tables exist
		simpleAuras = simpleAuras or {}
		simpleAuras.auras   = simpleAuras.auras   or {}
		simpleAuras.refresh = simpleAuras.refresh or 5
		simpleAuras.reactiveDurations = simpleAuras.reactiveDurations or {}  -- Reactive spell durations
		if sA.SuperWoW then
		  simpleAuras.auradurations = simpleAuras.auradurations or {}
		  simpleAuras.updating      = simpleAuras.updating or 0
		  simpleAuras.showlearning  = simpleAuras.showlearning or 0
		  simpleAuras.learnall      = simpleAuras.learnall or 0
		end
		
		sA.SettingsLoaded = 1
		
		-- Initialize aura cache on load
		sA:InitializeAuraCache()
		
		sA:CreateTestAuras()

		table.insert(UISpecialFrames, "sATest")
		table.insert(UISpecialFrames, "sATestDual")

end)

-- runtime only
sA = sA or { 
  auraTimers = {}, 
  learnCastTimers = {}, 
  learnNew = {}, 
  frames = {}, 
  dualframes = {}, 
  draggers = {}, 
  activeAuras = {},
  reactiveTimers = {}       -- [spellName] = {expiry, warnedOnce}
}

-- Get version from .toc file using WoW API
sA.VERSION = GetAddOnMetadata("simpleAuras", "Version") or "1.0"

sA.SuperWoW = SetAutoloot and true or false
local _, playerGUID = UnitExists("player")
sA.playerGUID = playerGUID
sA.SettingsLoaded = nil

-- perf: cache globals we use a lot (Lua 5.0-safe)
local gsub   = string.gsub
local find   = string.find
local lower  = string.lower
local floor  = math.floor
local tinsert = table.insert
local getn   = table.getn
local GetTime = GetTime

-- message helper
sA.PREFIX = "|c194b7dccsimple|cffffffffAuras v" .. (sA.VERSION or "1.0") .. ": "
function sA:Msg(msg)
  DEFAULT_CHAT_FRAME:AddMessage(self.PREFIX .. msg)
end

---------------------------------------------------
-- Helper Functions
---------------------------------------------------

local function GetAuraDurationBySpellID(spellID, casterGUID)
  if not spellID or not casterGUID then return nil end
  if type(simpleAuras.auradurations[spellID]) ~= "table" then
	simpleAuras.auradurations[spellID] = nil
	return nil
  end
  return simpleAuras.auradurations[spellID][casterGUID]
end

local function getAuraID(spellName)
    local auraFound = {}
    for auraID, aura in ipairs(simpleAuras.auras) do
        if aura.name == spellName then
            table.insert(auraFound, auraID)
        end
    end
    if getn(auraFound) > 0 then
        return auraFound
    else
        return {}
    end
end

-- SuperWoW: learn and track aura durations
if sA.SuperWoW then
  local sADuration = CreateFrame("Frame")
  sADuration:RegisterEvent("RAW_COMBATLOG")
  sADuration:RegisterEvent("UNIT_CASTEVENT")
  sADuration:SetScript("OnEvent", function()
    local timestamp = GetTime()

    if event == "RAW_COMBATLOG" and simpleAuras.auradurations then
      local raw = arg2
      if not raw or not find(raw, "fades from") then return end

      local _, _, spellName  = string.find(raw, "^(.-) fades from ")
      local _, _, targetGUID = string.find(raw, "from (.-).$")

      if lower(targetGUID or "") == "you" then _, targetGUID = UnitExists("player") end
      targetGUID = gsub(targetGUID or "", "^0x", "")
      if not spellName or targetGUID == "" then return end
      if not sA.auraTimers[targetGUID] then return end

      for spellID in pairs(sA.auraTimers[targetGUID]) do
        local n = SpellInfo(spellID)
        if n then
          n = gsub(n, "%s*%(%s*Rank%s+%d+%s*%)", "")
          if n == spellName then
            -- if we were learning this duration, compute actual
			
            if sA.learnCastTimers[targetGUID] and sA.learnCastTimers[targetGUID][spellID] and sA.learnCastTimers[targetGUID][spellID].duration then
              local castTime = sA.learnCastTimers[targetGUID][spellID].duration
              local actual   = timestamp - castTime
			  local casterGUID = sA.learnCastTimers[targetGUID][spellID].castby
			  simpleAuras.auradurations[spellID] = simpleAuras.auradurations[spellID] or {}
              simpleAuras.auradurations[spellID][casterGUID] = floor(actual + 0.5)
			  sA.learnNew[spellID] = nil
              if simpleAuras.updating == 1 then
                local casterType = (casterGUID == sA.playerGUID) and "your" or "ally's"
                sA:Msg("Updated " .. casterType .. " " .. spellName .. " (ID:"..spellID..") to: " .. floor(actual + 0.5) .. "s")
              elseif simpleAuras.showlearning == 1 then
                local casterType = (casterGUID == sA.playerGUID) and "your" or "ally's"
				sA:Msg("Learned " .. casterType .. " " .. spellName .. " (ID:"..spellID..") duration: " .. floor(actual + 0.5) .. "s")
			  end
              sA.learnCastTimers[targetGUID][spellID].duration = nil
              sA.learnCastTimers[targetGUID][spellID].castby = nil
            end
			
			if sA.auraTimers[targetGUID][spellID].duration <= timestamp then
				sA.auraTimers[targetGUID][spellID] = nil
			end
			
            if not next(sA.auraTimers[targetGUID]) then
              sA.auraTimers[targetGUID] = nil
            end
            break
          end
        end
      end

    elseif event == "UNIT_CASTEVENT" and simpleAuras.auradurations then
      local casterGUID, targetGUID, evType, spellID = arg1, arg2, arg3, arg4
      if evType ~= "CAST" or not spellID then return end
	  
      local spellName = SpellInfo(spellID)
      
      -- Check if player used a reactive spell (before aura learning logic)
      if sA.playerGUID then
        sA.playerGUID = gsub(sA.playerGUID, "^0x", "")
      else
        local _, playerGUID = UnitExists("player")
        sA.playerGUID = playerGUID
      end
      local checkCasterGUID = gsub(casterGUID or "", "^0x", "")
      if checkCasterGUID == sA.playerGUID and spellName then
        sA:HandleReactiveSpellUsed(spellName)
      end
      
	  local auraIDs = getAuraID(spellName)

	  if ((auraIDs and getn(auraIDs) > 0) or simpleAuras.learnall == 1) and spellID then

		  if sA.playerGUID then
			sA.playerGUID = gsub(sA.playerGUID, "^0x", "")
		  else
			local _, playerGUID = UnitExists("player")
			sA.playerGUID = playerGUID
		  end
		  
		  casterGUID = gsub(casterGUID or "", "^0x", "")
		  if targetGUID then targetGUID = gsub(targetGUID, "^0x", "") end

		  local dur = GetAuraDurationBySpellID(spellID,casterGUID)
	  
		  if dur and dur > 0 and simpleAuras.updating == 0 then
			-- Use known duration from any caster (not just player)
			sA.auraTimers[targetGUID] = sA.auraTimers[targetGUID] or {}
			sA.auraTimers[targetGUID][spellID] = sA.auraTimers[targetGUID][spellID] or {}
			if not sA.auraTimers[targetGUID][spellID].duration or (dur + timestamp) > sA.auraTimers[targetGUID][spellID].duration then
				sA.auraTimers[targetGUID][spellID].duration = timestamp + dur
				sA.auraTimers[targetGUID][spellID].castby = casterGUID
			end
			sA.learnNew[spellID] = nil
		  else
			-- Learn duration from any caster (not just player)

			local showLearn = nil
						
			if not targetGUID or targetGUID == "" then targetGUID = sA.playerGUID end
			
			sA.learnCastTimers[targetGUID] = sA.learnCastTimers[targetGUID] or {}
			sA.learnCastTimers[targetGUID][spellID] = sA.learnCastTimers[targetGUID][spellID] or {}
			sA.learnCastTimers[targetGUID][spellID].duration = timestamp
			sA.learnCastTimers[targetGUID][spellID].castby = casterGUID
			
			sA.auraTimers[targetGUID] = sA.auraTimers[targetGUID] or {}
			sA.auraTimers[targetGUID][spellID] = sA.auraTimers[targetGUID][spellID] or {}
			sA.auraTimers[targetGUID][spellID].duration = 0
			sA.auraTimers[targetGUID][spellID].castby = casterGUID
									
			for _, auraID in ipairs(auraIDs) do
				if simpleAuras.auras[auraID].unit ~= "Player" and simpleAuras.auras[auraID].type ~= "Cooldown" then
					showLearn = true
					break
				end
			end
						
			-- Show learning notification for any caster if aura is tracked
			if showLearn and targetGUID ~= sA.playerGUID then
				sA.learnNew[spellID] = 1
			end
			
			-- Display learning message for any caster
			if simpleAuras.updating == 1 then
			  local casterName = (casterGUID == sA.playerGUID) and "your" or "ally's"
			  sA:Msg("Updating " .. casterName .. " " .. (spellName or spellID) .. " (ID:"..spellID..")...")
			elseif simpleAuras.showlearning == 1 then
			  local casterName = (casterGUID == sA.playerGUID) and "your" or "ally's"
			  sA:Msg("Learning " .. casterName .. " " .. (spellName or spellID) .. " (ID:"..spellID..")...")
			end
			
		  end
		  
	  end
	  
    end
  end)
end

-- Periodic data updates (controlled by /sa refresh setting)
-- This is the HEAVY operation: scans UnitBuff, UnitDebuff, GetSpellCooldown
local sADataUpdate = CreateFrame("Frame", "sADataUpdate", UIParent)
sADataUpdate:SetScript("OnUpdate", function()
	if not sA.SettingsLoaded then return end
	
	local time = GetTime()
	-- Frequency controlled by simpleAuras.refresh (1-10 per second)
	local dataRefreshRate = 1 / (simpleAuras.refresh or 5)
	if (time - (sADataUpdate.lastUpdate or 0)) < dataRefreshRate then return end
	
	sADataUpdate.lastUpdate = time
	
	-- Rescan auras (catches missed events + provides periodic fallback)
	sA:UpdateAuraDataForUnit("Player")
	if UnitExists("target") then
		sA:UpdateAuraDataForUnit("Target")
	else
		-- Clear target auras if no target exists
		for id, aura in ipairs(simpleAuras.auras or {}) do
			if aura and aura.unit == "Target" and sA.activeAuras[id] then
				sA.activeAuras[id].active = false
				sA.activeAuras[id].expiry = nil
			end
		end
	end
	sA:UpdateCooldownData()
	sA:UpdateReactiveData()
end)

-- GUI rendering updates (fixed at 20 FPS for smooth animations)
-- This is LIGHT operation: only math (expiry - GetTime) and text updates
local sAEvent = CreateFrame("Frame", "sAEvent", UIParent)
sAEvent:SetScript("OnUpdate", function()

	local time = GetTime()
	local guiRefreshRate = 1 / 20  -- Fixed 20 FPS (0.05 seconds)
	if (time - (sAEvent.lastUpdate or 0)) < guiRefreshRate then return end
		
  -- Cache the UI scale in a safe context
  sA.uiScale = UIParent:GetEffectiveScale()

  -- Handle Move Mode with Ctrl Key
  local mainFrame = _G["sAGUI"]
  if mainFrame and mainFrame:IsVisible() and IsControlKeyDown() and IsAltKeyDown() and IsShiftKeyDown() then

	if sA.moveAuras ~= 1 then
			
		-- TestAura
		if sA.TestAura and sA.TestAura:IsVisible() then
			
			sA.draggers[0]:Show()
			gui:SetAlpha(0)
			gui.editor:SetAlpha(0)
			
		else
	  
			-- Continuously show draggers for any visible frames while in move mode
			for id, frame in pairs(sA.frames) do
			  if frame:IsVisible() and sA.draggers[id] then
				sA.draggers[id]:Show()
				gui:SetAlpha(0)
				if gui.editor then
				  gui.editor:SetAlpha(0)
				end
			  end
			end
			
		end

		sA.moveAuras = 1

	end
	
  else

	if sA.moveAuras == 1 then
				
		-- Hide all draggers when not in move mode
	    for id, dragger in pairs(sA.draggers) do
	      if dragger then
			dragger:Hide()
	        gui:SetAlpha(1)
			if gui.editor then
	          gui.editor:SetAlpha(1)
			end
		  end
	    end
		
		-- Reload data if in editor
		if gui.editor and gui.auraEdit and sA.draggers[0] and sA.draggers[0]:IsVisible() then
			
			sA:SaveAura(gui.auraEdit)
			
		end

		sA.moveAuras = 0

	end
	
  end
		
  sAEvent.lastUpdate = time
  -- Only render GUI, don't fetch data here
  sA:UpdateAuras()
		
end)

-- Combat state
local sACombat = CreateFrame("Frame")
sACombat:RegisterEvent("PLAYER_REGEN_DISABLED")
sACombat:RegisterEvent("PLAYER_REGEN_ENABLED")
sACombat:SetScript("OnEvent", function()
  if event == "PLAYER_REGEN_DISABLED" then
    sAinCombat = true
  elseif event == "PLAYER_REGEN_ENABLED" then
    sAinCombat = nil
  end
end)

-- Aura tracking events (event-driven updates)
local sAAuraTracker = CreateFrame("Frame")
sAAuraTracker:RegisterEvent("UNIT_AURA")
sAAuraTracker:RegisterEvent("PLAYER_AURAS_CHANGED")
sAAuraTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
sAAuraTracker:RegisterEvent("SPELL_UPDATE_COOLDOWN")
sAAuraTracker:RegisterEvent("SPELL_UPDATE_USABLE")
sAAuraTracker:RegisterEvent("COMBAT_TEXT_UPDATE")
sAAuraTracker:SetScript("OnEvent", function()
  if not sA.SettingsLoaded then return end
  
  if event == "UNIT_AURA" then
    local unit = arg1
    -- Update data for auras tracking this unit
    if unit == "player" then
      sA:UpdateAuraDataForUnit("Player")
    elseif unit == "target" then
      sA:UpdateAuraDataForUnit("Target")
    end
    
  elseif event == "PLAYER_AURAS_CHANGED" then
    -- Fallback event for player auras
    sA:UpdateAuraDataForUnit("Player")
    
  elseif event == "PLAYER_TARGET_CHANGED" then
    -- Target changed, clear old target auras first, then scan new target
    for id, aura in ipairs(simpleAuras.auras or {}) do
      if aura and aura.unit == "Target" and sA.activeAuras[id] then
        sA.activeAuras[id].active = false
        sA.activeAuras[id].expiry = nil
      end
    end
    -- Now scan new target
    if UnitExists("target") then
      sA:UpdateAuraDataForUnit("Target")
    end
    
  elseif event == "SPELL_UPDATE_COOLDOWN" then
    -- Update all cooldown-type auras
    sA:UpdateCooldownData()
    
  elseif event == "SPELL_UPDATE_USABLE" then
    -- Update reactive spell states (proc-based abilities)
    sA:UpdateReactiveData()
    
  elseif event == "COMBAT_TEXT_UPDATE" then
    -- Floating Combat Text event - fires for reactive ability activation
    -- NOTE: COMBAT_TEXT_UPDATE SPELL_ACTIVE only fires when ability BECOMES available,
    --       not on subsequent procs while already active. For 100% proc tracking,
    --       consider using CHAT_MSG_COMBAT_SELF_MISSES to detect dodge/parry/block
    --       and manually refresh reactive timers.
    local updateType = arg1
    local spellName = arg2
    
    if updateType == "SPELL_ACTIVE" and spellName then
      -- Trim whitespace from spell name
      spellName = gsub(spellName, "^%s+", "")
      spellName = gsub(spellName, "%s+$", "")
      
      -- Reactive ability became active
      sA:HandleReactiveActivation(spellName)
    end
  end
end)

---------------------------------------------------
-- Slash Commands
---------------------------------------------------
SLASH_sA1 = "/sa"
SLASH_sA2 = "/simpleauras"
SlashCmdList["sA"] = function(msg)

	-- Get Command
	if type(msg) ~= "string" then
		msg = ""
	end

	-- Get Command Arguments (improved parser for multi-word args)
	local cmd, val, fad, restOfMsg
	-- Extract first word as command, rest as args
	cmd = string.match(msg, "^(%S+)")
	restOfMsg = string.match(msg, "^%S+%s+(.*)$")
	
	if not cmd then cmd = "" end
	if not restOfMsg then restOfMsg = "" end
	
	-- For backward compatibility: try to extract val and fad from restOfMsg
	local s, e, a, b = string.find(restOfMsg, "^(%S*)%s*(%S*)$")
	if a then val = a else val = "" end
	if b then fad = b else fad = "" end
	
	
	-- hide / show or no command
	if cmd == "" or cmd == "show" or cmd == "hide" then
		if gui.auraEdit then gui.auraEdit = nil end
		if cmd == "show" then
			if not gui:IsVisible() then gui:Show() end
		elseif cmd == "hide" then
			if gui:IsVisible() then gui:Hide() sA.TestAura:Hide() sA.TestAuraDual:Hide() end
		else 
			if gui:IsVisible() then gui:Hide() sA.TestAura:Hide() sA.TestAuraDual:Hide() else gui:Show() end
		end
		sA:RefreshAuraList()
		return
	end
	
	-- refresh command
	if cmd == "refresh" then
		local num = tonumber(val)
		if num and num >= 1 and num <= 10 then
			simpleAuras.refresh = num
			sA:Msg("Data scan rate set to " .. num .. " times per second")
		else
			sA:Msg("Usage: /sa refresh X - set aura data scan rate. (1 to 10 scans per second. Default: 5).")
			sA:Msg("Note: GUI always renders at 20 FPS. This controls how often aura data is fetched.")
			sA:Msg("Current scan rate = " .. simpleAuras.refresh .. " times per second.")
		end
		return
	end
	
	-- learnall command
	if cmd == "learnall" then
		if sA.SuperWoW then
			local num = tonumber(val)
			if num and (num == 0 or num == 1) then
				simpleAuras.learnall = num
				sA:Msg("LearnAll set to " .. num)
			else
				sA:Msg("Usage: /sa learnall X - learn all AuraDurations, even if no Aura is set up. (1 = Active. Default: 0).")
				sA:Msg("Current LearnAll status = " .. simpleAuras.learnall)
			end
		else
			sA:Msg("/sa showlearning needs SuperWoW to be installed!")
		end
		return
	end
	
	-- refresh command
	if cmd == "update" or cmd == "relearn" then
		local num = tonumber(val)
		if num and (num == 0 or num == 1) then
			simpleAuras.updating = num
			sA:Msg("Aura durations update status set to " .. num)
		else
			sA:Msg("Usage: /sa update X - force aura durations updates (1 = re-learn durations. Default: 0).")
			sA:Msg("Note: Reactive spells use manual duration setting (/sa reactduration).")
			sA:Msg("Current update status = " .. simpleAuras.updating)
		end
		return
	end
	
	-- manual learning of durations
	if cmd == "learn" then
		if sA.SuperWoW then
			local spell = tonumber(val)
			local fade = tonumber(fad)
			if spell and fade then
				local _, playerGUID = UnitExists("player")
				playerGUID = gsub(playerGUID, "^0x", "")
				simpleAuras.auradurations[spell] = simpleAuras.auradurations[spell] or {}
				simpleAuras.auradurations[spell][playerGUID] = fade
				sA:Msg("Set Duration of "..SpellInfo(spell).."("..spell..") to " .. fade .. " seconds.")
			else
				sA:Msg("Usage: /sa learn X Y - manually set duration Y of spellID X.")
			end
		else
			sA:Msg("/sa learn needs SuperWoW to be installed!")
		end
		return
	end
	
	-- track others
	if cmd == "showlearning" then
		local num = tonumber(val)
		if num and (num == 0 or num == 1) then
			simpleAuras.showlearning = num
			sA:Msg("ShowLearning status set to " .. num)
		else
			sA:Msg("Usage: /sa showlearning X - shows learning messages in chat (1 = show. Default: 0).")
			sA:Msg("Works for both auras (SuperWoW) and reactive spells.")
			sA:Msg("Current ShowLearning status = " .. simpleAuras.showlearning)
		end
		return
	end
	
	-- reactduration command (special parsing for spell names with spaces)
	if cmd == "reactduration" then
		-- Extract everything after "reactduration" and parse manually
		local fullArgs = string.match(msg, "^reactduration%s+(.+)$")
		
		if fullArgs then
			-- Find last number (duration)
			local duration = tonumber(string.match(fullArgs, "(%d+)%s*$"))
			if duration and duration > 0 then
				-- Extract spell name/ID (everything before last number)
				local spellIdentifier = string.match(fullArgs, "^(.-)%s*%d+%s*$")
				-- Remove quotes if present
				spellIdentifier = string.gsub(spellIdentifier or "", "^[\"']+", "")
				spellIdentifier = string.gsub(spellIdentifier, "[\"']+$", "")
				spellIdentifier = string.gsub(spellIdentifier, "^%s+", "")
				spellIdentifier = string.gsub(spellIdentifier, "%s+$", "")
				
				if spellIdentifier and spellIdentifier ~= "" then
					-- Support both spell name and spellID
					local spellID = tonumber(spellIdentifier)
					if spellID then
						-- It's a spellID
						local spellName = SpellInfo(spellID)
						if spellName then
							simpleAuras.reactiveDurations[spellName] = duration
							sA:Msg("Set reactive duration of '" .. spellName .. "' (ID:" .. spellID .. ") to " .. duration .. " seconds.")
						else
							sA:Msg("SpellID " .. spellID .. " not found!")
						end
					else
						-- It's a spell name
						simpleAuras.reactiveDurations[spellIdentifier] = duration
						sA:Msg("Set reactive duration of '" .. spellIdentifier .. "' to " .. duration .. " seconds.")
					end
				else
					sA:Msg("Invalid spell name/ID!")
				end
			else
				sA:Msg("Invalid duration!")
			end
		else
			sA:Msg("Usage: /sa reactduration SpellName Duration - manually set reactive spell duration.")
			sA:Msg("Usage: /sa reactduration SpellID Duration - or use spell ID instead.")
			sA:Msg("Example: /sa reactduration Riposte 5")
			sA:Msg("Example: /sa reactduration Surprise Attack 6")
			sA:Msg("Example: /sa reactduration 52531 6")
		end
		return
	end
	
	-- delete
	if cmd == "forget" or cmd == "unlearn" or cmd == "delete" then
		-- Check if forgetting reactive spell
		if val == "react" or val == "reactive" then
			if fad == "all" then
				simpleAuras.reactiveDurations = {}
				sA:Msg("Forgot all learned Reactive spell durations.")
			elseif fad and fad ~= "" then
				if simpleAuras.reactiveDurations[fad] then
					simpleAuras.reactiveDurations[fad] = nil
					sA:Msg("Forgot reactive duration for '" .. fad .. "'.")
				else
					sA:Msg("No learned duration for reactive spell '" .. fad .. "'.")
				end
			else
				sA:Msg("Usage: /sa forget react SpellName - forget reactive spell duration.")
				sA:Msg("Usage: /sa forget react all - forget all reactive durations.")
			end
			return
		end
		
		-- SuperWoW aura durations
		if sA.SuperWoW then
			local arg = val
			if val and val == "all" then
				simpleAuras.auradurations = {}
				sA:Msg("Forgot all learned AuraDurations.")
			elseif val then
				local val = tonumber(val)
				if simpleAuras.auradurations[val] and type(simpleAuras.auradurations[val]) == "table" then
					simpleAuras.auradurations[val] = nil
					sA:Msg("Forgot learned AuraDuration for " .. SpellInfo(val) .. " (ID:"..val..").")
				else
					sA:Msg("No learned AuraDuration for SpellID " .. val.. ".")
				end
				
				-- local _, playerGUID = UnitExists("player")
				-- playerGUID = gsub(playerGUID, "^0x", "")
				-- for spellID, units in pairs(simpleAuras.auradurations) do
					-- if type(units) == "table" and units[playerGUID] then
						-- units[playerGUID] = nil
						-- if next(units) == nil then
							-- simpleAuras.auradurations[spellID] = nil
						-- end
					-- elseif type(units) ~= "table" and simpleAuras.auradurations[spellID] then
						-- simpleAuras.auradurations[spellID] = nil
					-- end
				-- end
				-- sA:Msg("All learned AuraDurations casted by unitGUID "..unitGUID.." deleted.")
			else
				sA:Msg("Usage: /sa forget X - forget AuraDuration of SpellID X (or use 'all' instead to delete all durations).")
			end
		else
			sA:Msg("/sa forget needs SuperWoW to be installed!")
		end
		return
	end
	

	-- help or unknown command fallback
	sA:Msg("Usage:")
	sA:Msg("/sa or /sa show or /sa hide - show/hide simpleAuras Settings.")
	sA:Msg("/sa refresh X - set aura data scan rate. (1 to 10 scans per second. Default: 5). GUI renders at fixed 20 FPS.")
	sA:Msg(" ")
	sA:Msg("Reactive Spells (Riposte, Overpower, etc):")
	sA:Msg("/sa reactduration SpellName Duration - manually set reactive spell duration.")
	sA:Msg("/sa forget react SpellName - forget reactive spell duration (or 'all' to delete all).")
	sA:Msg("/sa showlearning 1 - shows learning of reactive spell durations in chat.")
	sA:Msg(" ")
	if sA.SuperWoW then
		sA:Msg("SuperWoW commands:")
		sA:Msg("/sa learn X Y - manually set duration Y of spellID X.")
		sA:Msg("/sa forget X - forget AuraDuration of SpellID X (or use 'all' instead to delete all durations).")
		sA:Msg("/sa update X - force AuraDurations updates (1 = re-learn aura durations. Default: 0).")
		sA:Msg("/sa showlearning X - shows learning of new AuraDurations in chat (1 = show. Default: 0).")
		sA:Msg("/sa learnall X - learn all AuraDurations, even if no Aura is set up. (1 = Active. Default: 0).")
	end

end


