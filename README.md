# Ring Quarry (ComputerCraft 1.63, Minecraft 1.6.4)

A 16-turtle quarry that mines whole Minecraft chunks down to bedrock, in
**rings around its base**: first the 8 chunks around it, then the 16 around
those, and so on. A main computer runs the show and draws a dashboard with
a map; a service turtle unloads and refuels the miners.

It grew out of the straight-line
[Quarry-CC-program](https://github.com/landonracer109/Quarry-CC-program)
(same turtles, base and dashboard). Mining in rings keeps every chunk close
to the base, so trips home stay short and the radio always reaches.

## How it works

- **The control chunk** is the chunk directly behind the miners' start row.
  It holds the base (main computer, monitors, GPS) and is **never mined or
  crossed**.
- **Rings**: ring 1 is the 8 chunks around the control chunk, ring 2 the
  16 around those, ring 3 the next 24. A run mines "up to ring N".
- **Order**: each ring starts with its **spoke** chunk, straight ahead of
  the miners, then goes **clockwise** around. The spoke line is also the
  way home.
- **16 mining turtles**, one per lane, cover a chunk together, 3 layers per
  pass, down to bedrock. When all 16 finish, the fleet moves to the next
  chunk. Before mining a chunk, each lane checks whether its lane is already
  mined, so already-mined chunks go quickly.
- **Junk** (cobblestone, dirt, gravel) goes into a Trash Can each miner
  carries, so trips home are rare.
- **Going home**: a miner that's nearly full or low on fuel drives back to
  its start spot, each lane at its own depth underground so they never meet.
  When it's shorter, it **flies** instead, 8 to 23 blocks up (each lane its
  own height), over chunks that are loaded but not mined yet, like the one
  being mined. The **service turtle** pulls out its blocks and refuels it.
  Before heading home a miner throws out junk, merges split stacks and
  burns the coal it mined, so it only goes when it really is full.
- **Chunk loading**: ring 1 sits in the always-loaded area around the base.
  From ring 2 on, lane 0 places a **Spot Loader** for each chunk, takes a
  finished ring's loaders back when the next ring starts, and collects them
  all at the end of the run.
- **GPS**: turtles find their position with GPS after a restart or a server
  crash, so they can always get home. **RECALL** brings everyone home now.
- **Survives restarts and server crashes** by itself.
- **Light on the server**: about 0.5–0.7 radio messages a second for the
  whole quarry while mining (each turtle in its own time slot), nothing
  between runs.
- **Mobs in the way**: turtles can't tell a mob from a player, so they
  wait. Only when something has blocked them for a full minute, 5 or more
  layers down and not while travelling, do they swing at it (3 hits a
  minute), and they log it. Near the surface, on the home row and in the
  travel tunnels they never attack.

## What you need

- 17 **advanced turtles** with **wireless modems** and pickaxes
  (16 miners, 1 service turtle).
- 1 **computer** with a **wireless modem** (the main computer) and an
  **Advanced Monitor** (6x5 or bigger), connected with wired modems and
  networking cable.
- 4 more **computers** with **wireless modems** for **GPS**.
- A **disk drive** and a **floppy disk** to install the turtles.
- Two **chests** (fuel and output) and one solid "marker" block.
- For each miner: 1 cobblestone, 1 dirt, 1 gravel and an **Extra Utilities
  Trash Can**.
- **Spot Loaders**, in lane 0's slot 16. Mining ring R needs 9R-2 at once
  (ring 2: 16, ring 3: 25, ring 7: 61; ring 1: none). One stack of 64
  covers up to ring 7.
- Fuel: **coal blocks** are best.
- A `get <url> <file>` program (a small HTTP downloader).

## Layout

Stand behind the miners, looking the way they dig:

```
   lane 0  lane 1  ...  lane 15      <- miners: the spoke chunk's first row
 S  .       .           .            <- home row (inside the control chunk)
```

- **Miners**: 16 in a flush row, facing forward. **Lane 0 is the
  leftmost.** Line up with Minecraft chunks (F3 shows chunk borders): the
  row is the first row of a chunk, lane 0 on its first column. The chunk
  **behind** the row becomes the control chunk.
- **Service turtle home**: one block **behind** lane 0 and one block to its
  **left**, facing the way the miners face. **Output chest above** it,
  **fuel chest below** it (fuel only), a **solid block in front** of it.
  These two columns (home and the block in front) are never dug.
- Everything else goes in the control chunk: main computer, monitor, GPS
  computers. Keep it chunk-loaded.
- Put the main computer and the GPS computers **high up** (y 200+): radio
  range grows with height, from about 64 blocks on the ground to several
  hundred up high.

## Installing (fresh)

1. **GPS**: place 4 computers with wireless modems up high in the control
   chunk, spread out and **not all at the same height** (if they're all in
   one flat plane, GPS can't work). For each: stand on it, read F3 (x and z
   in brackets, y = your feet minus 1), then:
   ```
   edit startup
   ```
   with one line, using that computer's numbers:
   ```
   shell.run("gps", "host", "446", "252", "-194")
   ```
   Save, then run `startup`. Test from any turtle with `gps locate`.
2. **Main computer** (wireless modem and monitor attached, `get` copied
   onto it):
   ```
   get https://raw.githubusercontent.com/landonracer109/Ring-Quarry-CC/main/ControlCPU c
   c install
   c update
   ```
   Reboot it (hold Ctrl+R). It asks **"Mine up to ring"**.
3. **Floppy** in the disk drive:
   ```
   get https://raw.githubusercontent.com/landonracer109/Ring-Quarry-CC/main/Join disk/join
   ```
4. **Service turtle** on its home spot, fueled:
   ```
   disk/join service
   ```
5. **Miners**: slots 12, 13, 14 = 1 cobblestone, 1 dirt, 1 gravel; slot 15
   = the Trash Can; lane 0 also gets Spot Loaders in slot 16. Then, with
   each one's own lane number:
   ```
   disk/join miner 0
   ```
6. On the dashboard, check all 16 lanes and the service turtle show up
   (with the same version in the **VER** column) and press **START**.

Branch links (`/main/`) can be up to 5 minutes out of date right after a
change. For an exact version, replace `main` with a commit hash.

## Switching from the straight-line quarry (v8)

The turtles, chests and base stay as they are.

1. Let the last run finish (or STOP it), so every turtle is home.
2. Set up **GPS** (step 1 above).
3. On the main computer, hold Ctrl+T to stop `c`, then:
   ```
   delete c
   delete staged
   delete quarry.cfg
   delete quarry.progress
   delete .quarry_run_a
   delete .quarry_run_b
   get https://raw.githubusercontent.com/landonracer109/Ring-Quarry-CC/main/ControlCPU c
   c update
   ```
   (Its UPD button would still download the old version until `c` itself
   is replaced. v8's settings would be read as "ring 16", so they have to
   go.) It installs, reboots every turtle onto the ring version and asks
   "Mine up to ring".
4. Put Spot Loaders in lane 0's slot 16 before mining ring 2 or more.

## Using it

Dashboard buttons (bottom row of the monitor), or keys on the main computer:

| Button | Key | What it does |
|---|---|---|
| START | Enter | start a run (once everyone has registered) |
| STOP | S | lanes finish their current pass and go home (touch twice) |
| RECALL | | everyone comes home now, mid-pass (touch twice) |
| SET | C | how many rings to mine (C asks on the computer's own screen); SET also has START OVER, which forgets the map of finished chunks |
| UPD | U | download the newest programs from GitHub; they install between runs and every turtle reboots onto them (touch twice) |
| LOG | L | every turtle uploads its debug log; the main computer shows one link to all of them |

- The **map** beside the service panel and log shows the rings in colored
  blocks, as big as fit: green = mined, yellow `@` = being mined, blue `C`
  = the control chunk, gray = still to do. On a small monitor or with many
  rings it shrinks to one character per chunk (`#`, `@`, `C`, `.`).
  Finished chunks are remembered in `quarry.map` on the main computer.
- The **VER** column shows each turtle's program version: red means it
  hasn't taken the newest update yet.
- If a turtle says **LOST**, put it on its start spot and run
  `m <lane> here` (or `s here` for the service turtle).
- Turtles go through water and lava pools without harm.

## Programs

| File | In game | What |
|---|---|---|
| ControlCPU | `c` | main computer: dashboard, map, run control, update server |
| TurtleTest1 | `m <lane>` | mining turtle |
| ServiceTurtle | `s` | service turtle |
| Join | `disk/join` | installer and boot loader for turtles |
| Push | `push <file>` | uploads files and prints a link to share them |
| NetMon | `netmon` | listen-only live count of radio messages (adds no load) |
| RangeTest | `rangetest` | checks how far a wireless modem reaches |
| BuildTest | `buildtest` | one-time in-game check for the (coming) builder turtle: placing turtles, computers, modems and monitors, booting them from a floppy |

Turtles get their programs from the main computer, so only the main
computer ever downloads from GitHub.

## Simulator

Every change is tested first in a ComputerCraft 1.63 simulator that runs
these exact programs in a fake world, with restarts and server crashes.
It lives in [`sim/`](sim/); see [sim/README.md](sim/README.md).
