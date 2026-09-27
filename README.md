# Ring Quarry (ComputerCraft 1.63, Minecraft 1.6.4)

A 16-turtle chunk quarry that mines in rings around a control chunk.

This repo starts as a copy of the working straight-line quarry,
[Quarry-CC-program](https://github.com/landonracer109/Quarry-CC-program) v8,
and is being turned into the ring version. Until the ring code lands, the
programs here behave exactly like v8 (shown as version R0 on the dashboard).

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
