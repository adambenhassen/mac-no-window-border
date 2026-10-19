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

squared() {  # squared <wid> -> "square=…" field of tests/winpixels for that window
    screencapture -x -o -l $1 build/engine.png
    tests/winpixels build/engine.png
}

start_host ""
out=$($probe run $host $maxwid applied)
case "$out" in
    result=ok*)
        note "PASS engine applied: $out"
        px=$(squared $maxwid)
        [[ "$px" == square=1* ]] && note "PASS engine squares corners: $px" \
                                 || note "FAIL engine squares corners: $px"
        out=$($probe run $host $maxwid restored)
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
