--[[ OpenMW bHaptics v0.1.5-alpha
menu.lua
Date: 10/10/25
Author: Dteyn
URL: https://github.com/Dteyn/OpenMW-bHaptics
Description: Sends a heartbeat on startup so users knows that bHaptics is working
Target: OpenMW/OpenMW-VR 0.49.0 - Lua API v76
--]]

local relay   = require('scripts/bhaptics/relay')
local common  = require('scripts/bhaptics/common')

local gameStarted = false

local function onInit()
    -- Send heartbeat on game startup
    if not gameStarted then
        relay.setEnabled(true)
        print("Game started. Sending heartbeat: [bHaptics]play,heartbeat")
        relay.setEnabled(false)
    end
    gameStarted = true
end

return {
    engineHandlers = {
        onInit = onInit
    }
}
