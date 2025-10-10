# OpenMW bHaptics

A mod to add bHaptics support to [OpenMW](https://openmw.org/), with a focus on supporting [OpenMW-VR](https://openmw-vr.readthedocs.io/en/latest/manuals/installation/install-openmw-vr.html).

## Version: 0.1.5-alpha

> [!WARNING]
> This mod is currently in a very early **alpha** state. I've published the Lua scripts for now, but have not yet published the required companion app config.
>
> There are some [Known Issues](#known-issues) with performance/memory in the Lua scripts in v0.1.5-alpha, once those are improved I'll publish the complete mod including companion app as v0.2.0-beta.


---

## Table of Contents
- [Overview](#overview)
- [How It Works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [File Layout](#file-layout)
- [High Level Overview](#high-level-overview)
- [Test video](#test-video)
- [Per-Script Reference](#per-script-reference)
- [Installation](#installation)
- [Configuration](#configuration)
- [Runtime Behavior](#runtime-behavior)
  - [common.lua](#commonlua)
  - [relay.lua](#relaylua)
  - [menu.lua](#menulua)
  - [global.lua](#globallua)
  - [player.lua](#playerlua)
  - [player-flight.lua](#player-flightlua)
- [Extending Haptics](#extending-haptics)
- [Performance Notes](#performance-notes)
- [Known Issues](#known-issues)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

---

## Overview
This mod adds bHaptics support to [OpenMW](https://openmw.org/) by printing specially formatted lines to `openmw.log`. A companion app [bHapticsRelay](https://github.com/Dteyn/bHapticsRelay) tails the log, parses `[bHaptics]...` commands, and triggers patterns in bHaptics Player.

The project currently targets [OpenMW](https://openmw.org/) 0.49.0 / [OpenMW-VR](https://openmw-vr.readthedocs.io/en/latest/manuals/installation/install-openmw-vr.html) 0.49.1 stable (**Lua API v76+ is required**).

## How It Works
1. Gameplay scripts detect events via the OpenMW Lua API (sounds, states, effects, inventory deltas, weather changes).
2. When a trigger is detected, a haptic command is emitted through `relay.lua`, which prints a `[bHaptics]<command>,...` line.
3. bHapticsRelay watches `openmw.log`, translates commands to bHaptics SDK calls, and plays the associated pattern on the haptic device.

### Command format
```
[bHaptics]<command>,<comma-separated-params>
```
Supported commands: `play`, `playParam`, `playLoop`, `pause`, `resume`, `stop`, `stopByEventId`, `stopAll`.

See [bHaptics SDK2 API Reference](https://github.com/Dteyn/bHapticsRelay?tab=readme-ov-file#bhaptics-sdk2-api-reference) for more details.

## Features
- Player haptics for common actions: walking, jumping, landing, melee hits, magic cast/hit, drink/eat, inventory pickup, door/teleport transitions, levitation, skill upgrades and level up.
- Ambient triggers (e.g., thunder) and weather-change signaling pipeline (using [OpenMW Lua helper by taitechnic](https://www.nexusmods.com/morrowind/mods/54629)).
- Flight up/down effect based on vertical velocity for large/far jumps (e.g., Scroll of Icarian Flight).
- Sound-to-haptic mapping table with a simple polling loop for adding new haptic effects.
- Internal tracking for currently playing events, pause/resume, and stop.

## Requirements
- [OpenMW](https://openmw.org/) 0.49.0 / [OpenMW-VR](https://openmw-vr.readthedocs.io/en/latest/manuals/installation/install-openmw-vr.html) 0.49.1 or newer (Lua API revision >= 76).
- [bHaptics Player](https://www.bhaptics.com) installed and configured.
- [bHapticsRelay](https://github.com/Dteyn/bHapticsRelay) configured to tail `openmw.log` and route commands to bHaptics Player.
- [OpenMW Lua helper by taitechnic](https://www.nexusmods.com/morrowind/mods/54629) (for weather globals; disables weather haptics if absent).

## File Layout
```
bhaptics.omwscripts

scripts/bhaptics/
  common.lua        -- shared constants/utilities (mod id, API gate)
  relay.lua         -- logging bridge to bHapticsRelay; local tracking of play state
  menu.lua          -- startup heartbeat effect
  global.lua        -- emits weather-change events to player script
  player.lua        -- main player-driven haptics (sounds, inventory, levitation, etc.)
  player-flight.lua -- flight up/down effect (see contents for additional notes)
```

## High Level Overview

### Summary
First, it should be noted I'm new to Lua, this is my first Lua project and also my first OpenMW mod. I've learned a lot through the API docs. I also use GPT-5 as a coding assistant although I strive to understand as much as possible and try to avoid copy/paste so I can understand things better.

With that said, GPT-5 struggled at times recommending things that were either inefficient, causing memory leaks or adding way too many op/s. I thought I had things working nicely until I looked at Lua profiler and in an earlier version had 23,000 op/s and memory leak up to 256mb in a few minutes.

Thankfully, I was able to get that worked out and mostly optimized but I am certain there are more gains to be made. When I started, I had a lot of things in onUpdate and quickly learned I had to move some things into a periodic timer via `runRepeatedly`. I've implemented several of those and all have configurable poll values, and can also be disabled by setting to 0. Disabling one at a time has helped tune them.

I've added more notes on [Known Issues](#known-issues) below. In general, I've added a lot of comments and explanations throughout the files as much as possible. I normally over-comment my code so when I come back to a project I can re-familiarize my thought process at the time.

### Lua improvements down the road
I do realize many things are implemented in a 'less than ideal' form, mainly due to limitations with the current Lua API. I'm targeting v76 for 0.49.0 (OpenMW VR current stable version). Future API will allow quite a bit of improvements.

As the Lua engine improves, many of these triggers should be moved away from stuff like sound polling to actual events or interfaces that could handle them more efficiently.

I've used sound polling for most effects simply out of convenience, as when a sound plays is the correct time to trigger haptics so that has been the main approach. However, as more event handlers and engine handlers are added, transitioning these over to proper events would make sense.

A great example is the melee hit effects when striking another actor. I asked about this on the Discord, and blurpanda mentioned there is `Combat` interface that can be used. This would be perfect, however I couldn't use it in the present implementation since I'm targeting version 0.49.0 (Lua API v76).

Over time, the performance of this mod should improve as the Lua engine is extended and enhanced.

### player-flight.lua

The `player-flight.lua` script implements a specific haptic effect I wanted for large jumps like Scroll of Icarian Flight. It is mostly AI generated with lots of tunable values so I could tweak the effect. It's working nicely but now needs to be be simplified with the logic worked into `player.lua`. I've left it separate for the time being.

### Test video

I've recorded a short video here showing the effects in action, with the bHaptics Player overlay and showing the debug log and Lua profiler at various stages.

[![Test video v0.1.5-alpha](https://img.youtube.com/vi/-qSKcuXfv90/0.jpg)](https://www.youtube.com/watch?v=-qSKcuXfv90)

## Per-Script Reference

### common.lua
Purpose: shared constants and API guard.
- Validates `core.API_REVISION >= 76`; errors otherwise.
- Exposes `MOD_ID` string for other modules.

### relay.lua
Purpose: thin client that prints bHaptics commands to openmw.log and tracks play state locally.

Public API (examples):
```lua
relay.setEnabled(true)                  -- master switch; false ignores all commands
relay.play('heartbeat')                 -- fire-and-forget by event id
local id = relay.playParam('impact',0,0.8,1.0,45,0.0) -- returns requestId
relay.playLoop('player_levitate',1.0,1.0,0,0,0,99999)
relay.pause('impact')
relay.resume('impact')
relay.stop(id)
relay.stopByEventId('impact')
relay.stopAll()
relay.isPlaying()                       -- boolean
relay.isPlayingByRequestId(id)          -- boolean
relay.isPlayingByEventId('impact')      -- boolean
relay.resetTracking()                   -- clears internal tables
```
Notes:
- Uses `print("[bHaptics]...")` to emit commands. bHapticsRelay parses those and forwards to the SDK.
- Internally tracks requests and events so scripts can query play state even though OpenMW cannot read back from the SDK.

### menu.lua
Purpose: send a single heartbeat on game start to verify the relay is connected.
- On first `onInit`, enables relay, prints a heartbeat `play`, then disables.

### global.lua
Purpose: raise a `BH_WeatherChanged` event to the player script when the weather global changes.
- Requires [OpenMW Lua helper by taitechnic](https://www.nexusmods.com/morrowind/mods/54629) (`OpenMW_luahelper.esp`); gracefully disables if missing.
- Polls once per second; when weather ID changes, it sends an event with `{id, name, prevId, prevName}`.

### player.lua
Purpose: main haptics driver for player events.

Core areas:
- Sound-to-haptic mapping table (`SOUND_TO_HAPTIC`): walking, swimming, weapons, magic cast success/failure, magic hits, jumping, landing, etc.
- Player sound polling: rising-edge detect to avoid spamming duplicate plays.
- Actor sound polling: detects melee hits the player lands by checking a small set of hit sound IDs on nearby actors.
- Ambient polling: triggers thunder effect when certain ambient thunder IDs fire.
- Levitation polling: starts a running loop effect while the levitate active effect is present.
- Inventory polling: counts all items and triggers on increasing count; dynamically skips ticks based on total inventory to keep costs bounded.
- Container polling: detects lockpick success/fail on nearby doors and containers to trigger effects.
- Health watcher: low-health heartbeat with critical health trigger, as well as death and healing effects.
- Transitions: `onTeleported` sends a door/portal travel haptic.
- Consumables: `onConsume` maps potions to drink and ingredients to eat effects.
- Skill/level up: hooks `SkillProgression` and level up UI mode change to trigger effects.
- Weather changed: receives `BH_WeatherChanged` and would play looped weather effects; playback currently disabled pending edge-case handling.

Tuning points:
- Poll interval constants, health thresholds, and debug switch.
- Sound map table for easy extension.
- Distance thresholds for actor lockpick and melee checks.

### player-flight.lua
Purpose: optional flight up/down effect driven by vertical velocity with smoothing and hysteresis.

Highlights:
- Computes vy from Z and simulation time; applies a small moving average.
- Starts effect on liftoff with a minimum sustained vy; then manages ascend/descend states with Schmitt-like on/off thresholds and hold timing.
- Emits `playParam` at a fixed interval with intensity and duration scaling based on vy magnitude.
- Detects hard landings and triggers a fall impact.
- Tunable thresholds for ascend/descend, hold times, MA window, emit rate, and duration scaling bounds.

Note:
- This script is mostly AI-generated and way too complex. But, it does implement the effect I wanted. It should be integrated into `player.lua` but am leaving it separate for now.

## Installation
1. Copy the `scripts/bhaptics` folder into your OpenMW data path.
2. Install and start bHaptics Player.
3. Start the companion app bHapticsRelay, pointing it at your OpenMW `openmw.log` path.
> [!NOTE]
> Currently bHapticsRelay is not packaged with the alpha release until the Lua scripts are debugged. It will be included with the beta release.
4. Ensure your OpenMW config loads these scripts (via content list or your mod packaging method).
5. Install OpenMW Lua Helper (OpenMW_luahelper.esp) if you want weather haptics (rain, wind, etc).

## Configuration
Most tunables live in `player.lua` and `player-flight.lua` as local constants near the top.

Common examples:
- Poll intervals: `ACTOR_POLL_INTERVAL`, `PLAYER_POLL_INTERVAL`, `AMBIENT_POLL_INTERVAL`, `LEVITATION_POLL_INTERVAL`, `INVENTORY_POLL_INTERVAL`, `CONTAINER_POLL_INTERVAL`. Set to 0 to disable.
- Debugging: set `DEBUG = true` to include extra debug logging in openmw.log. Set `true` by default in alpha version.
- Health thresholds: `LOW_HP`, `CRIT_HP`, `MAX_HEARTBEATS` to control heartbeat effect.
- Inventory backoff tiers: with larger inventories, skip frames to avoid performance impact
- Flight effect thresholds and smoothing: see `player-flight.lua` tunables.

## Runtime Behavior
- On init/load, player script builds a sound->haptic map and starts periodic pollers.
- Sound polling checks the OpenMW sound system for specific IDs and triggers mapped haptics on rising edges.
- Actor polling looks for melee-hit sound IDs on nearby actors to infer successful strikes.
- Ambient polling looks for thunder IDs on the ambient sound channel.
- Levitation polling watches active effects and starts/stops a looped haptic.
- Inventory polling counts items and triggers a store/pickup effect when count increases; it increases skip ticks at high counts.
- Weather changes are signaled from `global.lua` to `player.lua` (effect playback currently disabled pending edge-case fixes).
- Startup heartbeat: `menu.lua` toggles the relay and sends a short heartbeat so users know the companion app is working.

---

## Extending Haptics

The script is designed to add more haptic effects easily. I've added most of what I can think of, but there is always room for improvement adding more things that increase immersion.

I'm happy to add the effects to the bHaptics SDK2 profile, just reach out to me via Discord or open an Issue here in GitHub to start a conversation and I'm happy to update that if someone wants to help adding new effects.

### Adding a new sound trigger
1. Ensure the event exists in the bHaptics SDK profile.
2. Open `player.lua` and locate `SOUND_TO_HAPTIC`.
3. Add a new mapping:
```lua
["your sound id"] = function() relay.play("your_event_id") end,
```

### Add a new periodic poller
1. Implement `local function myPoller()` in `player.lua`.
2. Append to the `pollers` list in `startPollers()` with an interval.

### Emit parameterized patterns
- Use `relay.play(eventId)` for simple effects.
- Use `relay.playParam(eventId, requestId, intensity, duration, angleX, offsetY)` for more complex effects.
- Use `relay.playLoop(...)` for loops.

---

## Performance Notes
- Poll intervals default to 0.10 s. Disable a poller by setting its interval to 0.
- Inventory polling is the most expensive poller. It scales to skip ticks by inventory size to cap work per second.
- Actor and container checks use distance thresholds to bound search distance.
- Flight script rate-limits emits with `EMIT_INTERVAL` and smooths vy to reduce chatter.

## Known Issues

### Performance Improvements Needed
- Small memory leak in player.lua which I haven't yet identified. It seems to use around 2mb of memory which seems like a lot.
- Container polling is quite expensive when outside, it needs to be optimized. Lua Profiles shows op/s around 80-100 indoors but around 2000 outdoors.
- Inventory polling is can get expensive with lots of items. Currently will skip frames on larger inventory amounts but that is not ideal as results in delayed haptics. This should be updated if there is another way to trigger based on items added to inventory.

### Weather Effects
- Weather effects are disabled until edge cases are handled:
  - Pause/stop when in interiors or menus, stop underwater, resume correctly on re-entry.

### Future Improvements
- Actor-hit haptics piggyback on sound IDs; finer combat hooks will be available in newer v96+ API via `Combat` interface.
- VR-specific handedness mapping is not yet implemented for certain effects where it would make sense to have them per-hand.
- On stable release, most debug logging can be removed once no longer needed.

## Troubleshooting
- No haptics at all: confirm bHaptics Player is running and bHapticsRelay is tailing the correct `openmw.log`.
- See the startup heartbeat in `openmw.log` after launching a game. If not present, `menu.lua` may not be loading.
- Enable `DEBUG = true` in `player.lua` to trace decisions and verify pollers are running.
- Use `relay.setEnabled(true)` and `relay.stopAll()` to reset the bridge after a death event.

## Contributing
- Keep mappings and pollers small and readable.
- Prefer rising-edge detection over constant re-emits.
- Include a short comment on new sound IDs and why the effect is appropriate.
- PRs welcome!

## Credits
- OpenMW team for the Lua API.
- OpenMW-VR team for the VR fork of OpenMW.
- bHaptics for their awesome devices and stellar SDK.
- OpenMW Lua Helper by taitechnic for weather globals.

## License
MIT

