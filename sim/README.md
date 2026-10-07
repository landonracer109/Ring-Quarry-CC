# The quarry simulator

A small ComputerCraft 1.63 simulator, written for this quarry. It runs the
**real, unchanged programs** from this repo (ControlCPU, ServiceTurtle,
TurtleTest1, Join): a main computer, a service turtle and up to 16 miners,
all at once in a fake 3D world, in simulated time. Hours of in-game mining
take seconds to a few minutes.

It's text-only: no 3D view or graphs. You get logs, text snapshots of the
dashboard monitor, and a report with checks and server-load numbers.

It is **built for this quarry**: the world it makes, the computers it
starts and the checks at the end are quarry-specific. The ComputerCraft
part (the faked APIs, the event scheduler, crashes and restarts) is the
reusable bit; see "Where things are" below.

## Running it

You need **LuaJIT** (Lua 5.1 compatible) and, for the test suite, **bash**
(Git Bash on Windows works).

```
cd sim
luajit ccsim.lua 4 4 10 2 - - 30
```

Arguments, in order (`-` skips one):

| # | Meaning |
|---|---|
| 1 | lanes (also the chunk size: 4 = 4 lanes in 4x4 chunks; 16 = the real thing) |
| 2 | (unused, from the straight-line version) |
| 3 | depth: layers down to bedrock |
| 4 | rings to mine |
| 5 | press STOP at this time (seconds) |
| 6 | bedrock y (default -depth) |
| 7 | Spot Loaders in lane 0 |
| 8 | touch STOP on the monitor at this time |
| 9 | monitor size in blocks, e.g. `6x5` |
| 10 | restarts: `all@600` (server restart), `lane2@300`, `service@400`, `crash@900` (server CRASH: the world goes back to its last 45 s autosave, computer files don't) |
| 11 | `deploy` / `deploy+update@T` (install via Join, press update at T) |
| 12 | press START again at this time (a second run) |

Options are environment variables, e.g. `SIM_STATS=1 luajit ccsim.lua 16 16 20 1`:

| Variable | What |
|---|---|
| `SIM_STATS=1` | server load: radio messages, monitor writes, file writes, turtle actions per second |
| `SIM_FUEL=coal_block` | what the fuel chest holds (`coal` or `coal_block`) |
| `SIM_DIGSLOT1=1` | dug items land from slot 1 instead of the selected slot (a real CC quirk) |
| `SIM_NOGPS=1` | no GPS hosts |
| `SIM_MOB=lane1@600@deep` | a mob steps in a turtle's way (`@shallow`, `@<seconds>` to wander off) |
| `SIM_ORES=0.25` | share of rare ores (more = more trips home) |
| `SIM_TOUCH=3:SET,4:+1` | touch monitor buttons at given times |
| `SIM_PREMINED=0,1;0,2` | chunks already mined out |
| `SIM_RANGE=40@100-300` | the radio only reaches 40 blocks between t=100 and 300 |
| `SIM_DUMPFILES=1` | write every computer's files (state, debug logs) to the output folder |
| `SIM_NOJIT=1` | JIT off (needed to get a traceback when a program loops forever) |
| `SIM_OUT=dir/` | where to write the logs (default: here) |
| `SIM_TLIMIT`, `SIM_WALL` | simulated / real time limits |

Output: `sim.log` (every event), `ctrl_quarry.log` (the main computer's
log), `monitor_*.txt` (dashboard snapshots), and a report ending in
`RESULT: PASS` or `RESULT: FAIL` with the reasons (`^ ...` lines).

**The test suite** runs about 330 scenarios (sizes, restarts, crashes at
many moments, mobs, both dig-slot behaviors) in parallel:

```
LUAJIT=/path/to/luajit bash suite.sh          # everything, ~8 min on 22 cores
LUAJIT=/path/to/luajit bash suite.sh quick    # ~1 min
```

`one.sh` runs a single scenario in its own folder (used by the suite);
`JOBS=8 bash suite.sh` sets how many run at once.

## Where things are (ccsim.lua)

| Lines (about) | What |
|---|---|
| 1-30 | CC 1.63 quirks (`pairs` error when a key is removed mid-loop) and the watchdog that catches programs looping without waiting |
| 39-75 | arguments; `read_host` loads the real programs from the repo root |
| 76-135 | **event scheduler** (simulated time), load counters, logging, fatal errors |
| 137-235 | **the world**: blocks in a table keyed `"x,y,z"`, autosave + crash rollback, chunk loading, protected spots, radio range, the in-game clock |
| 237-300 | inventories (CC 1.63's insert rules), serialize / unserialize |
| 302-1035 | **computers**: `new_computer` builds each one's APIs: `turtle` (move, dig, place, suck, drop, refuel, attack...), `rednet` + modems, `fs`, `peripheral`, `gps`, `os` (timers, events, reboot), `http` (fake), monitors (`make_monitor`), `parallel` |
| 1035-1048 | `resume`: runs one computer until it waits |
| 1049-1235 | **the scenario**: ore generation, the base (chests, service home), which computers exist and what they run, scripted key presses / touches, restarts |
| 1249-1520 | **the main loop**: hands events to computers in time order, autosaves, crashes, restarts |
| 1520-end | **the report**: every check that decides PASS / FAIL, and the load numbers |

To simulate your own programs, the parts to change are the scenario
(which computers, what they run, what the world looks like) and the
report (what counts as success). The computers, scheduler and world
can stay as they are.

## How the ring programs are built (parts/)

The ring version of the programs is generated, not edited by hand:

- `parts/assemble_miner.lua` builds **TurtleTest1** from `orig_TurtleTest1`
  (the straight-line miner, for the unchanged parts) plus the new parts
  `n0_header.lua` ... `n3_start.lua`.
- `parts/patch_control.lua` (+ `patch_control2.lua`, using
  `patchlib.lua`) builds **ControlCPU** from `orig_ControlCPU`.
- ServiceTurtle is edited directly.

Run them from `sim/parts`: `luajit assemble_miner.lua`, `luajit patch_control.lua`.
They write the programs in the repo root.
