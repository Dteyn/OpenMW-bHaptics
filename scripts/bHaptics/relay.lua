--[[ OpenMW bHaptics v0.1.5-alpha
relay.lua
Date: 10/10/25
Author: Dteyn
URL: https://github.com/Dteyn/OpenMW-bHaptics
Description: Interface for bHapticsRelay support for writing events to openmw.log
Target: OpenMW/OpenMW-VR 0.49.0 - Lua API v76

Author's notes:
---------------
  This script is a utility for sending commands to companion app bHapticsRelay.

  For more information on bHapticsRelay, see here:
  https://github.com/Dteyn/bHapticsRelay

  bHapticsRelay can monitor a text log file (in this case, openmw.log) and will
  trigger bHaptics events based on what it sees in the log file, which

  The commands are written to openmw.log in the following format:

        [bHaptics]<command>,<comma-separated-params>

Where <command> is one of:
  - play
  - playParam
  - playLoop
  - pause
  - resume
  - stop
  - stopByEventId
  - stopAll

(NOTE: bHapticsRelay supports more commands, but only the above are currently implemented in this script)

API Commands Available:

  relay.setEnabled()            -- Control whether haptics are enabled (true) or disabled (false).
  relay.isEnabled()             -- Returns true if haptics are enabled, false if disabled.
  relay.play()                  -- Play a pre-defined haptic pattern by event ID (string).
  relay.playParam()             -- Play a haptic pattern with custom parameters (intensity/duration/rotation/offset).
  relay.playLoop()              -- Play a looping haptic pattern. Loop timing and maximum count can be specified.
  relay.pause()                 -- Pause a specific haptic playback by event ID (string).
  relay.resume()                -- Resume a specific haptic playback by event ID (string).
  relay.stop()                  -- Pause a specific haptic playback by request ID (numeric).
  relay.stopByEventId()         -- Stop a specific haptic playback by event ID (string).
  relay.stopAll()               -- Stop all currently playing haptic events.
  relay.isPlaying()             -- Returns true if any event Id is currently playing.
  relay.isPlayingByRequestId()  -- Returns true if a specific event Id is currently playing, by request Id (numeric).
  relay.isPlayingByEventId()    -- Returns true if a specific event Id is currently playing, by event name (string).
  relay.resetTracking()         -- Wipe internal tracking of event and request Ids.

Example Usage:
  local relay = require('scripts/bhaptics/relay')
  relay.setEnabled(true)
  local playReqId = bHaptics.play('heartbeat')
  relay.pause('heartbeat')
  relay.resume('heartbeat')
  relay.stop(playReqId)
  relay.stopByEventId('heartbeat')
  relay.stopAll()
  relay.setEnabled(false)

Further Notes:
  When .setEnabled is false, relay will not write any commands to openmw.log and instead will
  log a message with the command that was issued, noting that haptics are disabled.

  Events playing are tracked and can be paused/resumed/stopped by event Id. The script also
  has helpers to report if an event is playing, it's worth noting that these particular commands
  are handled internally to the script whereas in bHapticsRelay, they are also supported commands
  that can be sent to the bHaptics Player app.

  In this use case, since OpenMW Lua scripting cannot read input from files (unless I'm mistaken),
  we operate in 'one way' communication mode where the OpenMW Lua scripts are able to issue commands,
  but not receive replies back from bHapticsRelay.

  bHapticsRelay does support two-way communication with bHaptics Player in Websocket mode, but
  in this case we are only using the Log Tailing mode for the one-way communication that OpenMW Lua
  is able to provide.
--]]

local common = require('scripts/bhaptics/common')

local relay = {}

--------------------
-- State Tracking --
--------------------

-- Master switch (true = haptics enabled, false = ignore all commands)
local hapticsEnabled = false

-- Counter for generating new request IDs. Starts at 1000
local nextRequestId = 1000

-- Request lookup: [requestId] = { eventId=string, status="playing"/"paused", hasRequestId=true }
local requestsById = {}

-- Event lookup: [eventId] = { anyPlaying=boolean, requestIds={ [reqId]=true, ... } }
-- Tracks whether any playback is active and which requests belong to it.
local eventsById = {}

----------------------
-- Helper Functions --
----------------------

-- Emit a command to bHapticsRelay via print(), which writes to openmw.log
-- bHapticsRelay looks for '[bHaptics]command,params' and sends to bHaptics Player accordingly
local function emit(command, args)
  local payload = command
  if args and #args > 0 then
    payload = payload .. "," .. table.concat(args, ",")
  end
  print("[bHaptics]" .. payload)
end

-- Generate a new requestId
local function generateRequestId()
  nextRequestId = nextRequestId + 1
  return nextRequestId
end

-- Normalize eventId (trim spaces and ensure nonempty string)
local function normalizeEventId(eventId)
  if type(eventId) ~= "string" then return nil end
  local trimmed = eventId:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return nil end
  return trimmed
end

-- Ensure a bucket exists for the given eventId
local function ensureEventBucket(eventId)
  local bucket = eventsById[eventId]
  if not bucket then
    bucket = { anyPlaying = false, requestIds = {} }
    eventsById[eventId] = bucket
  end
  return bucket
end

-- Recompute whether any request in this event bucket is still playing
local function recomputeAnyPlaying(eventId)
  local bucket = eventsById[eventId]
  if not bucket then return end
  bucket.anyPlaying = false
  for reqId in pairs(bucket.requestIds) do
    local rec = requestsById[reqId]
    if rec and rec.status == "playing" then
      bucket.anyPlaying = true
      return
    end
  end
end

-- Track a play() call that didn't supply a requestId
local function trackPlayEventOnly(eventId)
  local bucket = ensureEventBucket(eventId)
  bucket.anyPlaying = true
end

-- Track a playParam/playLoop call with requestId
local function trackRequest(reqId, eventId)
  requestsById[reqId] = { eventId = eventId, status = "playing", hasRequestId = true }
  local bucket = ensureEventBucket(eventId)
  bucket.requestIds[reqId] = true
  bucket.anyPlaying = true
end

-- Update all requests for an event to a given status (playing/paused).
local function setStatusByEvent(eventId, status)
  local bucket = eventsById[eventId]
  if not bucket then return end
  for reqId in pairs(bucket.requestIds) do
    local rec = requestsById[reqId]
    if rec then rec.status = status end
  end
  if status == "playing" then
    bucket.anyPlaying = true
  elseif status == "paused" then
    recomputeAnyPlaying(eventId)
  end
end

-- Clear a single requestId
local function clearRequest(reqId)
  local rec = requestsById[reqId]
  if not rec then return end
  local eventId = rec.eventId
  requestsById[reqId] = nil
  local bucket = eventsById[eventId]
  if bucket then
    bucket.requestIds[reqId] = nil
    if not next(bucket.requestIds) then
      bucket.anyPlaying = false
    else
      recomputeAnyPlaying(eventId)
    end
  end
end

-- Clear all requests belonging to an eventId
local function clearByEvent(eventId)
  local bucket = eventsById[eventId]
  if not bucket then return end
  for reqId in pairs(bucket.requestIds) do
    requestsById[reqId] = nil
  end
  eventsById[eventId] = { anyPlaying = false, requestIds = {} }
end

-- Clear all state (requests + events)
local function clearAll()
  requestsById = {}
  eventsById = {}
end

------------------------
-- Main API Functions --
------------------------

--- relay.play()
-- Plays a pre-defined haptic pattern by event ID.
-- Example output to openmw.log: [bHaptics]play,heartbeat
function relay.play(eventId)
  if not hapticsEnabled then
    print("[relay] Haptics disabled - ignoring play command.")
    return -1
  end
  local event = normalizeEventId(eventId)
  if not event then return -1 end
  emit("play", { event })
  trackPlayEventOnly(event)
  return -1 -- local id, not stoppable by stop(reqId)
end

--- relay.playParam()
-- Plays a haptic pattern with custom parameters (intensity/duration/rotation/offset)
-- Example output to openmw.log: [bHaptics]playParam,impact,1001,0.8,1.0,45,0.0
function relay.playParam(eventId, requestId, intensity, duration, angleX, offsetY)
  if not hapticsEnabled then
    print("[relay] Haptics disabled - ignoring playParam command.")
    return -1
  end
  local event = normalizeEventId(eventId)
  if not event then return -1 end
  local reqId = tonumber(requestId) or 0
  if reqId <= 0 then reqId = generateRequestId() end
  emit("playParam", {
    event,
    tostring(reqId),
    tostring(intensity or 1.0),
    tostring(duration or 1.0),
    tostring(angleX or 0.0),
    tostring(offsetY or 0.0),
  })
  trackRequest(reqId, event)
  return reqId
end

--- relay.playLoop()
-- Plays a looping haptic pattern. Loop timing and maximum count can be specified.
-- Example output to openmw.log: [bHaptics]playLoop,pulse,1.0,0.5,0,0,1000,5
function relay.playLoop(eventId, intensity, duration, angleX, offsetY, interval, maxCount)
  if not hapticsEnabled then
    print("[relay] Haptics disabled - ignoring playLoop command.")
    return -1
  end
  local event = normalizeEventId(eventId)
  if not event then return -1 end
  emit("playLoop", {
    event,
    tostring(intensity or 1.0),
    tostring(duration or 1.0),
    tostring(angleX or 0.0),
    tostring(offsetY or 0.0),
    tostring(interval or 0),
    tostring(maxCount or 0),
  })
end

--- relay.pause()
-- Pauses a specific haptic playback by event ID.
-- Example output to openmw.log: [bHaptics]pause,impact
function relay.pause(eventId)
  if not hapticsEnabled then
    print("[relay] Haptics disabled - ignoring pause command.")
    return -1
  end
  local event = normalizeEventId(eventId)
  if not event then return false end
  emit("pause", { event })
  setStatusByEvent(event, "paused")
  return true
end

--- relay.resume()
-- Resumes a specific haptic playback by event ID.
-- Example output to openmw.log: [bHaptics]resume,impact
function relay.resume(eventId)
  if not hapticsEnabled then
    print("[relay] Haptics disabled - ignoring resume command.")
    return -1
  end
  local event = normalizeEventId(eventId)
  if not event then return false end
  emit("resume", { event })
  setStatusByEvent(event, "playing")
  return true
end

--- relay.stop()
-- Stops a specific haptic playback by request ID (numeric).
-- Example output to openmw.log: [bHaptics]stop,12345
function relay.stop(requestId)
  local reqId = tonumber(requestId)
  local rec = reqId and requestsById[reqId] or nil
  if not rec or not rec.hasRequestId then
    -- Probably came from a play() call without SDK requestId.
    return false
  end
  emit("stop", { tostring(reqId) })
  clearRequest(reqId)
  return true
end

--- relay.stop()
-- Stops a specific haptic playback by event ID (string).
-- Example output to openmw.log: [bHaptics]stop,impact
function relay.stopByEventId(eventId)
  local event = normalizeEventId(eventId)
  if not event then return false end
  emit("stopByEventId", { event })
  clearByEvent(event)
  return true
end

--- relay.stop()
-- Stop all currently playing haptic events.
-- Example output to openmw.log: [bHaptics]stopAll
function relay.stopAll()
  emit("stopAll")
  clearAll()
  return true
end

---------------------
-- Query Functions --
---------------------

--[[
NOTE:
bHaptics SDK does offer these functions, which bHapticsRelay supports.
However, OpenMW is one-way communication to bHaptics SDK only via writing to openmw.log.
Since we cannot get data back into OpenMW Lua, we replicate these functions here
via internal tracking states.
--]]

--- relay.isPlaying()
-- Returns true if any event Id is currently playing.
function relay.isPlaying()
  for _, bucket in pairs(eventsById) do
    if bucket.anyPlaying then return true end
  end
  return false
end

--- relay.isPlayingByRequestId()
-- Returns true if a specific event Id is currently playing, by request Id (numeric).
function relay.isPlayingByRequestId(requestId)
  local reqId = tonumber(requestId)
  local rec = reqId and requestsById[reqId] or nil
  return rec and rec.status == "playing" or false
end

--- relay.isPlayingByEventId()
-- Returns true if a specific event Id is currently playing, by event name (string).
function relay.isPlayingByEventId(eventId)
  local event = normalizeEventId(eventId)
  if not event then return false end
  local bucket = eventsById[event]
  return bucket and bucket.anyPlaying or false
end

-- Wipes tracking of event and request Ids tracked internally
function relay.resetTracking()
  clearAll()
end

-------------------
-- Master Switch --
-------------------

--- relay.setEnabled()
-- Controls whether haptics are enabled (true) or disabled (false)
 function relay.setEnabled(val)
  hapticsEnabled = not not val -- force boolean
end

--- relay.isEnabled()
-- Returns current state of master switch
function relay.isEnabled()
  return hapticsEnabled
end

return relay
