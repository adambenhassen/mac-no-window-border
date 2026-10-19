#!/bin/zsh
# Checks the native engine changing a real AppKit window: one call script against tests/hostapp,
# verified by pixels rather than by any window-server state.
set -u
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
