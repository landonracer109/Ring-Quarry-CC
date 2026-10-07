#!/bin/bash
# The ring quarry's regression set, run on many cores at once.
#   bash suite.sh            everything
#   bash suite.sh quick      a quick subset
# Prints only failures, then "N of M failed".
cd "$(dirname "$0")"
JOBS=${JOBS:-22}
mode=${1:-full}

scenarios() {
  local dig=$1 # "" or "SIM_DIGSLOT1=1"
  local e="SIM_FUEL=coal_block $dig SIM_TLIMIT=60000"
  echo "$e | 4 4 10 1"
  echo "$e | 4 4 10 2 - - 30"
  echo "$e | 4 4 10 3 - - 40"
  echo "$e | 16 16 20 1 - - 64 - 8x6"
  echo "$e SIM_PREMINED=0,1;0,2 | 4 4 10 2 - - 30"
  echo "$e SIM_TOUCH=700:RECALL,702:RECALL? | 4 4 10 2 - - 30 - - - - 1000"
  echo "$e | 4 4 10 2 900 - 30"
  echo "$e SIM_TOUCH=3:SET,4:+1,5:SAVE,40:LOG#2 | 4 4 10 1 - - 30"
  echo "$e SIM_ORES=0.12 | 4 4 12 2 - - 30"
  echo "SIM_FUEL=coal SIM_FUELCHEST=300@1500 $dig SIM_TLIMIT=60000 | 4 4 10 2 - - 30"
  echo "$e SIM_NOTRASH=1 | 4 4 10 1"
  echo "$e SIM_MOB=lane1@500@deep,lane2@700@shallow@200,lane3@900@deep@30 | 4 4 10 2 - - 30"
  [ "$mode" = quick ] && return
  for t in $(seq 300 150 2400); do echo "$e | 4 4 10 2 - - 30 - 6x5 all@$t"; done
  for t in $(seq 300 170 2400); do echo "$e | 4 4 10 2 - - 30 - 6x5 lane0@$t"; done
  for t in $(seq 350 190 2400); do echo "$e | 4 4 10 2 - - 30 - 6x5 service@$t,lane2@$((t+40))"; done
  for t in $(seq 200 37 2400); do echo "$e | 4 4 10 2 - - 30 - 6x5 crash@$t"; done
  for t in $(seq 1500 131 4400); do echo "$e | 4 4 10 3 - - 40 - 6x5 crash@$t"; done
  for t in $(seq 219 82 2400); do echo "$e | 4 4 10 2 - - 30 - 6x5 crash@$t"; done
  for t in 500 1100 1700; do echo "$e | 4 4 10 2 - - 30 - 6x5 crash@$t,crash@$((t+300))"; done
  for t in 900 1800; do echo "$e SIM_NOGPS=1 | 4 4 10 2 - - 30 - 6x5 all@$t"; done
}

list=$( { scenarios ""; scenarios "SIM_DIGSLOT1=1"; } )
total=$(echo "$list" | wc -l)
start=$(date +%s)
results=$(echo "$list" | xargs -P "$JOBS" -d '\n' -n 1 bash one.sh)
fails=$(echo "$results" | grep -c '^FAIL')
echo "$results" | grep -v '^PASS$'
echo "$fails of $total failed  ($(( $(date +%s) - start )) s on $JOBS cores)"
