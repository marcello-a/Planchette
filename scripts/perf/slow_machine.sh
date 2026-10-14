#!/bin/zsh
# usage: slow_machine.sh <busy-processes> <logfile> <max-seconds>
#
# Runs the whole unit-test suite on a machine that is made slow, WITHOUT starving your own work:
# the busy processes AND the test run use the background QoS class, which keeps them on the
# efficiency cores, so everything at normal priority (your editor, your agents) is untouched.
# A watchdog stops it all when the load average passes 90 or more than 60 git processes run.
# Typical: 32 busy processes make the suite about 10 times slower; the log is <logfile>.
#
# A different way to slow ONE thing down: put slow-git/ first on PATH and set
# PLT_GIT_SLOW_SUBCOMMAND=commit PLT_GIT_DELAY=16 — `git commit` then takes 16 s, longer than
# the app's 15 s poll deadline, with no load at all.
N=${1:-16}; LOG=$2; MAX=${3:-900}
HERE=${0:A:h}
cd "$HERE/../../macos/Planchette"
pids=(); testpid=""
# taskpolicy replaces itself with `yes`, so $pids are the busy processes themselves.
cleanup() { [ -n "$testpid" ] && kill $testpid 2>/dev/null; kill $pids 2>/dev/null }
trap cleanup EXIT INT TERM
for i in $(seq 1 $N); do taskpolicy -b yes > /dev/null & pids+=($!); done
echo "hogs: $N (background QoS), max ${MAX}s" > "$LOG"
taskpolicy -b swift test --skip-build >> "$LOG" 2>&1 &
testpid=$!
start=$SECONDS
while kill -0 $testpid 2>/dev/null; do
  sleep 5
  load1=$(sysctl -n vm.loadavg | awk '{print $2}' | tr ',' '.')
  gits=$(pgrep -x git | wc -l | tr -d ' ')
  el=$((SECONDS - start))
  echo "watch t=${el}s load1=${load1} git=${gits}" >> "$LOG.watch"
  if awk "BEGIN{exit !($load1 > 90)}" || [ "$gits" -gt 60 ] || [ "$el" -gt "$MAX" ]; then
    echo "ABORT by watchdog at t=${el}s load1=${load1} git=${gits}" >> "$LOG"
    break
  fi
done
cleanup
wait 2>/dev/null
echo "finished after $((SECONDS - start))s" >> "$LOG"
