#!/bin/zsh
# Checks the native engine changing a real AppKit window: one call script against tests/hostapp,
# verified by pixels rather than by any window-server state.
set -u
source "${0:A:h}/no-noborder.sh"
cd "${0:A:h}/.."
fail=0
probe=build/noborder-probe

note() { print -r -- "$1"; if [[ "$1" == FAIL* ]]; then fail=1; fi; }

start_host() {  # start_host [args...] -> host, maxwid
    ./tests/hostapp $=1 > build/hostapp.out &
    host=$!
    for _ (1 2 3 4 5 6 7 8 9 10); do
        maxwid=$(awk '$1=="max" {print $2}' build/hostapp.out)
        [[ -n $maxwid ]] && break
        sleep 0.3
    done
    [[ -n $maxwid ]] || note "FAIL hostapp printed no window number"
}
stop_host() { [[ -n $host ]] && kill $host 2>/dev/null; wait $host 2>/dev/null; host=""; maxwid="" }

call_engine() {  # call_engine <applied|restored>: ask, and ask again like the scan loop would.
                 # A target that is busy is not servable yet, and that is a deferral, not a failure;
                 # AppKit's own work after a change (a full-screen window's shadow and titlebar)
                 # keeps an app un-parkable for seconds. Prints the last result and how many tries.
    local mode=$1 out i
    for i (1 2 3 4 5 6 7 8); do
        out=$($probe run $host $maxwid $mode)
        [[ "$out" == result=ok* ]] && { print -r -- "$out attempts=$i"; return 0; }
        sleep 0.5
    done
    print -r -- "$out attempts=$i"
    return 1
}

squared() {  # squared <wid> -> "square=…" field of tests/winpixels for that window
    screencapture -x -o -l $1 build/engine.png
    tests/winpixels build/engine.png
}

call_key() {  # call_key: ask the app the window's key state, retrying a busy app like the loop does.
              # The answer is in the result word: word=1 is key. Prints the last result and tries.
    local out i
    for i (1 2 3 4 5 6 7 8); do
        out=$($probe run $host $maxwid key)
        [[ "$out" == result=ok* ]] && { print -r -- "$out attempts=$i"; return 0; }
        sleep 0.5
    done
    print -r -- "$out attempts=$i"
    return 1
}

start_host ""
out=$(call_engine applied)
case "$out" in
    result=ok*)
        note "PASS engine applied: $out"
        px=$(squared $maxwid)
        [[ "$px" == square=1* ]] && note "PASS engine squares corners: $px" \
                                 || note "FAIL engine squares corners: $px"
        out=$(call_engine restored)
        px=$(squared $maxwid)
        case "$out" in result=ok*) note "PASS engine restored: $out";; *) note "FAIL engine restored: $out";; esac
        [[ "$px" == square=0* ]] && note "PASS engine leaves rounded corners again: $px" \
                                 || note "FAIL engine leaves rounded corners again: $px"
        # Handing the thread back has to leave the app sitting in the same run-loop call it was in:
        # that is where it re-issues the wait, and where a botched restore would show up.
        out=$($probe threadinfo $host)
        [[ "$out" == *"run_state=3"* && "$out" == *"pc=mach_msg2_trap+"* ]] \
            && note "PASS engine hands the thread back: $out" \
            || note "FAIL engine hands the thread back: $out"
        ;;
    *) note "FAIL engine applied: $out" ;;
esac
stop_host

# Review Focus: a call that faults must leave the app alive, parkable, and untouched.
start_host ""
out=$($probe run $host $maxwid applied fault)
case "$out" in
    result=faulted*) note "PASS engine catches a fault: $out" ;;
    *) note "FAIL engine catches a fault: $out" ;;
esac
us=$(print -r -- "$out" | sed -n 's/.*stop_us=\([0-9]*\).*/\1/p')
[[ -n "$us" && "$us" -lt 5000 ]] && note "PASS fault handled without a long stop: ${us}us" \
                                 || note "FAIL fault stop too long or missing: '$out'"
sleep 2
kill -0 $host 2>/dev/null && note "PASS app survives a faulting call" || note "FAIL app died from a faulting call"
[[ "$($probe park $host)" == "park $host parked" ]] && note "PASS app parks again after a fault" \
                                                    || note "FAIL app does not park again after a fault"
px=$(squared $maxwid)
[[ "$px" == square=0* ]] && note "PASS faulting call left the window alone: $px" \
                         || note "FAIL faulting call changed the window: $px"
stop_host

# Task 7's race, kept as a standing check: an app woken by its own 1 ms main-queue timer between
# reading its state and entering. Entering a thread that has been running its own code hands back
# registers from a frame the app has left — measured: it jumped to a signed return address and died
# in EXC_BAD_ACCESS. The entry has to be refused and retried, and the app served and unharmed.
start_host "tick"
ok=0
for _ (1 2 3 4 5 6 7 8); do    # the wake-up has to land in the entry window, so cross the boundary
    kill -USR2 $host; sleep 0.35
    [[ "$(call_engine applied)" == result=ok* ]] && ok=$((ok+1))
    kill -USR1 $host; sleep 0.35
    [[ "$(call_engine restored)" == result=ok* ]] && ok=$((ok+1))
done
(( ok == 16 )) && note "PASS engine serves an app with a 1 ms timer: 16/16 calls" \
                || note "FAIL engine on an app with a 1 ms timer: $ok/16 calls ran"
sleep 1
kill -0 $host 2>/dev/null && note "PASS app with a 1 ms timer survives the calls" \
                            || note "FAIL app died: the entry raced its wake-up"
[[ "$($probe park $host)" == "park $host parked" ]] && note "PASS timer app parks afterwards" \
                                                    || note "FAIL timer app does not park afterwards"
px=$(squared $maxwid)
[[ "$px" == square=0* ]] && note "PASS timer app ends unharmed and unchanged: $px" \
                         || note "FAIL timer app left changed: $px"
stop_host

# The crash of 2026-10-20, kept as a standing check: the shipped app crashed iTerm four times in
# an hour, all on thread 0 (CF run-loop port trap, CF timer heap with a return address in
# anonymous memory, pc in no image at all) while apply storms entered its main thread seconds
# before each crash. The old entry checked the parked state and then acted on it, a window the
# app could wake into (Task 7's race, left open). The entry now stops the thread first, so the
# check and the entry share one frozen moment. This hammers 100 entries into an app woken every
# millisecond: every one has to run, and the app has to be alive and parkable afterwards.
start_host "tick"
ok=0
for _ (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
       21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
       41 42 43 44 45 46 47 48 49 50); do
    [[ "$(call_engine applied)" == result=ok* ]] && ok=$((ok+1))
    [[ "$(call_engine restored)" == result=ok* ]] && ok=$((ok+1))
done
(( ok == 100 )) && note "PASS race stress: 100/100 entries into a 1 ms-timer app" \
                || note "FAIL race stress: $ok/100 entries ran"
sleep 1
kill -0 $host 2>/dev/null && note "PASS app survives the race stress" \
                           || note "FAIL app died in the race stress"
[[ "$($probe park $host)" == "park $host parked" ]] && note "PASS race-stress app parks afterwards" \
                                                    || note "FAIL race-stress app does not park afterwards"
stop_host

# The poison (plan 2026-10-20): apply/restore entries at production storm rates against
# WindowServer-churning windows with a focus flap — the repro harness for the CF
# __CFRunLoopServiceMachPort.cold.1 trap class. It must stay green: every entry runs, the
# apps live and park, and no fresh cold.1 crash report appears. tests/poison.sh exits 3 for
# "no trap" (the passing answer), 0 when the trap fires, 1 when an app died without one.
out=$(POISON_CALLS=40 POISON_APPS=2 POISON_WINDOWS=2 POISON_BUTTONS=1 POISON_ARGS=churn \
      POISON_RETRY=0 tests/poison.sh 1)
rc=$?
case "$rc" in
    3) note "PASS poison: storm entries with churn and focus flap, no CF cold.1 trap: $out" ;;
    0) note "FAIL poison: CF cold.1 trap reproduced: $out" ;;
    *) note "FAIL poison (exit $rc): $out" ;;
esac

# The focus undo, measured 2026-10-20: a window becoming key re-enables AppKit's top-edge
# highlight on a window we changed (the change's ~16 rows move back), while an untouched
# window's focus redraw moves nothing — and the in-app properties (hasShadow,
# drawsDecorationView) stay as the apply left them, so they are not the signal. The signal is
# the window's own key state: `probe run <pid> <wid> key` asks the app `isKeyWindow` for a
# whole batch in one call and packs the answers into the result word (word=1 is key). Measured
# 2026-10-20: the read is the reliable half — a headless activation makes the window key
# (word=1) while the rim pixels stay unflipped; AppKit's rim redraw wants a user gesture. So
# the read is asserted and the rim reported; the loop's response to the signal is unit-tested
# (WindowTrackerTests, ScanLoopTests).
start_host ""
out=$(call_engine applied)
case "$out" in
    result=ok*) note "PASS focus-undo: applied: $out" ;;
    *) note "FAIL focus-undo: applied: $out"
        stop_host
        exit $fail ;;
esac
px=$(squared $maxwid)
cp build/engine.png build/fu_applied.png
[[ "$px" == "square=1 rim=0" ]] && note "PASS focus-undo: the rim is gone: $px" || note "FAIL after apply: $px"
kill -CONT $host; sleep 0.9                              # focus in: AppKit puts its highlight back
out=$(call_key)
# The key answer is the gate: it is what the loop reads, and it answers headless.
# Measured 2026-10-20: the handler's activation after launch makes the window key (word=1)
# with the terminal frontmost; if activation is refused outright, word=0 and the signal has
# no subject to assert on — the SKIP below says so honestly.
if [[ "$out" == *word=1* ]]; then
    note "PASS focus-in made the window key; that is the loop's signal: $out"
    px=$(squared $maxwid)
    if [[ "$px" == *rim=1* ]]; then
        note "PASS the key window's rim is back; the signal tracks the visible undo: $px"
    else
        note "SKIP rim pixels: key without a user gesture does not redraw AppKit's rim: $px"
    fi
    out=$(call_engine applied)
    [[ "$out" == result=ok* ]] && note "PASS the change goes back on: $out" || note "FAIL re-apply: $out"
    px=$(squared $maxwid)
    [[ "$px" == *rim=0* ]] && note "PASS the rim is gone again: $px" || note "FAIL after re-apply: $px"
    kill -WINCH $host; sleep 0.7
    out=$(call_key)
    [[ "$out" == *word=0* ]] && note "PASS focus-out answers not key; the budget is finite: $out" \
                             || note "FAIL after focus-out: $out"
    kill -CONT $host; sleep 0.9                          # the next focus cycle undoes it again: the budget's reason
    out=$(call_key)
    if [[ "$out" == *word=1* ]]; then
        note "PASS the next focus cycle reads key again: $out"
        px=$(squared $maxwid)
        if [[ "$px" == *rim=1* ]]; then
            note "PASS the next focus cycle undoes it again: $px"
        else
            note "SKIP rim pixels: key without a user gesture does not redraw AppKit's rim: $px"
        fi
    else
        note "SKIP 2nd focus cycle: key transfer back to a background app is refused headless: $out"
    fi
else
    note "SKIP focus-undo: focus-in did not make the window key (no user gesture; key transfer is prevented): $out"
fi
call_engine restored > /dev/null
stop_host

# Review Focus: an app whose main thread never parks must not be touched at all.
start_host spin
for _ (1 2 3 4 5 6 7 8 9 10); do      # the app starts spinning 0.5 s after its first draw
    [[ "$($probe park $host)" == "park $host running" ]] && break
    sleep 0.3
done
out=$($probe run $host $maxwid applied)
case "$out" in
    "result=not-parked stop_us=0") note "PASS engine defers an app that never parks: $out" ;;
    *) note "FAIL engine defers an app that never parks: $out" ;;
esac
px=$(squared $maxwid)
[[ "$px" == square=0* ]] && note "PASS app that never parks is untouched: $px" \
                         || note "FAIL app that never parks is untouched: $px"
stop_host

exit $fail
