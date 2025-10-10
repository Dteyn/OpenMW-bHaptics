--[[ OpenMW bHaptics v0.1.5-alpha
global.lua
Date: 10/10/25
Author: Dteyn
URL: https://github.com/Dteyn/OpenMW-bHaptics
Description: Sends weather changes to player.lua
Target: OpenMW/OpenMW-VR 0.49.0 - Lua API v76
--]]

local DEBUG = true

local world = require('openmw.world')
local core  = require('openmw.core')
local time  = require('openmw_aux.time')
local common  = require('scripts/bhaptics/common')

--------------------------------------------------------
--- Requires OpenMW lua helper utility by taitechnic ---
--- https://www.nexusmods.com/morrowind/mods/54629   ---
--------------------------------------------------------
if not core.contentFiles.has('OpenMW_luahelper.esp') then
    print('[ERROR] Missing OpenMW luahelper ESP – weather haptics disabled.')
    return {}
end

---------------
-- Constants --
---------------
local EVENT_WEATHER_CHANGED = 'BH_WeatherChanged'
local prevWeather = -1

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

----------------------
-- Helper functions --
----------------------
-- debugLog - all calls to this are gated behind 'if DEBUG' for best performance
-- TEMPORARY: will remove all debug logging on release version
local function debugLog(logMsg, ...)
  if select('#', ...) > 0 then
    print("[DEBUG] " .. string.format(logMsg, ...))  -- only use string formatting if needed
  else
    print("[DEBUG] " .. logMsg)
  end
end

local WEATHER_NAMES = {}
for name, id in pairs(WEATHER) do
    WEATHER_NAMES[id] = name
end

---------------------
-- Weather updates --
---------------------
local function checkWeather()
    local player = world.players[1]
    if not player then return end

    local vars      = world.mwscript.getGlobalVariables(player)
    local weatherId = vars and vars.omwWeather or -1

    if weatherId ~= prevWeather then
        local oldName = WEATHER_NAMES[prevWeather] or "?"
        local newName = WEATHER_NAMES[weatherId]  or "?"

        if DEBUG then debugLog("Weather changed %s (%d) -> %s (%d)", oldName, prevWeather, newName, weatherId) end

        -- Send event to player.lua
        player:sendEvent(EVENT_WEATHER_CHANGED, {
            prevId   = prevWeather,
            prevName = oldName,
            id       = weatherId,
            name     = newName,
        })

        prevWeather = weatherId
    end
end

local function onInit()
    -- Monitor for weather changes once per second
    time.runRepeatedly(checkWeather, time.second)
    checkWeather()
end

return {
    engineHandlers = {
        onInit = onInit,
    }
}
