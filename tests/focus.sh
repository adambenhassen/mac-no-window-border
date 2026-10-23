#!/bin/zsh
# Regression for the focus repaint race (2026-10-21): switch away from an app and back, and the
# border must not stay. The bug was in the scan loop's kick path — at focus-in the target is busy
# repainting, the native key read times out and answers nothing, and the old code gated the
# re-apply on that read, so the repainted border stood. The fix re-asserts applied windows on a
# user kick unconditionally (WindowTracker.update, transitionsAreUser) with no key read.
#
# The logic is covered deterministically by the Swift unit tests (testAKickReassertsEvenWhenNoKey-
# ReadRan, testAFocusKickReassertsWithoutAKeyRead). This drives the whole stack end to end against
# tests/hostapp only: the real ScanLoop + AgentEngine, its agent installed in a real process, a
# real window. `build/noborder-e2e` is that stack with SIGUSR1 standing in for the activation
# notification the shipped app turns into `loop.kick()`.
#
# The oracle is the fix's contract, not pixels (screen capture is a black image headless — the same
# reason tests/e2e.sh's app mode is GUI-only): on the kick the agent accepts an apply (`deferred=[]`)
# AND the engine does no key read (`KEYREAD`). The old code read the key state on a kick; at focus-in
# that read times out and answers nothing, and the re-apply was gated on it, so the border stood. A
# revert re-introduces the KEYREAD on the kick and fails here.
set -u
source "${0:A:h}/no-noborder.sh"
typeset -F SECONDS
cd "${0:A:h}/.."
out=build/focus
mkdir -p $out
fail=0

[[ -x build/noborder-e2e ]] || { echo "FAIL no build/noborder-e2e (make probe)"; exit 1; }
[[ -x tests/hostapp ]]      || { echo "FAIL no tests/hostapp (make testtools)"; exit 1; }

host=""; harness=""
cleanup() {
    [[ -n $harness ]] && kill -TERM $harness 2>/dev/null
    [[ -n $host ]] && kill $host 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log=$out/harness.log
: > $log

await() {  # await <pattern> <timeout> <from-line>: a matching line at/after <from-line>, else 1
    local deadline=$((SECONDS + $2))
    while true; do
        tail -n "+$3" $log 2>/dev/null | grep -qE "$1" && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 0.2
    done
}

tests/hostapp > $out/host.txt 2>&1 & host=$!
sleep 1.5
max=$(awk '$1=="max"{print $2}' $out/host.txt)
[[ -n $max ]] || { echo "FAIL hostapp did not report a window"; exit 1; }
echo "note hostapp pid=$host wid=$max"

# The whole product stack, scoped to the one window: install the agent, apply.
build/noborder-e2e $host $max > $log 2>&1 & harness=$!

if await "APPLY $host \[$max\] deferred=\[\]" 25 1; then
    echo "PASS the agent applied the window: $(grep -m1 "APPLY $host" $log)"
else
    echo "FAIL the agent never applied the window: $(tail -5 $log)"; fail=1
fi
# Wait out the single timer key read (keyReadInterval is large → exactly one) before the kick, so a
# KEYREAD after the kick is the kick's own and never a slow timer read landing late (a false FAIL).
await "KEYREAD $host" 10 1
sleep 0.3

# The kick (the activation notification) must re-apply the window WITHOUT a key read.
kickLine=$(( $(wc -l < $log) + 1 ))
kill -USR1 $harness
if await "APPLY $host \[$max\] deferred=\[\]" 10 "$kickLine"; then
    echo "PASS the focus kick re-applied the window: $(tail -n +$kickLine $log | grep -m1 "APPLY $host")"
else
    echo "FAIL the kick did not re-apply the window: $(tail -n +$kickLine $log)"; fail=1
fi
if tail -n +$kickLine $log | grep -q "KEYREAD"; then
    echo "FAIL the kick did a key read (the old, buggy path): $(tail -n +$kickLine $log | grep -m1 KEYREAD)"; fail=1
else
    echo "PASS the kick re-applied with no key read (the read times out on a busy app at focus-in)"
fi

# Quit restores the window and removes the agent (the loop's stop), promptly.
kill -TERM $harness
if await "STOPPED" 15 1; then
    echo "PASS quit restored and stopped cleanly: $(grep -m1 RESTORE $log || echo "restore line")"
else
    echo "FAIL the harness did not stop within 15 s: $(tail -3 $log)"; fail=1
fi
harness=""

exit $fail
