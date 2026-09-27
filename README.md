# Ring Quarry (ComputerCraft 1.63, Minecraft 1.6.4)

A 16-turtle chunk quarry that mines in rings around a control chunk.

It grew out of the working straight-line quarry,
[Quarry-CC-program](https://github.com/landonracer109/Quarry-CC-program) v8
(same network timing, service turtle and dashboard). R1 is the first ring
version: it passes the simulator's full test set (normal runs, restarts,
server crashes), but hasn't run in game yet.

## The plan

- Mine clockwise rings around the control chunk: 3x3, then 5x5, then 7x7, and so on.
  The control chunk (main computer tower, service turtle) is never mined.
- A spoke runs north from the home row, along the old straight-line chunks.
  Turtles travel home along their ring, then down the spoke.
- The service turtle's home column and its marker block are protected and
  are never dug. The rest of the chunks around the base get mined.
- Spot Loaders from ring 2 outward: one per chunk. Lane 0 collects a finished
  ring's loaders; spoke loaders stay until the end of the run. Ring 1 sits in
  the always-loaded 3x3.
- Run size is in rings. The main computer keeps a map of finished chunks
  and shows it on the dashboard.
- GPS (4 host computers on the tower) so turtles can always find their way
  home, plus a RECALL button.

## Setting up (from v8)

1. **GPS**: 4 computers with wireless modems up on the tower, spread out
   (not all at the same height or in one line). On each, run
   `gps host <x> <y> <z>` with that computer's own coordinates (F3), in a
   `startup` file so they come back after a restart. The turtles work
   without GPS too, but then can't find their way after a crash.
2. **Spot Loaders**: a stack in slot 16 of lane 0. Mining ring R needs
   9R-2 of them at once (ring 2: 16, ring 3: 25, ring 7: 61; ring 1: none),
   so one stack of 64 covers up to ring 7.
3. Update everything from this repo (UPD on the dashboard, or `c update`).
   The main computer asks how many rings to mine; SET changes it later.
   The map of finished chunks is kept in `quarry.map` (START OVER in SET
   clears it). Chunks are checked before they're mined, so already-mined
   ones go quickly.
4. Fluids: turtles move and dig through water and lava without harm.

## Programs

| File | In game | What |
|---|---|---|
| ControlCPU | `c` | main computer: dashboard, run control, update server |
| TurtleTest1 | `m <lane>` | mining turtle |
| ServiceTurtle | `s` | service turtle (unloads miners, hands out fuel) |
| Join | `disk/join` | installer / boot loader for turtles |
| Push | `push <file>` | uploads a file and prints a link to share |
| NetMon | `netmon` | listen-only live count of rednet messages |
| RangeTest | `rangetest` | checks how far a wireless modem reaches |
