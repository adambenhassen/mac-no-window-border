#!/bin/zsh
# Checks the signed probe binary: it must carry the debugger entitlement, get task ports, find the
# test app's own main thread, and read that thread's parked/running state. These are the Mach
# operations the native engine is built on; they cannot run inside `swift test`, because SwiftPM's
# test bundle cannot carry the entitlement.
set -u
source "${0:A:h}/no-noborder.sh"
cd "${0:A:h}/.."
fail=0
probe=build/noborder-probe

note() { print -r -- "$1"; if [[ "$1" == FAIL* ]]; then fail=1; fi; }

if [[ ! -x $probe ]]; then
    note "FAIL probe missing: $probe (make probe)"
    exit 1
fi
if ! codesign -d --entitlements - $probe 2>&1 | grep -q "com.apple.security.cs.debugger"; then
    note "FAIL probe entitlement: com.apple.security.cs.debugger not in the signature"
fi

start_host() {  # start_host [args...] -> sets host, host_mainthread
    ./tests/hostapp $=1 > build/hostapp.out &
    host=$!
    for _ (1 2 3 4 5 6 7 8 9 10); do
        host_mainthread=$(awk '$1=="mainthreadid" {print $2}' build/hostapp.out)
        [[ -n $host_mainthread ]] && break
        sleep 0.3
    done
    [[ -n $host_mainthread ]] || note "FAIL hostapp printed no main thread id"
}

stop_host() { [[ -n $host ]] && kill $host 2>/dev/null; wait $host 2>/dev/null; host="" }

start_host ""
out=$($probe taskport $host)
[[ "$out" == "taskport $host ok" ]] && note "PASS probe taskport: $out" || note "FAIL probe taskport: '$out'"

out=$($probe mainthread $host)
if [[ "$out" == "mainthread $host $host_mainthread" ]]; then
    note "PASS probe mainthread is the app's own thread ($host_mainthread)"
else
    note "FAIL probe mainthread: got '$out', want 'mainthread $host $host_mainthread'"
fi

parked=0
for _ (1 2 3 4 5); do
    [[ "$($probe park $host)" == "park $host parked" ]] && parked=$((parked + 1))
    sleep 0.2
done
(( parked >= 1 )) && note "PASS probe park: idle app reads parked ($parked/5)" \
                  || note "FAIL probe park: idle app never read parked"

# What "parked" is, at the machine level: the thread waits *inside the kernel*, in the run loop's
# Mach call (run_state=3 is TH_WAIT). The executor has to end that call to run anything.
out=$($probe threadinfo $host)
[[ "$out" == *"run_state=3"* && "$out" == *"pc=mach_msg2_trap+"* ]] \
    && note "PASS probe threadinfo: a parked run loop waits in the kernel ($out)" \
    || note "FAIL probe threadinfo: wanted run_state=3 in mach_msg2_trap, got '$out'"
# The entry gate reads the same number: the executor only enters a thread the kernel says is asleep,
# because a thread that has run app code since its state was read has registers we do not have.
out=$($probe runstate $host)
[[ "$out" == *"runstate $host 3"* ]] \
    && note "PASS probe runstate: a parked app is asleep in the kernel ($out)" \
    || note "FAIL probe runstate: wanted runstate 3, got '$out'"
stop_host

start_host busy
asleep=0
for _ (1 2 3 4 5 6 7 8 9 10); do
    [[ "$($probe runstate $host)" != *" 3" ]] && asleep=$((asleep + 1))
    sleep 0.1
done
(( asleep >= 5 )) && note "PASS probe runstate: a busy app is not asleep ($asleep/10 samples not 3)" \
                  || note "FAIL probe runstate: a busy app read asleep too often ($asleep/10)"

notparked=0
for _ (1 2 3 4 5 6 7 8 9 10); do
    [[ "$($probe park $host)" != "park $host parked" ]] && notparked=$((notparked + 1))
    sleep 0.1
done
(( notparked >= 5 )) && note "PASS probe park: busy app reads not-parked ($notparked/10)" \
                     || note "FAIL probe park: busy app read parked too often ($notparked/10)"

kill -HUP $host
became=0
for _ (1 2 3 4 5 6 7 8 9 10); do
    [[ "$($probe park $host)" == "park $host parked" ]] && became=1 && break
    sleep 0.2
done
(( became )) && note "PASS probe park: app reads parked once it goes idle" \
             || note "FAIL probe park: app never read parked after going idle"
[[ "$($probe runstate $host)" == *"runstate $host 3"* ]] \
    && note "PASS probe runstate: an app that goes idle is asleep again" \
    || note "FAIL probe runstate: not asleep after going idle"
stop_host

exit $fail
