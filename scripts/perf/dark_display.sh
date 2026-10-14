#!/bin/zsh
# usage: dark_display.sh <label> <binary> <scratch-folder>
#
# Runs dark_display.py: does a terminal that could not start because every display was
# asleep come alive when a display wakes? The displays must be ASLEEP when this starts
# (`pmset displaysleepnow`, wait until the screen is dark, then run it). Afterwards the
# displays are put back to sleep, but only when nobody touched the keyboard or the mouse
# for 60 s: a person who came back keeps their screen.
HERE=${0:A:h}
DISPLAYS=$(python3 -I "$HERE/perf_common.py" tool displays)
state=$("$DISPLAYS")
case "$state" in
  *active=0*) ;;
  *) echo "The displays are awake ($state): this test would show nothing."
     echo "Put them to sleep first: pmset displaysleepnow, wait a few seconds, run it again."
     exit 2 ;;
esac
python3 -I "$HERE/dark_display.py" "$1" "$2" "$3"
idle_s=$(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
echo "[$1] HID idle: ${idle_s}s"
if [ "$idle_s" -gt 60 ]; then
  pmset displaysleepnow
  sleep 3
  echo "[$1] displays put back to sleep: $("$DISPLAYS")"
else
  echo "[$1] somebody is at the machine; displays left alone"
fi
