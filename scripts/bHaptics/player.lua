--[[ OpenMW bHaptics v0.1.5-alpha
player.lua
Date: 10/10/25
Author: Dteyn
URL: https://github.com/Dteyn/OpenMW-bHaptics
Description: Provides haptic feedback for player events
Target: OpenMW/OpenMW-VR 0.49.0 - Lua API v76
--]]

-- Requirements
local ambient = require('openmw.ambient')
local core    = require('openmw.core')
local nearby  = require('openmw.nearby')
local selfObj = require('openmw.self')
local time    = require('openmw_aux.time')
local types   = require('openmw.types')
local iface   = require('openmw.interfaces')
local relay   = require('scripts/bhaptics/relay')
local common  = require('scripts/bhaptics/common')

-- Options
local LOW_HP, CRIT_HP           = 0.20, 0.10    -- 20% and 10% health thresholds for heartbeat effect
local MAX_HEARTBEATS            = 20            -- maximum number of heartbeats on low health, will reset when above LOW_HP
local SOUND_LOGGER              = false         -- true = log player sounds, for finding haptic triggers for sound -> event mappings
local LOG_NEW_ONLY              = false         -- for SoundLogger. true = log only new sounds as they are played. false = log every event
local DEBUG                     = true          -- true = debug script logging

-- Poll intervals - set to 0 to disable
local ACTOR_POLL_INTERVAL       = 0.10          -- seconds between actor sound polls
local PLAYER_POLL_INTERVAL      = 0.10          -- seconds between player sound polls
local AMBIENT_POLL_INTERVAL     = 0.10          -- seconds between ambient sound polls
local LEVITATION_POLL_INTERVAL  = 0.10          -- seconds between levitation polls
local INVENTORY_POLL_INTERVAL   = 0.10          -- seconds between inventory polls
local CONTAINER_POLL_INTERVAL   = 0.10          -- seconds between container polls
-- NOTE: Inventory poll begins skipping ticks at high inventory counts:
-- +250 items  - skip 1 ticks
-- +1000 items - skip 3 ticks
-- +2000 items - skip 7 ticks

-- State tracking - Script States
local hapticsEnabled = true         -- keep track of haptics enabled/disabled
local timersStarted = false         -- keep track of timers
local skillHandlerAdded = false     -- track when skill handler has been added to prevent duping

-- State tracking - Player States
local beatCount                     -- keep track of number of heartbeats sent
local heartTimer                    -- timer for heartbeats
local isLevitating = false          -- keep track of when player is levitating script-wide
local invPollSkip = 0               -- skip tracking for higher inventory counts
local lastInvCount                  -- keep track of last inventory count for inventory haptics
local prevLevitating = false        -- keep track of previous levitation state
local prevHealth                    -- keep track of player's health
local prevOnGround                  -- keep track of state on ground
local prevSwimming                  -- keep track of swimming state
local prevWeatherHaptics            -- keep track of playing weather haptics

-- State tracking - Player Sounds
local trackedSounds = {}            -- store table of sounds to track for player
local trackedMap = {}               -- store tracked map of sounds for player
local soundsPlaying = {}            -- keep track of sounds playing on player
local soundsLogged = {}             -- keep track of sounds logged on player (when using SoundLogger)

-- State tracking - Actor Sounds
-- Used for haptics when player contacts another actor with melee
-- fxMeleeHit() is used as the effect
local actorHitSoundIDs = { 'hand to hand hit', 'health damage' }  -- trigger on these sounds
local actorHitPlaying = { false, false }  -- track if either sound is playing separately
local distanceThreshold = 75  -- actors further than this will not be checked for sounds playing

-- State tracking - Thunder Sounds
local thunderIDs = { 'thunder0', 'thunder1', 'thunder2', 'thunder3' }  -- ambient sound IDs to trigger thunder effect on
local thunderPlaying = { false, false, false, false } -- state tracking for each thunder sound ID

-- State tracking - Lockpick Sounds
local lockpickSoundIDs   = { "open lock", "open lock fail" }
local lockpickPlaying    = { false, false }   -- track if either sound is playing
local containerDistance  = 225                -- max distance to check (within reach)

-- Cached API lookups
local Actor   = types.Actor
local activeEffects    = Actor.activeEffects
local statsHealth      = Actor.stats.dynamic.health
local isOnGround       = Actor.isOnGround
local isSwimming       = Actor.isSwimming
local soundRecords     = core.sound.records
local isSoundPlaying   = core.sound.isSoundPlaying
local runRepeatedly    = time.runRepeatedly

--------------------------
-- Main Haptic Triggers --
--------------------------
local function fxHeartbeat()            relay.play('heartbeat') end
local function fxDamageHit()            relay.play('damage_hit') end
local function fxDamageDeath()          relay.play('damage_death') end
local function fxMeleeHit()             relay.play('attack_slash_rh')  end
local function fxHeal()                 relay.play('player_heal') end
local function fxDrink()                relay.play('player_drink') end
local function fxEat()                  relay.play('player_eat') end
local function fxJump()                 relay.play('player_jump') end
local function fxDoorTransition()       relay.play('player_transition_door') end
local function fxThunder()              relay.play('weather_thunder') end
local function fxSkillUpgrade()         relay.play('player_skill_up') end
local function fxPlayerLevelUp()        relay.play('player_level_up') end
local function fxStoreInventory()       relay.play("player_store_center") end
local function fxLockpickSuccess()      relay.play("player_lockpick_success") end
local function fxLockpickFail()         relay.play("player_lockpick_fail") end

-- Effects that use playLoop:
local function fxLevitate()
  -- parameters: (eventId, intensity, duration, angleX, offsetY, interval, maxCount)
  relay.playLoop('player_levitate', 0.5, 1.0, 0.0, 0.0, 0.0, 99999)
end

-----------------------------
--- Sound Haptic Triggers ---
-----------------------------
-- This table maps game sound IDs to haptic events which are sent to bHaptics Player.
-- pollPlayerSounds() uses this and when sounds are detected as playing,
-- a play command is sent to relay.lua which in turn writes haptic events to openmw.log

local SOUND_TO_HAPTIC = {
  -- Example: ["sound id name"]   = function() relay.play("event_id") end,
  -- Where: "sound id name" is the Morrowind sound name, and "event_id" is the corresponding bHaptics event

  -- player
  -- 'defaultland' plays when player lands after a jump or fall
  ["defaultland"]                 = function() relay.play("player_land") end,
  -- 'hand to hand hit' plays when the player is hit with stamina remaining
  ["hand to hand hit"]            = function() relay.play("damage_hit") end,
  -- 'health damage' plays when hit with no stamina and health decreases
  ["health damage"]               = function() relay.play("damage_pierce") end,

  -- walking
  ["footbareleft"]                = function() relay.play("player_walk_lh") end,
  ["footbareright"]               = function() relay.play("player_walk_rh") end,
  ["footheavyleft"]               = function() relay.play("player_walk_lh") end,
  ["footheavyright"]              = function() relay.play("player_walk_rh") end,
  ["footlightleft"]               = function() relay.play("player_walk_lh") end,
  ["footlightright"]              = function() relay.play("player_walk_rh") end,
  ["footmedleft"]                 = function() relay.play("player_walk_lh") end,
  ["footmedright"]                = function() relay.play("player_walk_rh") end,
  ["footwaterleft"]               = function() relay.play("player_walk_lh") end,
  ["footwaterright"]              = function() relay.play("player_walk_rh") end,

  -- swimming
  ["swim left"]                   = function() relay.play("player_swim_lh") end,
  ["swim right"]                  = function() relay.play("player_swim_rh") end,

  -- weapons
  ["bowpull"]                     = function() relay.play("weapon_bow_pull") end,
  ["bowshoot"]                    = function() relay.play("weapon_bow_shoot") end,
  ["crossbowpull"]                = function() relay.play("weapon_crossbow_pull") end,
  ["crossbowshoot"]               = function() relay.play("weapon_crossbow_shoot") end,
  -- ["weapon swish"]             = function() relay.play("weapon_swish") end,

  -- raising and lowering weapons
  -- TODO: use different effects for different weapons. Using same for now
  ["item weapon blunt down"]      = function() relay.play("weapon_down") end,
  ["item weapon blunt up"]        = function() relay.play("weapon_up") end,
  ["item weapon bow down"]        = function() relay.play("weapon_down") end,
  ["item weapon bow up"]          = function() relay.play("weapon_up") end,
  ["item weapon crossbow down"]   = function() relay.play("weapon_down") end,
  ["item weapon crossbow up"]     = function() relay.play("weapon_up") end,
  ["item weapon longblade down"]  = function() relay.play("weapon_down") end,
  ["item weapon longblade up"]    = function() relay.play("weapon_up") end,
  ["item weapon shortblade down"] = function() relay.play("weapon_down") end,
  ["item weapon shortblade up"]   = function() relay.play("weapon_up") end,
  ["item weapon spear down"]      = function() relay.play("weapon_down") end,
  ["item weapon spear up"]        = function() relay.play("weapon_up") end,

  -- armor and clothes
  ["item clothes up"]             = function() relay.play("player_wear_clothes") end,
  ["item armor light up"]         = function() relay.play("player_wear_armor_light") end,
  ["item armor medium up"]        = function() relay.play("player_wear_armor_medium") end,
  ["item armor heavy up"]         = function() relay.play("player_wear_armor_heavy") end,

  -- magic cast success
  -- TODO: use different effects for different magic. Using same effects for now.
  -- TODO: differentiate between LH and RH effects when in VR
  ["alteration cast"]             = function() relay.play("player_magic_cast") end,
  ["conjuration cast"]            = function() relay.play("player_magic_cast") end,
  ["destruction cast"]            = function() relay.play("player_magic_cast") end,
  ["frost_cast"]                  = function() relay.play("player_magic_cast") end,
  ["illusion cast"]               = function() relay.play("player_magic_cast") end,
  ["mysticism cast"]              = function() relay.play("player_magic_cast") end,
  ["restoration cast"]            = function() relay.play("player_magic_cast") end,
  ["shock cast"]                  = function() relay.play("player_magic_cast") end,

  -- magic cast failure
  ["spell failure alteration"]    = function() relay.play("player_magic_fail") end,
  ["spell failure conjuration"]   = function() relay.play("player_magic_fail") end,
  ["spell failure destruction"]   = function() relay.play("player_magic_fail") end,
  ["spell failure illusion"]      = function() relay.play("player_magic_fail") end,
  ["spell failure mysticism"]     = function() relay.play("player_magic_fail") end,
  ["spell failure restoration"]   = function() relay.play("player_magic_fail") end,

  -- magic hits on player
  -- TODO: use different effects for different magic. Using same effects for now.
  ["alteration hit"]              = function() relay.play("player_magic_hit") end,
  ["conjuration hit"]             = function() relay.play("player_magic_hit") end,
  ["destruction hit"]             = function() relay.play("player_magic_hit") end,
  ["frost_hit"]                   = function() relay.play("player_magic_hit") end,
  ["illusion hit"]                = function() relay.play("player_magic_hit") end,
  ["mysticism hit"]               = function() relay.play("player_magic_hit") end,
  ["restoration hit"]             = function() relay.play("player_magic_hit") end,
  ["shock hit"]                   = function() relay.play("player_magic_hit") end,
}

-------------------------------
--- Weather Haptic Triggers ---
-------------------------------
--[[
-- TODO: FIXES NEEDED FOR WEATHER HAPTICS:
    Weather haptics hook/triggers work, but effects are DISABLED for now until these are fixed:
     --- When entering an interior (building/cave etc) effect keeps playing. It needs to stop and then start again when exiting interior.
     --- When underwater, effect needs to stop when player is fully submerged, and start again when they emerge.
     --- When at menu, effect needs to stop and resume again when back in game.
     --- When exiting game, effect needs to stop (note: this will be handled at the bHapticsRelay app level)
--]]

-- Weather types
local WEATHER = {
    CLEAR    = 0,
    CLOUDY   = 1,
    FOGGY    = 2,
    OVERCAST = 3,
    RAIN     = 4,
    THUNDER  = 5,
    ASH      = 6,
    BLIGHT   = 7,
    SNOW     = 8,
    BLIZZARD = 9,
}

-- Map weather type to haptic events
local WEATHER_HAPTICS = {
    [WEATHER.RAIN]    = 'weather_rain',
    [WEATHER.THUNDER] = 'weather_rain_heavy',
    [WEATHER.ASH]     = 'weather_wind',         -- note: effect does not yet exist
    [WEATHER.BLIGHT]  = 'weather_blight',       -- note: effect does not yet exist
    [WEATHER.SNOW]    = 'weather_snow',         -- note: effect does not yet exist
    [WEATHER.BLIZZARD]= 'weather_blizzard',     -- note: effect does not yet exist
}

------------------------
--- Helper functions ---
------------------------
-- debugLog - all calls to this are gated behind 'if DEBUG' for best performance.
-- This is temporary and for use during development. I plan to remove all debug logging on release version.
local function debugLog(logMsg, ...)
  if not DEBUG then return end
  if select('#', ...) > 0 then
    print("[DEBUG] " .. string.format(logMsg, ...))  -- only use string formatting if needed
  else
    print("[DEBUG] " .. logMsg)
  end
end

-- SoundLogger - for logging details on sounds, used for finding new haptic triggers
local function soundLogger(rec)
    print(('[PLAYER SOUNDLOGGER] Sound played: %s'):format(rec.id))
end

local function buildSoundTable()
  trackedSounds = {}
  trackedMap    = {}
  for id, fn in pairs(SOUND_TO_HAPTIC) do
    trackedSounds[#trackedSounds+1] = { id = id, trigger = fn }
    trackedMap[id] = true
  end
end

local function refreshInventoryCount()
  local inv = Actor.inventory(selfObj.object):getAll()
  local count = 0
  for i = 1, #inv do count = count + inv[i].count end
  lastInvCount = count
end

local function forEachNearbyLockable(fn)
  local selfPos = selfObj.position

  -- Containers
  for _, container in ipairs(nearby.containers) do
    if (container.position - selfPos):length() <= 225 then  -- limit distance check to 225 units
      fn(container)
    end
  end

  -- Doors
  for _, door in ipairs(nearby.doors) do
    if (door.position - selfPos):length() <= 225 then   -- limit distance check to 225 units
      fn(door)
    end
  end
end

--------------------------------------
--- Skill Progression and level up ---
--------------------------------------
-- Add a handler for skill level up and emit a haptic event when player ups their skills
-- TODO: Could add unique haptics based on skillId
local function addSkillHandler()
  if skillHandlerAdded then return end
  if DEBUG then debugLog("Adding SkillLevelUpHandler") end
  iface.SkillProgression.addSkillLevelUpHandler(function(skillId, source)
    if DEBUG then debugLog("Leveled up skill: %s -- Source: %s", tostring(skillId), tostring(source)) end
    fxSkillUpgrade()
  end)
  skillHandlerAdded = true
end

-----------------------------
--- Ambient Sound Polling ---
-----------------------------
-- Looks for any thunder ambient sound IDs currently playing and emits haptics when a crack of thunder happens
-- Runs via: onInit -> runRepeatedly via timer (AMBIENT_POLL_INTERVAL)
-- TODO: Add check for player under water and dampen thunder effect by 90% if in water
local function pollAmbientSounds()
  if not hapticsEnabled then return end

  for i = 1, 4 do
    local id = thunderIDs[i]
    local isPlaying = ambient.isSoundPlaying(id)
    if isPlaying and not thunderPlaying[i] then
      -- TODO: Add separate effects for each thunder sound. There are only 4 total
      fxThunder()
    end
    thunderPlaying[i] = isPlaying
  end
end

-----------------------------------------------
--- Sound Polling for Sound Haptic Triggers ---
-----------------------------------------------
-- Checks for currently playing sounds and triggers haptic events accordingly
-- Runs via: onInit -> runRepeatedly via timer (PLAYER_POLL_INTERVAL)
local function pollPlayerSounds()
  if not hapticsEnabled then return end

  for _, rec in ipairs(trackedSounds) do
    local id, trigger   = rec.id, rec.trigger
    local playing  = isSoundPlaying(id, selfObj)

    -- Trigger haptics if there is a matching mapped ID
    if playing and not soundsPlaying[id] then
      if DEBUG then debugLog("Triggering haptic for sound '%s'", id) end
      trigger()
    end

    -- If SoundLogger is enabled, log sound id played (used to find new haptic triggers)
    if SOUND_LOGGER and playing and not soundsPlaying[id] then
      if LOG_NEW_ONLY then  -- If LOG_NEW_ONLY is set, ONLY log the first time a sound plays
        if not soundsLogged[id] then
          soundLogger(rec)
          soundsLogged[id] = true
        end
      else  -- If LOG_NEW_ONLY is false, log EVERY time a sound plays
        soundLogger(rec)
      end
    end

    -- Keep track of sounds playing
    soundsPlaying[id] = playing
  end
end

----------------------------------
--- Melee hits on other actors ---
----------------------------------
-- Checks for currently playing sounds on actors and triggers haptics accordingly
-- Used for: triggering melee haptics when player strikes another actor
-- Runs via: onInit -> runRepeatedly via timer (ACTOR_POLL_INTERVAL)

--- NOTE: In API v96+ we will be able to use interface 'Combat' to send messages from actor scripts on NPC / CREATURE
--- Example, pointed out by blurpanda: https://github.com/erinpentecost/ErnOneStick/blob/main/scripts/ErnOneStick/actor.lua
--- Since we are targeting API v76 for OpenMW-VR 0.49.0, we'll use sounds as triggers for now
-- TODO: This fires when an arrow lands a hit but should be melee only. Will fix when API v96+ is available in OpenMW-VR

local function pollActorSounds()
  if not hapticsEnabled then return end

  for i, soundId in ipairs(actorHitSoundIDs) do
    local found = false
    local selfPos = selfObj.position  -- get player position
    for _, actor in ipairs(nearby.actors) do
      if actor ~= selfObj.object then
        if (actor.position - selfPos):length() < distanceThreshold then
          if core.sound.isSoundPlaying(soundId, actor) then
            found = true
            break
          end
        end
      end
    end
    if found and not actorHitPlaying[i] then
      if DEBUG then debugLog("[pollActorSounds NEW] Triggered for '%s'", soundId) end
      fxMeleeHit()
    end
    actorHitPlaying[i] = found
  end
end

-------------------------
--- Container haptics ---
-------------------------
-- Play haptics when player picks a lock (fail and success)
-- Runs via: onInit -> runRepeatedly via timer (CONTAINER_POLL_INTERVAL)
-- Checks containers and doors within 'containerDistance' if 'open lock' or 'open lock fail' is playing
-- If so, trigger haptics for lockpick success or fail accordingly

local function pollContainerSounds()
  if not hapticsEnabled then return end

  for i, soundId in ipairs(lockpickSoundIDs) do
    local found   = false
    local selfPos = selfObj.position

    -- Containers near player
    for _, container in ipairs(nearby.containers) do
      if (container.position - selfPos):length() < containerDistance then
        if isSoundPlaying(soundId, container) then
          found = true
          break
        end
      end
    end

    -- Doors near player
    if not found then
      for _, door in ipairs(nearby.doors) do
        if (door.position - selfPos):length() < containerDistance then
          if isSoundPlaying(soundId, door) then
            found = true
            break
          end
        end
      end
    end

    -- Trigger haptics
    if found and not lockpickPlaying[i] then
      if DEBUG then debugLog("[pollContainerSounds] Triggering haptics for '%s'", soundId) end
      if soundId == "open lock" then
        fxLockpickSuccess()
      else
        fxLockpickFail()
      end
    end

    -- Update edge state
    lockpickPlaying[i] = found
  end
end

--------------------------
--- Levitation haptics ---
--------------------------
-- Checks if player is currently levitating and triggers haptics while player has the effect active
-- Runs via: onInit -> runRepeatedly via timer (LEVITATION_POLL_INTERVAL)
local function pollLevitate()
  if not hapticsEnabled then return end

  local nowLevitating = false  -- keep track internally
  for _, effect in pairs(activeEffects(selfObj)) do
    if effect.id == "levitate" then nowLevitating = true; break end
  end

  if nowLevitating and not prevLevitating then
    if DEBUG then debugLog("Player started levitating.") end
    fxLevitate()
  elseif not nowLevitating and prevLevitating then
    if DEBUG then debugLog("Player stopped levitating.") end
    relay.stopByEventId("player_levitate")
  end

  isLevitating = nowLevitating  -- set isLevitating so jump effect in onUpdate isn't played when levitating
  prevLevitating = nowLevitating
end

-------------------------
--- Inventory haptics ---
-------------------------
-- Play haptics when player picks up or is given an item
-- This gets expensive for large amounts of inventory, so we skip ticks depending on inventory count
-- Runs via: onInit -> runRepeatedly via timer (INVENTORY_POLL_INTERVAL)
local function pollInventory()
  if not hapticsEnabled then return end

  -- Skip this tick if we’re still in a "back-off" period
  if invPollSkip > 0 then
    invPollSkip = invPollSkip - 1
    return
  end

  -- Get player inventory count
  local inv = Actor.inventory(selfObj.object):getAll()
  local count = 0
  for i = 1, #inv do
    count = count + (inv[i].count or 1)
  end

  -- Trigger haptics when the inventory amount increases
  if count > lastInvCount then
    if DEBUG then debugLog("Inventory pickup: %d -> %d (+%d)", lastInvCount, count, count - lastInvCount) end
    fxStoreInventory()
  end
  lastInvCount = count

  -- Skip frames to save ops when player has large inventory counts
  -- Base timer is 0.05s (50ms)
  local tier
  if count <= 250  then      -- every tick = every 120ms if under 250 items
    tier = 1
  elseif count <= 1000 then  -- 1 in 2 ticks = every 100ms if under 1000 items
    tier = 2
  elseif count <= 2000 then  -- i in 4 ticks = every 200ms if under 2000 items
    tier = 4
  else                       -- 1 in 8 ticks = every 400ms if over 2000 items
    tier = 8
  end
  invPollSkip = tier - 1
end


--------------------------------
---  Consume driven haptics  ---
--------------------------------
--[[ engineHandler: onConsume --
--------------------------------
Called on an actor when they consume an item (e.g. a potion).
Similarly to onActivated, the item has already been removed
from the actor’s inventory, and the count was set to zero.
--]]

local function onConsume(item)
  -- item.type will stringify as "Potion", "Ingredient", etc.
  local itemType = tostring(item.type)
  if itemType == 'Potion' then
    if DEBUG then debugLog("onConsume handler: used potion, playing drink effect") end
    fxDrink()
  elseif itemType == 'Ingredient' then
    if DEBUG then debugLog('onConsume handler: ate ingredient, playing eat effect') end
    fxEat()
  end
end

-----------------------------------
---   Teleport / transitions    ---
-----------------------------------
--[[ engineHandler: onTeleported --
-----------------------------------
Object was teleported. This is triggered for doors, teleports and fast travel (silt striders, etc).
--]]
local function onTeleported()
  if DEBUG then debugLog('onTeleported handler: door loads / portals / fast travel (all same haptics for now)') end
  -- TODO: Add detection for teleport/portals and fast travel so they can have different effects
  fxDoorTransition()
end

---------------------------------------
---         Weather haptics         ---
---------------------------------------
--[[ eventHandler: BH_WeatherChanged --
---------------------------------------
This triggers haptics for events such as a rain, wind, blight, snow, and blizzard.

NOTE: This depends on events coming from global.lua, which requires
OpenMW lua helper utility by taitechnic: https://www.nexusmods.com/morrowind/mods/54629
Thanks taitechnic!

-- TODO: FIXES NEEDED FOR WEATHER HAPTICS:
    This works, but effects are DISABLED for now until these are fixed:
     --- When entering an interior (building/cave etc) effect keeps playing. It needs to stop and then start again when exiting interior.
     --- When underwater, effect needs to stop when player is fully submerged, and start again when they emerge.
     --- When at menu, effect needs to stop and resume again when back in game.
     --- When exiting game, effect needs to stop (note: this will be handled at the bHapticsRelay app level)
--]]

local function onWeatherChanged(weatherData)
    -- data: { id, name, prevId, prevName, tag }
    if DEBUG then
        debugLog(
          "Weather event received from global.lua: %s (%d) <- %s (%d)",
          weatherData.name or '?',
          weatherData.id or -1,
          weatherData.prevName or '?',
          weatherData.prevId or -1
        )
    end

    -- Stop weather haptics from previous weather event if playing
    if prevWeatherHaptics then
        -- relay.stopByEventId(prevWeatherHaptics)
    end

    local newWeatherHaptics = WEATHER_HAPTICS[weatherData.id]
    if newWeatherHaptics then
        prevWeatherHaptics = newWeatherHaptics
        if DEBUG then debugLog("Weather changed. [EFFECT DISABLED, left for reference] playLoop command: '%s'", newWeatherHaptics) end
        -- parameters: (eventId, intensity, duration, angleX, offsetY, interval, maxCount)
        -- relay.playLoop(newWeatherHaptics,1.0,1.0,0.0,0.0,0,99999)
    end
end

----------------------
--- Initialization ---
----------------------
local function initState()
  local health = statsHealth(selfObj)
  prevHealth   = health.current
  prevOnGround = isOnGround(selfObj)
  prevSwimming = isSwimming(selfObj)
  heartTimer   = 0
  beatCount    = 0
  relay.setEnabled(true)
  relay.stopAll()  -- stop any effects that may be playing
  if DEBUG then debugLog("Initialized bHaptics.") end
end

local function startPollers()
  if timersStarted then return end

  local pollers = {
    { func = pollPlayerSounds, interval = PLAYER_POLL_INTERVAL },
    { func = pollActorSounds, interval = ACTOR_POLL_INTERVAL },
    { func = pollAmbientSounds, interval = AMBIENT_POLL_INTERVAL},
    { func = pollLevitate, interval = LEVITATION_POLL_INTERVAL},
    { func = pollInventory, interval = INVENTORY_POLL_INTERVAL},
    { func = pollContainerSounds, interval = CONTAINER_POLL_INTERVAL},
  }

  local anyEnabled = false
  for _, poller in ipairs(pollers) do
    if poller.interval > 0 then
      anyEnabled = true
      runRepeatedly(poller.func, poller.interval, { initialDelay = poller.interval })
    end
  end

  if DEBUG then
    if anyEnabled then
      debugLog("Timers started.")
    else
      debugLog("Timers skipped (all poll intervals at 0).")
    end
  end

  timersStarted = true

end

-----------------------------
--[[ engineHandler: onInit --
-----------------------------
(per docs): Called once when the script is created (not loaded).
--]]

local function onInit()
  -- Initialize state
  initState()

  -- Build table of tracked sounds
  buildSoundTable()

  -- Add skill handler
  addSkillHandler()

  -- Refresh inventory count
  refreshInventoryCount()

  -- Start pollers
  startPollers()

end

-----------------------------
--[[ engineHandler: onLoad --
-----------------------------
(per docs): Called on loading with the data previously returned by
onSave. During loading the object is always inactive. initData is
the same as in onInit.
Note that onLoad means loading a script rather than loading a game.
If a script did not exist when a game was saved onLoad will not be
called, but onInit will.
--]]

local function onLoad()
  -- Enable haptics
  relay.setEnabled(true)
  hapticsEnabled = true
  relay.stopAll()  -- stop any effects that may be playing

  -- Add skill handler
  addSkillHandler()

  -- Refresh inventory count on load
  refreshInventoryCount()

  -- Start pollers
  startPollers()
end

-------------------------------
--[[ engineHandler: onUpdate --
-------------------------------
Called every frame if the game is not paused. dt is
the simulation time from the last update in seconds.
--]]

local function onUpdate(dt)
  if heartTimer == nil or prevHealth == nil then
    initState()
  end

  -- Update health and percentage
  local health = statsHealth(selfObj)
  local cur    = health.current
  local pct    = (health.base > 0) and (cur / health.base) or 1.0

  --- Player death detection
  if cur <= 0 and prevHealth > 0 then
    if DEBUG then debugLog("Player DIED (health <= 0). Playing death effect, then disabling haptics.") end
    -- NOTE: We do this here instead of the Died eventHandler, this is quicker with no delay
    relay.stopAll()           -- stop any other playing effects
    fxDamageDeath()           -- play the death effect with a dying heartbeat
    relay.setEnabled(false)   -- disable haptics to prevent any further events from firing, because we're dead lol
    hapticsEnabled = false
  else
    --- Heartbeat feedback (low health only):
    -- LOW_HP and CRIT_HP are health‐percentage thresholds: defaults are 20% and 10% respectively.
    -- When health % falls to LOW_HP (20%) or below, we begin heartbeat feedback (one pulse every 1.5 s by default).
    -- If pct falls all the way to CRIT_HP (10%) or below, we speed up the pulse to once every 1.0 s.
    -- After MAX_HEARTBEATS (default 20), we stop so we don't annoy the player with too much haptic spam.
    -- Once health climbs back above LOW_HP, we reset the beat counter for next time health drops below LOW_HP.
    heartTimer = heartTimer + dt
    if pct <= LOW_HP then
      local interval = (pct <= CRIT_HP) and 1.0 or 1.5
      if beatCount < MAX_HEARTBEATS and heartTimer >= interval then
        heartTimer = 0
        beatCount = beatCount + 1
        fxHeartbeat()
      end
    end

    -- Reset heartbeat counter once health is above LOW_HP threshold
    if pct > LOW_HP then
      beatCount = 0
    end

    --- Damage / heal detection
    local diff = cur - prevHealth
    if diff > 1 then
      if DEBUG then debugLog("Player health increased, using heal effect") end
      fxHeal()
    elseif diff < -1 then
      -- TODO: Add fall detection and use a different effect when player falls down
      if DEBUG then debugLog("Player health decreased.") end
      -- fxDamageHit()  -- disabled here, using 'health damage' sound trigger instead
    end
  end

  --- Track health for next frame
  prevHealth = cur


  --- Jumping
  -- Do not play jump effect if levitation is active
  local onGround = isOnGround(selfObj)
  if prevOnGround ~= nil and prevOnGround and not onGround and not isLevitating then
    -- Player just left the ground = jumping
    if DEBUG then debugLog("Jump detected") end
    fxJump()
  end
  prevOnGround = onGround

  --- Water effect
  -- NOTE: Swimming effects are handled separately by sound events
  --[[ --TODO: DISABLED for now, may remove this as effect would be too spammy unless extremely subtle. left here for now
  local swim = isSwimming(selfObj)
  if swim ~= prevSwimming then
    if swim then
      -- TODO: Add a state for inWater and stop rain,etc effects if in water, could dampen thunder
      if DEBUG then debugLog("Entered water - playing in water effect") end
      fxWater()  -- use playLoop to keep effect going while in water
    else
      if DEBUG then debugLog("Exited water - stopping in water effect") end
      relay.stopByEventId('player_in_water')  -- stop effect when player is no longer swimming
    end
    prevSwimming = swim
  end
  --]]

end --onUpdate

--- Return

return {
  engineHandlers = {
    onLoad       = onLoad,
    onInit       = onInit,
    onUpdate     = onUpdate,
    onTeleported = onTeleported,
    onConsume    = onConsume,
  },
  eventHandlers = {
    -- When player levels up, play level up haptics
    UiModeChanged = function(data)
        if data.newMode == iface.UI.MODE.LevelUp then
            if DEBUG then debugLog("eventHandler.UiModeChanged: Level up UI is on screen, playing level up haptics") end
            fxPlayerLevelUp()
        end
    end,

    -- When receiving weather change event from global.lua, trigger weather haptics
    BH_WeatherChanged = onWeatherChanged,
  },
}
