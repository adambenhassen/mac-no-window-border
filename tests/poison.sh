#!/bin/zsh
# Phase-1 mechanism proof for the dispatch entry (plan 2026-10-20): the shipped script runs
# selector calls (setHasShadow:/setHidden:/_setCornerRadius:) inside the fabricated frame;
# the Mach-port churn there is believed to post MACH_PORT_DNREQ notifications onto the run
# loop's wakeup port, and CoreFoundation's next service traps in
# __CFRunLoopServiceMachPort.cold.1. This hammers apply/restore entries with a focus flap
# into tests/hostapp ONLY — never a live app — and scans DiagnosticReports for fresh hostapp
# crash reports carrying the cold.1 frame.
#
# The production crashes ran 3–6 injections/second against high-churn apps; a plain idle
# hostapp at ~1 call/s gives the trap an ~microsecond landing window per call and reproduced
# nothing in 3x200 entries (measured 2026-10-20). The storm settings rebuild the production
# load: POISON_APPS=3 apps churning WindowServer at 60 Hz (tests/hostapp "churn"), entries
# fired back-to-back with no retry sleeps (POISON_RETRY=0).
#
# usage: tests/poison.sh [loops]     (one loop = POISON_CALLS entries; default 1 loop, 200)
# env:   POISON_CALLS (200), POISON_APPS (1), POISON_ARGS ("", e.g. "churn"),
#        POISON_RETRY (0.5 s; 0 = single-shot, no retries — the storm)
# exit:  0 = trap reproduced; 3 = loops finished, no trap (mechanism unproven: stop, re-examine);
#        1 = a hostapp death with no cold.1 frame, or setup trouble.
set -u
cd "${0:A:h}/.."
probe=build/noborder-probe
reports="$HOME/Library/Logs/DiagnosticReports"
loops=${1:-1}
count=${POISON_CALLS:-200}
apps=${POISON_APPS:-1}
hostargs=${POISON_ARGS:-}
retry=${POISON_RETRY:-0.5}
windows=${POISON_WINDOWS:-1}
buttons=${POISON_BUTTONS:-0}              # 1 = the cycle includes buttons-hidden (standardWindowButton:/setHidden:)
modes=(applied restored)
(( buttons )) && modes=(applied restored buttons-hidden restored)
[[ -x $probe && -x tests/hostapp ]] || { print "FAIL missing $probe or tests/hostapp"; exit 1 }

marker=$(mktemp /tmp/poison-marker.XXXXXX)   # reports newer than this belong to this run
trap 'rm -f $marker' EXIT

newcold() {   # fresh hostapp crash reports (after the marker) whose text has the cold.1 frame
    local f out=()
    for f in "$reports"/hostapp-*.ips(N); do
        [[ $f -nt $marker ]] && grep -q "CFRunLoopServiceMachPort.cold" "$f" && out+=$f
    done
    print -r -- "${(j. .)out}"
}

start_hosts() {   # -> hosts[], wids[] = POISON_WINDOWS per app, flattened
    hosts=() wids=()
    for n in {1..$apps}; do
        ./tests/hostapp $=hostargs > build/hostapp.$n.out &
        hosts+=$!
        for _ (1 2 3 4 5 6 7 8 9 10); do
            nwin=$(awk '$1=="max"||$1=="floating" {c++} END {print c+0}' build/hostapp.$n.out)
            (( nwin >= windows )) && break
            sleep 0.3
        done
        (( nwin >= windows )) || print "FAIL hostapp $n printed $nwin windows, wanted $windows"
        for wname in max floating; do
            wid=$(awk -v n="$wname" '$1==n {print $2}' build/hostapp.$n.out)
            [[ -n $wid ]] && wids+=$wid
        done
    done
}
stop_hosts() {
    for h in $hosts; do kill $h 2>/dev/null; wait $h 2>/dev/null; done
    hosts=() wids=()
}

call_engine() {   # call_engine <host> <wid> <mode>: one entry, retried on a busy app like the loop.
                  # retry=0 means one shot — the storm fires entries back-to-back like the product.
    local host=$1 wid=$2 mode=$3 out i
    local tries=8
    (( retry == 0 )) && tries=1
    for i in $(seq 1 $tries); do
        out=$($probe run $host $wid $mode)
        [[ "$out" == result=ok* ]] && { print -r -- "$out attempts=$i"; return 0; }
        (( retry > 0 )) && sleep $retry
    done
    print -r -- "$out attempts=$i"
    return 1
}

summary() {   # summary <loop> <ok> <total> <death 0|1>
    print -r -- "loop=$1 ok=$2/$3 alive=$((1-$4)) apps=$apps windows=$windows buttons=$buttons args='$hostargs' retry=$retry cold=$(newcold)"
}

for loop in {1..$loops}; do
    start_hosts
    ok=0 death=0
    for i in {1..$count}; do
        n=$(( i % apps + 1 ))
        wid=${wids[(( n - 1 )) * windows + (i % windows) + 1]}
        mode=${modes[(( (i - 1) % ${#modes[@]} )) + 1]}
        [[ "$(call_engine $hosts[$n] $wid $mode)" == result=ok* ]] && ok=$((ok+1))
        if (( i % 10 == 0 )); then          # focus flap: real AppKit work between entries
            for h in $hosts; do kill -CONT $h 2>/dev/null; done
            sleep 0.3
            for h in $hosts; do kill -WINCH $h 2>/dev/null; done
            sleep 0.3
        fi
        for h in $hosts; do
            if ! kill -0 $h 2>/dev/null; then
                death=1
                sleep 3                     # let ReportCrash write the .ips
                break
            fi
        done
        (( death )) && break
    done
    if (( death )); then
        sleep 3
        c=$(newcold)
        if [[ -n $c ]]; then
            print -r -- "REPRO hostapp died mid-loop: cold.1 in $c"
            stop_hosts
            exit 0
        fi
        print -r -- "CRASH-NOTRAP hostapp died with no cold.1 report; loop=$loop ok=$ok/$count"
        stop_hosts
        exit 1
    fi
    stop_hosts
    sleep 2                                  # reports for a death after the last call
    c=$(newcold)
    if [[ -n $c ]]; then
        print -r -- "REPRO hostapp died after the loop: cold.1 in $c; loop=$loop ok=$ok/$count"
        exit 0
    fi
    summary $loop $ok $count 0
done
print -r -- "NOREPRO $loops loop(s) x $count entries, no cold.1 trap: mechanism unproven — stop, re-examine"
exit 3
