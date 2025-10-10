--[[ OpenMW bHaptics v0.1.5-alpha
player-flight.lua
Date: 10/10/25
Author: Dteyn
URL: https://github.com/Dteyn/OpenMW-bHaptics
Description: Provides haptic feedback for flying up and flying down effect
Target: OpenMW/OpenMW-VR 0.49.0 - Lua API v76

Author's notes:
---------------
This script implements an effect I really wanted, but wasn't sure how to implement. I've leaned
heavily on GPT-5 Thinking (Plus subscription) for this, although I have asked it to clean up
and make the variable names descriptive as well as add comments explaining everything.

The basic idea here is that when player does a huge jump - like with Scroll of Icarian Flight -
there should be haptics that play as the player 'flies up' and then those haptics should slow down
as the player gets to the apex of the jump, and then those effects reverse as the player begins
to fall. There is a 'ramp up' and 'ramp down' effect to slow the duration of the effect based
on vertical velocity.

The script uses bHaptics SDK2 'playParam' command, which has intensity and duration values. The
duration value specifically is needed to speed up / slow down the effect depending on player's
vertical velocity.

In initial versions, there was some 'jitter / noise' that needed to be accounted for, so GPT
used something called 'Schmitt flip' or 'Schmitt-style ON/OFF thresholds' which I'm not familiar
with. This type of programming is a bit beyond my skill, but the good news is everything seems to
work as I'd anticipated.

The code is no doubt way over-engineered and needs to be simplified, but the good news is with
this version, there are a lot of tunable values. I spent some time tuning them until the effect
felt right to me. I'm happy with where it's at now.

As a sidenote, this effect also plays while flying up/down using levitation effect, which I kind of like,
but I also like the separate levitation effect itself. This would interfere so it's a one-or-the-other
situation. I've left it enabled for now until I've tested it more in game.

Ultimately, this should be worked into the main player.lua, but for now I'm leaving it as a separate
script. Before moving it to player.lua I will need to simplify it down but that's a project for future me.
This works fine for initial implementation so am leaving it like this for time being.

What follows is an AI-generated description of what the script is doing and why.

-Dteyn

Purpose
-------
Drive bHaptics “flying up / flying down / fall impact” feedback during
big jumps by watching the player's vertical velocity (vy). We smooth vy
with a moving average, use Schmitt-style (hysteresis) thresholds with
hold-times (debounce) to avoid flicker, and rate-limit haptic emits so
we don't spam the bridge.

How it works (high level)
-------------------------
1) Compute vy each update from change in Z over change in simulation time.
2) Smooth vy via a short moving average (MA) to reduce jitter -> vy_ma.
3) "Arm" when we detect a true liftoff: player leaves ground AND sustains
   a high enough upward vy_ma for a minimum hold time. (Prevents air
   bumps or stairs from triggering flight.)
4) While armed:
   - Ascend effect turns ON when vy_ma ≥ ASCEND_VY_ON for HYSTERESIS_HOLD_MS,
     and turns OFF when vy_ma ≤ ASCEND_VY_OFF for HYSTERESIS_HOLD_MS.
   - Descend effect turns ON when vy_ma ≤ DESCEND_VY_ON, and OFF when vy_ma ≥
     DESCEND_VY_OFF, both with the same hold-time hysteresis.
   - Each active effect emits at most every EMIT_INTERVAL seconds, with
     intensity and duration scaling derived from vy_ma.
5) On a hard landing (touch ground with vy_ma ≤ HARD_LAND_VY_THRESHOLD),
   fire a fall impact effect and reset all state.

--]]

local core     = require('openmw.core')
local selfObj  = require('openmw.self')
local types    = require('openmw.types')

---------------------------------------------------------------------
-- Tunables (units, windows, thresholds) ----------------------------
---------------------------------------------------------------------
-- Notes:
-- - Velocity units are "game units per second" (u/s).
-- - Hold times are in milliseconds (ms).
-- - MOVING_AVG_SAMPLES is a sample *count*, not time, but at typical update
--   rates ~24 samples ≈ ~100 ms of smoothing. Adjust to taste.

local MOVING_AVG_SAMPLES     = 24      -- samples in vy moving average (~100 ms).       default = 24
local LIFTOFF_ARM_VY         = 1200    -- must sustain vy ≥ this to arm after liftoff   default = 1200
local LIFTOFF_ARM_HOLD_MS    = 50      -- hold above LIFTOFF_ARM_VY for this long       default = 50

-- Ascend Schmitt thresholds (ON high, OFF low) + debounce hold-time
local ASCEND_VY_ON           = 1200    -- vy_ma ≥ this (for hold) => ascend ON          default = 1200
local ASCEND_VY_OFF          = 120     -- vy_ma ≤ this (for hold) => ascend OFF         default = 120

-- Descend Schmitt thresholds (ON low, OFF high) + debounce hold-time
local DESCEND_VY_ON          = -800    -- vy_ma ≤ this (for hold) => descend ON         default = -800
local DESCEND_VY_OFF         = -50     -- vy_ma ≥ this (for hold) => descend OFF        default = -50

local HYSTERESIS_HOLD_MS     = 200     -- debounce hold for all ON/OFF decisions        default = 200

-- Landing detection
local HARD_LAND_VY_THRESHOLD = -200    -- vy_ma must be ≤ this on touchdown             default = -200

-- Duration scaling vs speed (maps |vy| into a duration scale)
local VY_CAP_ABS             = 5000    -- cap |vy| before scaling                       default = 5000
local DURATION_SCALE_MIN     = 0.5     -- shortest allowed effect (half base duration)  default = 0.5
local DURATION_SCALE_MAX     = 3.0     -- longest allowed effect (triple base duration) default = 3.0

-- Landing duration mapping (computed but not used by the current play call;
-- left available for future tuning if you decide to parameterize landing)
local MIN_LAND_DURATION_S    = 0.5    -- minimum landing effect duration (gentle land)  default = 0.5
local MAX_LAND_DURATION_S    = 2.0    -- maximum landing effect duration (hard land)    default = 2.0

-- Emit throttling (rate limit to avoid spamming the bridge)
local EMIT_INTERVAL          = 0.25   -- interval to emit haptic triggers               default = 0.25

---------------------------------------------------------------------
-- State & buffers ---------------------------------------------------
---------------------------------------------------------------------
-- Moving-average accumulator for vertical velocity (vy)
local vyRingBuffer           = {}      -- last N raw vy samples
local vyRingSum              = 0.0     -- running sum of samples in the vy ring buffer

-- Previous frame’s state (for computing delta vy)
local prevZ                  = selfObj.position.z           -- last Z position sampled
local prevSimTime            = core.getSimulationTime()     -- last simulation time sampled

-- Grounded state (used to detect liftoff/landing edges)
local wasOnGround            = types.Actor.isOnGround(selfObj)

-- Debounce/hold timers (milliseconds) for Schmitt-style ON/OFF thresholds
local armHoldMs, ascOnHoldMs, ascOffHoldMs = 0, 0, 0
local descOnHoldMs, descOffHoldMs          = 0, 0

-- High-level state flags (armed flight mode and current effect states)
local isArmed                = false        -- true once a liftoff has been validated
local isAscending            = false        -- ascend haptics currently active
local isDescending           = false        -- descend haptics currently active

-- Emit clocks (seconds since last emit), and a separate fade for descend
local ascendEmitElapsed      = 0.0          -- time since last ascend haptic emit
local descendEmitElapsed     = 0.0          -- time since last descend haptic emit
local descendFadeElapsed     = 0.0          -- ramps 0 → 1 during the first second of fall

---------------------------------------------------------------------
-- Helpers -----------------------------------------------------------
---------------------------------------------------------------------

--- Clamp numeric value into [lo, hi].
local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

--- Map |vy| to a landing duration in seconds in [MIN_LAND_DURATION_S, MAX_LAND_DURATION_S].
--- (Available for future use; current landing trigger uses a simple 'play' call.)
local function landingDurationFromVy(vy)
  local t = clamp(math.abs(vy) / VY_CAP_ABS, 0, 1)
  return t * (MAX_LAND_DURATION_S - MIN_LAND_DURATION_S) + MIN_LAND_DURATION_S
end

--- Advance a "hold" timer used for hysteresis-style debouncing.
--  If `cond` is true, accumulate dt in ms; otherwise reset to 0.
--  Returns the updated timer (in ms).
local function advanceHoldMs(currentMs, cond, dt)
  if cond then
    return currentMs + dt * 1000.0
  else
    return 0
  end
end

--- Emit a bHaptics playParam command.
--  eventId: string (profile's event name)
--  intensity: 0..1
--  durationScale: optional scalar that multiplies profile duration (MIN..MAX)
local function emitPlayParam(eventId, intensity, durationScale)
  if durationScale then
    -- requestId=0 lets the bridge auto-assign
    print(string.format(
      "[bHaptics]playParam,%s,0,%.3f,%.3f,0.0,0.0",
      eventId, intensity, durationScale
    ))
  else
    -- default intensity=1, durationScale=1
    print(string.format("[bHaptics]playParam,%s,0,1.0,1.0,0.0,0.0", eventId))
  end
end

---------------------------------------------------------------------
-- Engine update -----------------------------------------------------
---------------------------------------------------------------------
local function onUpdate(dt)
  ------------------------------------------------------------------
  -- 1) Sample current sim time / position and compute raw vy
  ------------------------------------------------------------------
  local now = core.getSimulationTime()
  if now == prevSimTime then return end  -- no time delta; skip
  local zNow = selfObj.position.z

  local vyRaw = (zNow - prevZ) / (now - prevSimTime)
  prevZ, prevSimTime = zNow, now

  -- Push into moving average ring
  vyRingSum = vyRingSum + vyRaw
  table.insert(vyRingBuffer, vyRaw)
  if #vyRingBuffer > MOVING_AVG_SAMPLES then
    vyRingSum = vyRingSum - table.remove(vyRingBuffer, 1)
  end
  local vy_ma = vyRingSum / #vyRingBuffer

  -- Ground contact
  local onGround = types.Actor.isOnGround(selfObj)

  ------------------------------------------------------------------
  -- A) ARM on true liftoff (leave ground + sustain high vy)
  ------------------------------------------------------------------
  if not isArmed then
    -- Detect the exact moment we leave the ground (edge)
    if wasOnGround and not onGround then
      armHoldMs = 0
    end

    -- After leaving ground, require vy_ma ≥ LIFTOFF_ARM_VY for LIFTOFF_ARM_HOLD_MS
    armHoldMs = advanceHoldMs(armHoldMs, (not wasOnGround and vy_ma >= LIFTOFF_ARM_VY), dt)
    if armHoldMs >= LIFTOFF_ARM_HOLD_MS then
      isArmed = true
    end
  end

  ------------------------------------------------------------------
  -- B) Ascend control (hysteresis + rate-limiting)
  ------------------------------------------------------------------
  if isArmed then
    -- Update ON/OFF hold timers
    ascOnHoldMs  = advanceHoldMs(ascOnHoldMs,  vy_ma >= ASCEND_VY_ON,  dt)
    ascOffHoldMs = advanceHoldMs(ascOffHoldMs, vy_ma <= ASCEND_VY_OFF, dt)

    -- Schmitt flip with hold-time debounce
    if (not isAscending) and (ascOnHoldMs  >= HYSTERESIS_HOLD_MS) then
      isAscending       = true
      ascendEmitElapsed = EMIT_INTERVAL   -- fire immediately on engage
    elseif isAscending and (ascOffHoldMs >= HYSTERESIS_HOLD_MS) then
      isAscending       = false
      ascendEmitElapsed = 0
    end

    -- Throttled emits while ascending
    if isAscending then
      ascendEmitElapsed = ascendEmitElapsed + dt
      if ascendEmitElapsed >= EMIT_INTERVAL then
        -- Duration scale decreases as speed increases (cap at VY_CAP_ABS)
        local speedFrac  = clamp(vy_ma, 0, VY_CAP_ABS) / VY_CAP_ABS
        local durScaleUp = (1 - speedFrac) * (DURATION_SCALE_MAX - DURATION_SCALE_MIN) + DURATION_SCALE_MIN

        -- Intensity ramps from OFF→ON threshold (0..1)
        local intensityUp = clamp(
          (vy_ma - ASCEND_VY_OFF) / (ASCEND_VY_ON - ASCEND_VY_OFF),
          0, 1
        )

        emitPlayParam("player_flying_up", intensityUp, durScaleUp)
        ascendEmitElapsed = 0
      end
    end
  end

  ------------------------------------------------------------------
  -- C) Descend control (hysteresis + rate-limiting + fade-in)
  ------------------------------------------------------------------
  if isArmed then
    -- Update ON/OFF hold timers
    descOnHoldMs  = advanceHoldMs(descOnHoldMs,  vy_ma <= DESCEND_VY_ON,  dt)
    descOffHoldMs = advanceHoldMs(descOffHoldMs, vy_ma >= DESCEND_VY_OFF, dt)

    -- Schmitt flip with hold-time debounce
    if (not isDescending) and (descOnHoldMs  >= HYSTERESIS_HOLD_MS) then
      isDescending        = true
      descendEmitElapsed  = EMIT_INTERVAL   -- fire immediately on engage
      descendFadeElapsed  = 0               -- start 0→1 fade over first second
    elseif isDescending and (descOffHoldMs >= HYSTERESIS_HOLD_MS) then
      isDescending        = false
      descendEmitElapsed  = 0
    end

    -- Throttled emits while descending
    if isDescending then
      descendEmitElapsed = descendEmitElapsed + dt
      descendFadeElapsed = math.min(descendFadeElapsed + dt, 1.0)  -- 1 s fade to full intensity

      if descendEmitElapsed >= EMIT_INTERVAL then
        -- Duration scale decreases as fall speed increases
        local speedFrac   = clamp(-vy_ma, 0, VY_CAP_ABS) / VY_CAP_ABS
        local durScaleDn  = (1 - speedFrac) * (DURATION_SCALE_MAX - DURATION_SCALE_MIN) + DURATION_SCALE_MIN

        -- Intensity fades in during the first second of the fall
        local intensityDn = descendFadeElapsed  -- 0..1 over 1 s

        emitPlayParam("player_flying_down", intensityDn, durScaleDn)
        descendEmitElapsed = 0
      end
    end
  end

  ------------------------------------------------------------------
  -- D) Hard landing (impact) --------------------------------------
  ------------------------------------------------------------------
  if isArmed and (not wasOnGround) and onGround and (vy_ma <= HARD_LAND_VY_THRESHOLD) then
    -- If you later want to scale this landing by speed, compute once here:
    -- local landDur = landingDurationFromVy(vy_ma)   -- currently unused
    print("[bHaptics]play,player_falldown")

    -- Full reset of flight state
    isArmed, isAscending, isDescending = false, false, false
    armHoldMs, ascOnHoldMs, ascOffHoldMs = 0, 0, 0
    descOnHoldMs, descOffHoldMs          = 0, 0
    vyRingBuffer, vyRingSum              = {}, 0.0
    ascendEmitElapsed, descendEmitElapsed, descendFadeElapsed = 0.0, 0.0, 0.0
  end

  -- Latch ground state for next frame
  wasOnGround = onGround
end

return {
  engineHandlers = {
    onUpdate = onUpdate,
  }
}
