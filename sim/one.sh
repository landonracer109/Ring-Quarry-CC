#!/bin/bash
# Runs ONE simulator scenario in its own output folder and prints PASS, or
# FAIL with the reasons. The argument is one line: "VAR=x VAR2=y | args".
# (Used by suite.sh to run many scenarios at once.)
cd "$(dirname "$0")"
LUAJIT=${LUAJIT:-luajit} # (set LUAJIT=/path/to/luajit if it is not on your PATH)
line="$1"
envs="${line%%|*}"
args="${line#*|}"
mkdir -p out
dir=$(mktemp -d out/run.XXXXXX)
out=$(env $envs SIM_OUT="$dir/" timeout ${SIM_TIMEOUT:-500} "$LUAJIT" ccsim.lua $args 2>&1)
[ $? -eq 124 ] && out="$out
^ HUNG (over ${SIM_TIMEOUT:-240} s real time)"
if echo "$out" | grep -q "RESULT: PASS"; then
  echo "PASS"
else
  printf 'FAIL [%s] %s\n%s\n' "$envs" "$args" "$(echo "$out" | grep -E "FATAL|\^|LOST" | head -3)"
fi
rm -rf "$dir"
