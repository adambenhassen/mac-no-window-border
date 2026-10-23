#!/bin/zsh
# How long the engine stops the app's own main loop. This is the number the phase is judged by:
# the engine has to stay under 5 ms.
#
# The measurement is the app's own: tests/hostapp tick runs a 1 ms main-queue timer with no leeway
# and reports, every 5 s, the longest gap between two of its fires. A gap is a stretch in which the
# main thread was not running its own queue, whatever stopped it.
#
# What is *not* the engine has to be measured too, because it is not small: an app crossing the
# maximized boundary spends several milliseconds of its own main thread resizing, and a test that
# photographs the window every half second keeps the app's window-server connection busy. So the
# driving is run twice, with the engine and with nothing (the baseline), and the engine's own action
# is measured on its own as well: apply and restore on a window that is
# already in the state the engine is asked for, which is what a scan loop does.
set -u
source "${0:A:h}/no-noborder.sh"
typeset -F SECONDS  # fractional, so the poll deadlines are exact
cd "${0:A:h}/.."
mkdir -p build/bench
# No arguments: the full benchmark — the driving with the engine and without it, plus the isolated
# run. That is what `make bench` runs. "isolated": the engine's own action only, which is the number
# the verdict is made on, so it is worth measuring on its own, more than once, before it is believed.
modes=()
if [[ ${1:-} != isolated ]]; then
    modes=(native)
fi
say() { print -r -- "$1"; }
# What the last measurement produced, for the caller to report.
gap=0
applied=0

px() {  # px <wid>: "square=… rim=…" from a live capture of that window
    screencapture -x -o -l $1 build/bench/w.png && tests/winpixels build/bench/w.png
}

reached() {  # reached <wid> <wanted px> <seconds>: poll until the window shows that state
    local deadline=$(( SECONDS + $3 ))
    while true; do
        [[ "$(px $1)" == "$2" ]] && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 0.5
    done
}

start_app() {  # start_app <label> -> $host $max: a ticking app, un-maximized, past its launch
    ./tests/hostapp tick small > build/bench/host-$1.log & host=$!
    max=""
    for _ in {1..20}; do
        max=$(awk '$1=="max" {print $2}' build/bench/host-$1.log)
        [[ -n $max ]] && break
        sleep 0.25
    done
    [[ -n $max ]] || return 1
    # The app's own launch (first draw, two windows) costs its main queue tens of milliseconds and
    # belongs to no engine: start counting after the first window of gaps has been reported.
    for _ in {1..40}; do grep -q '^maxgap_ms=' build/bench/host-$1.log && break; sleep 0.25; done
    mark=$(grep -c '^maxgap_ms=' build/bench/host-$1.log)
}

stop_app() {
    [[ -n $host ]] && kill -TERM $host 2>/dev/null
    for _ in {1..20}; do kill -0 $host 2>/dev/null || break; sleep 0.25; done
    kill -9 $host 2>/dev/null; wait $host 2>/dev/null
    host=""
}

max_gap() {  # max_gap <label> -> the largest reported gap, skipping the launch windows counted at mark
    # The mark counts maxgap_ms lines, not file lines: the app prints its window numbers first, and
    # the launch window belongs to no engine.
    awk -v skip=$mark '/^maxgap_ms=/ { n++; if (n <= skip) next;
                                       sub(/^maxgap_ms=/, ""); if ($1 + 0 > m) m = $1 + 0 }
                       END { print m + 0 }' build/bench/host-$1.log
}

# The same driving for every caller: one window across the maximized boundary twice. The app does
# exactly the same thing with and without an engine, which is what makes the two comparable.
drive() {  # drive <label> <native|none> -> sets $gap and $applied
    local engine=$2 i
    applied=0
    local steps=(apply restore apply restore)
    local signals=(USR2 USR1 USR2 USR1)   # maximize / un-maximize
    start_app $1 || { say "FAIL bench: hostapp printed no window number"; return 1; }
    for i in 1 2 3 4; do
        kill -SIG${signals[$i]} $host 2>/dev/null
        sleep 0.5   # let the app finish resizing before the engine is asked to follow
        if [[ $engine == none ]]; then
            sleep 1.5
            continue   # nothing will change; measure the driving alone
        fi
        build/noborder-probe ${steps[$i]} $host $max > build/bench/probe.log 2>&1
        local want="square=1 rim=0"
        [[ ${steps[$i]} == restore ]] && want="square=0 rim=1"
        reached $max "$want" 5 && applied=$((applied + 1))
    done
    sleep 5.5   # the 5 s window that covers the last action has to be reported before it is read
    gap=$(max_gap $1)
    stop_app
}

# The native engine's own action, alone: no resize, no captures, no window-server traffic. A scan
# loop does exactly this on every window it has already decided about.
isolated_native() {  # isolated_native <label> -> sets $gap and $applied
    start_app $1 || { say "FAIL bench: hostapp printed no window number"; return 1; }
    local done=0 i
    for i in {1..16}; do
        build/noborder-probe apply $host $max > build/bench/probe.log 2>&1 && done=$((done + 1))
        sleep 0.2
        build/noborder-probe restore $host $max > /dev/null 2>&1
        sleep 0.2
    done
    sleep 5.5   # the window covering the last call has to be reported before the gap is read
    gap=$(max_gap $1)
    stop_app
    applied=$done
}

for mode in $modes; do
    drive "baseline-$mode" none
    local_gap=$gap; local_applied=$applied
    drive "$mode" $mode
    say "bench engine=$mode maxgap_ms=$gap baseline_ms=$local_gap applied=$applied/4"
done

isolated_native "native-isolated"
say "bench isolated=native maxgap_ms=$gap actions=$applied/16"

# "beaten" is the phase's bar: the native engine's own work keeps the app's main loop inside 5 ms,
# and every action it was asked for applied. A missing action is not a fast engine.
isolated_gap=$gap
isolated_actions=$applied
if [[ $isolated_gap -lt 5 && $isolated_actions == 16 ]]; then
    say "verdict=beaten"
else
    say "verdict=not-beaten"
fi
