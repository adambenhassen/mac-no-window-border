#!/bin/zsh
# An entry must hand the run loop back every message its receive has already taken. The thread can
# be stopped with a message delivered and the trap's answer pending, or between the trap and its
# return; an entry that hands back "timed out" there discards the message. When that message is a
# mode's timer wake, CoreFoundation still believes the timer port is armed for the overdue deadline
# and never arms it again: every timer in the mode stops, silently (iTerm 2026-10-23: a paste's
# chunk timer stopped and the tab queued every key behind the unfinished paste).
#
# The target is windowless, so the NoBorder app has nothing of it to change and may stay up.
set -u
cd "${0:A:h}/.."
fail=0
probe=build/noborder-probe
out=""
target=""

note() { print -r -- "$1"; if [[ "$1" == FAIL* ]]; then fail=1; fi; }

if [[ ! -x $probe ]]; then
    note "FAIL probe missing: $probe (make probe)"
    exit 1
fi
make tests/timerloop || exit 1

stop_target() {
    if [[ -n $target ]]; then
        kill $target 2>/dev/null
        wait $target 2>/dev/null
        target=""
    fi
}
trap stop_target EXIT
trap 'exit 130' INT TERM

fired() { awk '$1=="fired" {n=$2} END {print n+0}' $out }

# check <mode> <entries>: run the entries, then the timer must still be counting.
check() {
    out=build/timerloop.$1.out
    ./tests/timerloop > $out &
    target=$!
    sleep 0.5
    $probe run-repeat $target 0 $1 $2 > build/timerwake.$1.out
    local ran=$(grep -c 'result=ok' build/timerwake.$1.out)
    local bad=$(grep -Ec 'result=(failed|faulted|timed-out)' build/timerwake.$1.out)
    sleep 0.3
    local before=$(fired)
    sleep 0.5
    local after=$(fired)
    local alive=0
    kill -0 $target 2>/dev/null && alive=1
    stop_target
    if (( ! alive )); then
        note "FAIL timerwake $1: target exited or crashed after $ran entries"
    elif (( bad > 0 )); then
        note "FAIL timerwake $1: $bad entries failed (see build/timerwake.$1.out)"
    elif (( ran < $2 * 3 / 4 )); then
        # Busy moments may defer an entry, but a handful of successes is not a stress test.
        note "FAIL timerwake $1: only $ran/$2 entries ran (see build/timerwake.$1.out)"
    elif (( after > before )); then
        note "PASS timerwake $1: the timer still fires after $ran entries ($before -> $after)"
    else
        note "FAIL timerwake $1: the timer stopped at $before after $ran entries"
    fi
}

check key 400
check noop 400
exit $fail
