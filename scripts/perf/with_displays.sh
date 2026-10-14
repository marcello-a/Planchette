#!/bin/zsh
# usage: with_displays.sh <seconds> <command...>
#
# Keeps the displays awake while the command runs: a terminal needs an awake display to start,
# so every GUI measurement here needs one. Afterwards the displays go back to sleep, but only
# when nobody touched the keyboard or the mouse for 60 s.
HERE=${0:A:h}
DISPLAYS=$(python3 -I "$HERE/perf_common.py" tool displays)
secs=$1; shift
caffeinate -d -u -t $secs &
cpid=$!
sleep 3
"$@"
rc=$?   # not `status`: that is a read-only variable in zsh
kill $cpid 2>/dev/null
idle_s=$(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
echo "HID idle: ${idle_s}s"
if [ "$idle_s" -gt 60 ]; then
  pmset displaysleepnow; sleep 3; echo "displays put back to sleep: $("$DISPLAYS")"
else
  echo "somebody is at the machine; displays left alone"
fi
exit $rc
