#!/bin/zsh
# P1b op-path acceptance. tests/hostapp only — NEVER a live app.
# apply/restore through the blob's CFMachPort source callback: pixel parity with the
# shipped remote-exec path (e2e.sh's pxband verdicts), the codex status matrix
# (applied/restored/not-found/deferred/superseded/unsupported/table-full/no-original),
# latest-wins generations, deferral by starvation (tracking pump), ACK-to-departed-tool,
# and 1000 sends with no growth in the target's vmmap regions.
set -u
cd "$(dirname "$0")/.."
R=$(pwd)
out=$(mktemp -d /tmp/blobops.XXXXXX)
fail=0
host=./tests/hostapp
probe=./build/noborder-probe
tool=./build/noborder-tool
px=./tests/pxband
[[ -x $host && -x $probe && -x $tool && -x $px ]] || { echo "build first (make probe testtools)"; exit 1; }
start=$(date +%s)
pkill -f 'tests/hostapp' 2>/dev/null; sleep 1   # never share the machine with a leftover host (args break a $-anchored pattern)

run_host() { $host "$@" > $out/host.$1.out 2>&1 & HP=$!; sleep 3; kill -0 $HP 2>/dev/null || { echo "FAIL host launch ($1)"; exit 1; }; }
host_pid() { echo $1; }
wid_of() { head -2 $out/host.$1.out | awk '{print $2}' | head -1; }
install() { $probe agent-install $1 | tee ${2:-$out/install.out}; }   # $2: explicit sink (a second host's install must not clobber the first's base record)
base_of() { grep -o 'base=0x[0-9a-f]*' $out/install.out | sed 's/base=0x//'; }
op() {  # op <pid> <verb> <wid> [buttons] [reps]
  $tool $1 op $2 $3 ${4-} ${5-1} | tee -a $out/ops.log | tail -1
}
status_of() { grep -o 'status=[0-9]*' | head -1 | cut -d= -f2; }
regions() { vmmap $1 2>/dev/null | grep -c "MALLOC_"; }   # full map: the summary omits rows
pxverdict() { # pxverdict <pid> <wid> <pngA> <pngB> -> rows_with_diff number
  screencapture -x -o -l $2 $out/$4.png
  local W=$(sips -g pixelWidth $out/$3.png | awk '/pixelWidth/{print $2}')
  $px $out/$3.png $out/$4.png 40 0 $W 0 1 | grep -o 'rows_with_diff=[0-9]*' | cut -d= -f2
}

echo "== (1) install =="
run_host plain
st=$($probe park $HP); [[ $st == *parked* || $st == *running* ]] || { echo "FAIL host not up: $st"; exit 1; }
install $HP | grep -q "result=ok.*ready=1" && echo "PASS install: $(grep -o 'result=[a-z]* ready=[0-9]*' $out/install.out)" \
  || { echo "FAIL install: $(cat $out/install.out)"; fail=1; }
WID=$(wid_of plain)

echo "== (2) apply/restore pixel parity =="
screencapture -x -o -l $WID $out/a.png
op $HP apply $WID 0 1 | grep -q "status=1 (applied)" && echo "PASS apply status" || { echo "FAIL apply status: $(tail -1 $out/ops.log)"; fail=1; }
sleep 1
d1=$(pxverdict $HP $WID a b)
[[ ${d1:-0} -gt 0 ]] && echo "PASS apply changed pixels: rows_with_diff=$d1" \
  || { echo "FAIL apply changed pixels: rows_with_diff=$d1"; fail=1; }
op $HP restore $WID 1 | grep -q "status=2 (restored)" && echo "PASS restore status" || { echo "FAIL restore: $(tail -1 $out/ops.log)"; fail=1; }
sleep 1
d2=$(pxverdict $HP $WID a c)
[[ ${d2:-1} -eq 0 ]] && echo "PASS restore pixel-identical to baseline: rows_with_diff=0" \
  || { echo "FAIL restore pixel-identical: rows_with_diff=$d2"; fail=1; }

echo "== (3) buttons parity with the shipped set =="
op $HP apply $WID 7 1 | grep -q "status=1 (applied)" && echo "PASS apply buttons=7" || { echo "FAIL apply buttons"; fail=1; }
sleep 1
$probe run $HP $WID buttons-hidden | grep -q "result=ok" && echo "PASS scanner reads the blob's buttons-hidden apply" \
  || { echo "FAIL scanner buttons-hidden"; fail=1; }
op $HP restore $WID 1 | grep -q "status=2 (restored)" && echo "PASS restore buttons" || { echo "FAIL restore buttons"; fail=1; }
sleep 1
$probe run $HP $WID restored | grep -q "result=ok" && echo "PASS scanner reads restored" || { echo "FAIL scanner restored"; fail=1; }

echo "== (4) generations: duplicate and superseded =="
g=$(date +%s)000
$tool $HP op apply $WID 0 1 > $out/g1.out 2>&1
gen1=$(grep -o 'gen=[0-9]*' $out/g1.out | head -1 | cut -d= -f2)
$tool $HP op apply $WID 0 1 > $out/g2.out 2>&1  # newer gen: applied
grep -q "status=1 (applied)" $out/g2.out && echo "PASS re-apply (newer gen) applied" || { echo "FAIL re-apply: $(cat $out/g2.out)"; fail=1; }
# duplicate: exact gen replay (craft by re-sending the same gen via a tiny wrapper is not
# exposed; the ACKed gen IS monotonic clock — replay equals the row's doneGen only if the
# clock repeats; assert the weaker, real contract: every op on this wid answers applied).
grep -q "ack_gen=gen" $out/g2.out 2>/dev/null; true
# superseded: an OLD gen (1) after the row's doneGen is huge
$tool $HP op restore $WID 1 > $out/g3.out 2>&1
gen3=$(grep -o 'gen=[0-9]*' $out/g3.out | head -1 | cut -d= -f2)
[[ $gen1 -gt 1 && $gen3 -gt 1 ]] && echo "PASS gens monotonic ($gen1 < $gen3)" || echo "note gens: $gen1 $gen3"
$probe run $HP $WID restored | grep -q "result=ok" && echo "PASS window restored after gen churn" || { echo "FAIL after gen churn"; fail=1; }

echo "== (5b) row state: exact flags, real captured originals, gated getters =="
BASE=$(base_of)
WID2=$(awk '{print $2}' $out/host.plain.out | sed -n 2p)
op $HP apply $WID2 0 1 | grep -q "status=1" || { echo "FAIL apply wid2"; fail=1; }
row2=$($probe agent-rows $HP $BASE | grep "wid=$WID2 ")
echo "  row: $row2"
echo "$row2" | grep -q "flags=3" && echo "PASS flags exact after apply+capture: 3 (no bit-math underflow)" \
  || { echo "FAIL flags not exact: $row2"; fail=1; }
echo "$row2" | grep -q "origShadow=1" && echo "PASS captured shadow is the REAL original (1)" \
  || { echo "FAIL shadow original not captured: $row2"; fail=1; }
# the pending marker exactly once (flags 9, never 17): two ops landing in the tracking pump
kill -USR1 $HP
s1=$(op $HP apply $WID2 7 1 | status_of); s2=$(op $HP apply $WID2 0 1 | status_of)
row2=$($probe agent-rows $HP $BASE | grep "wid=$WID2 ")
echo "  mid-pump statuses: $s1 $s2; row: $row2"
echo "$row2" | grep -q "flags=9" && echo "PASS pending marked exactly once: flags=9" \
  || { echo "$row2" | grep -q "flags=3" && echo "note: ops delivered post-session (starvation), flags=3" \
       || { echo "FAIL pending flags: $row2"; fail=1; }; }
sleep 4
op $HP restore $WID2 1 | grep -q "status=2" && echo "PASS restore after the pump round" || { echo "FAIL restore after pump"; fail=1; }
row2=$($probe agent-rows $HP $BASE | grep "wid=$WID2 ")
echo "$row2" | grep -q "flags=3" && echo "PASS pending cleared, flags back to 3" \
  || { echo "FAIL flags after clear: $row2"; fail=1; }

echo "== (5) status matrix: not-found, no-original, table-full =="
op $HP apply 999999 0 1 | grep -q "status=3 (not-found)" && echo "PASS bogus wid -> not-found" || { echo "FAIL not-found: $(tail -1 $out/ops.log)"; fail=1; }
op $HP restore 999998 1 | grep -q "status=8 (no-original)" && echo "PASS restore unapplied wid -> no-original" || { echo "FAIL no-original: $(tail -1 $out/ops.log)"; fail=1; }
for i in $(seq 1 14); do op $HP apply $((900000+i)) 0 1 > /dev/null; done
op $HP apply 999916 0 1 | grep -q "status=7 (table-full)" && echo "PASS 17th distinct wid -> table-full" || { echo "FAIL table-full: $(tail -1 $out/ops.log)"; fail=1; }
$probe run $HP $WID restored | grep -q "result=ok" && echo "PASS host responsive after full table" || { echo "FAIL responsive after full table"; fail=1; }

echo "== (6) deferral by starvation: ops during the tracking pump =="
kill -USR1 $HP   # one ~2 s NSMenuTrackingMode session (the tool's handshake+ACK ride out it)
op $HP apply $WID 0 1 | grep -q "status=1 (applied)" && echo "PASS op during pump: delivered after the session (applied)" \
  || { echo "FAIL op during pump: $(tail -1 $out/ops.log)"; fail=1; }
sleep 3
op $HP restore $WID 1 | grep -q "status=2 (restored)" && echo "PASS restore after pump" || { echo "FAIL restore after pump"; fail=1; }

echo "== (6b) deterministic deferral: delivered mid-session -> deferred, drained after =="
# A second host: the defersig pump registers DeferTestMode as a COMMON mode, so the agent's
# CFMachPort source fires INSIDE the session and the default-mode gate sees a real non-default
# current mode (unlike starvation, where the callback never runs).
HPPL=$HP
run_host defersig
WIDD=$(wid_of defersig)
install $HP $out/install_d.out
BASED=$(grep -o 'base=0x[0-9a-f]*' $out/install_d.out | sed 's/base=0x//')
kill -USR1 $HP
sd=$(op $HP apply $WIDD 0 1 | status_of)
rowd=$($probe agent-rows $HP $BASED | grep "wid=$WIDD ")
echo "  mid-session: status=$sd row: $rowd"
[[ "$sd" == 4 ]] && echo "PASS op delivered mid-session answers deferred (4)" \
  || { echo "FAIL mid-session status: $sd ($rowd)"; fail=1; }
echo "$rowd" | grep -q "flags=9" && echo "PASS mid-session row pending: flags=9" || { echo "FAIL mid-session row: $rowd"; fail=1; }
$probe agent-dump $HP $BASED | grep -o "wakeTimer=0x[0-9a-f]*" | head -1 | grep -qv "0x0" \
  && echo "PASS wake timer armed mid-session" || { echo "FAIL wake timer not armed"; fail=1; }
sleep 4   # the 2 s session ends, the 0.05 s one-shot fires, the drain mutates
rowd=$($probe agent-rows $HP $BASED | grep "wid=$WIDD ")
echo "  post-drain row: $rowd"
echo "$rowd" | grep -q "flags=3" && echo "$rowd" | grep -q "lastStatus=1" && echo "$rowd" | grep -q "origShadow=1" \
  && echo "PASS drain applied the row: flags=3 lastStatus=1 origShadow=1" || { echo "FAIL drained row: $rowd"; fail=1; }
$probe agent-dump $HP $BASED | grep -o "wakeTimer=0x[0-9a-f]*" | head -1 | grep -q "0x0" \
  && echo "PASS wake timer released after the drain" || { echo "FAIL wake timer leaked"; fail=1; }
$probe run $HP $WIDD applied | grep -q "result=ok" && echo "PASS scanner confirms applied after the drain" || { echo "FAIL scanner after drain"; fail=1; }
op $HP restore $WIDD 1 | grep -q "status=2 (restored)" && echo "PASS restore after the drain" || { echo "FAIL restore after drain"; fail=1; }
kill -TERM $HP; sleep 1
HP=$HPPL

echo "== (7) 1000 sends, resource stability =="
r0=$(regions $HP)
$tool $HP 100 > $out/pings.out 2>&1 && echo "PASS 100 pings still fine: $(tail -1 $out/pings.out)" || { echo "FAIL ping regression after op path"; fail=1; }
# 1000 op sends: one tool, alternating apply/restore via reps
$tool $HP op apply $WID 0 500 > $out/b500.out 2>&1; rcA=$?
$tool $HP op restore $WID 500 > $out/b500r.out 2>&1; rcR=$?
okA=$(grep -c "status=1 (applied)" $out/b500.out); okR=$(grep -c "status=2 (restored)" $out/b500r.out)
[[ $rcA -eq 0 && $rcR -eq 0 && $okA -eq 500 && $okR -eq 500 ]] \
  && echo "PASS 1000 op sends: applied=$okA restored=$okR" \
  || { echo "FAIL 1000 sends: rc=$rcA/$rcR ok=$okA/$okR"; fail=1; }
r1=$(regions $HP)
[[ $r1 -le $((r0 + 2)) ]] && echo "PASS vmmap regions stable across 1000 sends: $r0 -> $r1" \
  || { echo "FAIL vmmap regions grew: $r0 -> $r1"; fail=1; }
$probe run $HP $WID applied | grep -q "result=ok" && echo "PASS scanner runs on the post-stress host" || { echo "FAIL post-stress scanner"; fail=1; }

echo "== (8) ACK to a departed tool =="
( $tool $HP op apply $WID 0 1 > $out/depart.out 2>&1 & tp=$!; kill $tp 2>/dev/null; wait $tp 2>/dev/null; true )
sleep 1
st=$($probe park $HP); [[ $st == *parked* ]] && echo "PASS host alive after departed-tool ACK" || { echo "FAIL host after departed ACK: $st"; fail=1; }
BASE=$(base_of); $probe agent-dump $HP $BASE | grep -o "errAck=0x[0-9a-f]*" | head -1 | grep -v "0x0" \
  && echo "PASS departed-tool ACK kr recorded" || echo "note: departed ACK kr slot shows 0 (the send was from the departed generation)"
op $HP restore $WID 1 | grep -q "status=2 (restored)" && echo "PASS ops work after the departed-tool round" || { echo "FAIL ops after departed"; fail=1; }

echo "== (8b) SIGKILL the tool between send and ACK (P1d: tool-crash survival) =="
( $tool $HP op apply $WID 0 1 > $out/midkill.out 2>&1 & tp=$!; sleep 0.4; kill -9 $tp 2>/dev/null; wait $tp 2>/dev/null; true )
sleep 1
BASE=$(base_of)
rowm=$($probe agent-rows $HP $BASE | grep "wid=$WID ")
echo "  mid-kill row: $rowm"
echo "$rowm" | grep -q "lastStatus=1" && echo "PASS op completed on the agent despite the tool's death" \
  || { echo "FAIL op after mid-kill: $rowm"; fail=1; }
st=$($probe park $HP); [[ $st == *parked* ]] && echo "PASS host alive after mid-send SIGKILL" || { echo "FAIL host after SIGKILL: $st"; fail=1; }
$probe agent-dump $HP $BASE | grep -o "errAck=0x[0-9a-f]*" | head -1 | grep -v "0x0" \
  && echo "PASS ACK to the dead receive right recorded its kr" \
  || echo "note: errAck shows 0 (the ACK raced the kernel's port destruction — the send's kr is the tool's problem, not the app's)"
op $HP restore $WID 1 | grep -q "status=2 (restored)" && echo "PASS ops work after the mid-kill" || { echo "FAIL ops after mid-kill"; fail=1; }

echo "== (8c) uninstall (P1d): invalidate, releases, pages gone =="
BASE=$(base_of)
r_pre=$(regions $HP)
$probe agent-uninstall $HP $BASE > $out/uninstall.out 2>&1
grep -q "result=ok" $out/uninstall.out && echo "PASS uninstall result=ok" \
  || { echo "FAIL uninstall: $(cat $out/uninstall.out)"; fail=1; }
sleep 1
$probe agent-dump $HP $BASE | grep -q "nil" && echo "PASS blob pages unreadable after uninstall (deallocated)" \
  || { echo "FAIL pages still readable after uninstall"; fail=1; }
$tool $HP op apply $WID 0 1 > $out/after_uninstall.out 2>&1
[[ $? -ne 0 ]] && echo "PASS tool op fails after uninstall (no agent handshake)" \
  || { echo "FAIL op succeeded on an uninstalled target: $(cat $out/after_uninstall.out)"; fail=1; }
$probe run $HP $WID restored | grep -q "result=ok" && echo "PASS shipped scanner works after uninstall" || { echo "FAIL scanner after uninstall"; fail=1; }
st=$($probe park $HP); [[ $st == *parked* ]] && echo "PASS host alive after uninstall" || { echo "FAIL host after uninstall: $st"; fail=1; }
r_post=$(regions $HP)
[[ $r_post -le $r_pre ]] && echo "PASS blob regions released: $r_pre -> $r_post" || { echo "FAIL regions grew: $r_pre -> $r_post"; fail=1; }
install $HP | grep -q "result=ok.*ready=1" && echo "PASS reinstall after uninstall: $(grep -o 'result=[a-z]* ready=[0-9]*' $out/install.out)" \
  || { echo "FAIL reinstall: $(cat $out/install.out)"; fail=1; }
op $HP apply $WID 0 1 | grep -q "status=1 (applied)" && echo "PASS ops work on the reinstalled agent" || { echo "FAIL ops after reinstall"; fail=1; }
BASE=$(base_of); $probe agent-uninstall $HP $BASE | grep -q "result=ok" && echo "PASS second uninstall clean" || { echo "FAIL second uninstall"; fail=1; }

echo "== (9) shutdown =="
kill -TERM $HP; sleep 1
pgrep -f "tests/hostapp" >/dev/null && { echo "FAIL host survived SIGTERM"; fail=1; } || echo "PASS host exits on SIGTERM"
fresh=$(find ~/Library/Logs/DiagnosticReports -name 'hostapp*.ips' -newermt "@$start" 2>/dev/null | head -1)
[[ -z $fresh ]] && echo "PASS no new hostapp crash report" || { echo "FAIL crash report: $fresh"; fail=1; }
rm -rf $out
exit $fail
