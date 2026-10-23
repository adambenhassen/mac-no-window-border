#!/bin/zsh
# P1a blob-agent acceptance (codex verdict 6 gates + codex landing-review gates),
# tests/hostapp only — NEVER a live app.
# The blob is hand-assembled arm64 installed into a plain hostapp by
# `noborder-probe agent-install` (two pages: code RX, state RW; the entry runs as a
# dispatched block on the app's main thread under the fault guard). The rendezvous
# client is build/noborder-tool. Same message shapes as tests/agent.sh (HELLO v2 96B,
# COMPLEX handshake, ping/ACK); the blob COPIES its send (19) where the linked agent
# MOVES (17).
# Gates: (1) install: result=ok ready=1; (2) handshake + 200 pings, p99 < 5000us;
# (3) second tool on one blob; (4) 10,000-ping distribution; (5) tool SIGKILL proven
# mid-run (unfinished): host survives, fresh rendezvous works; (6) duplicate install
# succeeds with a fresh per-install name, host unharmed, first blob keeps serving,
# send-right count stable; (7) boundary messages: sub-gate HELLO/pings rejected, ping44 processed, ACK to
# a departed tool's port recorded, unterminated name fails closed — no state damage; (8)
# tracking pump with the blob: survives and
# recovers; (9) fault-install: absorbed, ready=0, host RESPONSIVE (executor noop ok);
# (10) SIGTERM: clean exit, no new crash report.
set -u
source "${0:A:h}/no-noborder.sh"
typeset -F SECONDS
cd "${0:A:h}/.."
fail=0
out=build/blobagent
mkdir -p $out
host=./tests/hostapp
probe=build/noborder-probe
tool=build/noborder-tool
[[ -x $probe && -x $tool && -x $host ]] || { echo "FAIL build the tools first (make testtools probe)"; exit 1 }
start=$(date +%s)

hp=""
run_host() {
    $host "$@" > $out/host.out 2>&1 & hp=$!
}
kill_host() { [[ -n $hp ]] && { kill $hp 2>/dev/null; wait $hp 2>/dev/null; }; hp="" }
trap 'kill $hp 2>/dev/null' EXIT
alive() { kill -0 $hp 2>/dev/null; }
# state slot readers (base from the install line, agentPort from the dump)
slot() { $probe agent-dump $hp $base 2>/dev/null | command grep -oE "$1=0x[0-9a-f]+" | sed 's/.*0x//'; }
agent_port() { slot agentPort; }
srights() { $probe agent-portinfo $hp $1 2>/dev/null | command grep -oE "srights=[0-9]+" | cut -d= -f2; }
# The blob registers a per-install nonce rendezvous name (AgentInstaller); the installer reports
# it as `serviceName=` and the tool looks it up via NOBORDER_RZ_NAME. (The default,
# com.noborder.rz.<pid>, is the linked agent's name in tests/agent.sh.)
use_rzname() { export NOBORDER_RZ_NAME=$(command grep -oE "serviceName=[^ ]+" "$1" | head -1 | cut -d= -f2); }

# (1) install gate
run_host
sleep 1.2
$probe agent-install $hp > $out/install.out 2>&1; rc=$?
grep -q "result=ok entryDone=true ready=1" $out/install.out && [[ $rc == 0 ]] \
  && echo "PASS install: $(grep result= $out/install.out)" \
  || { echo "FAIL install: rc=$rc $(grep result= $out/install.out)"; fail=1; }
base=$(grep -oE "base=0x[0-9a-f]+" $out/install.out | sed 's/.*0x//')
use_rzname $out/install.out

# (2) handshake + 200 pings
$tool $hp 200 > $out/ping200.out 2>&1; rc=$?
grep -q "handshake ok" $out/ping200.out && grep -q "n=200 ok=200" $out/ping200.out && [[ $rc == 0 ]] \
  && echo "PASS handshake + 200 pings: $(tail -1 $out/ping200.out)" \
  || { echo "FAIL ping round: rc=$rc $(tail -2 $out/ping200.out)"; fail=1; }
p99=$(awk '/n=200 ok=200/{for(i=1;i<=NF;i++)if($i~/^p99_us=/){sub(/^p99_us=/,"",$i);print $i}}' $out/ping200.out)
[[ -n $p99 && $p99 -lt 5000 ]] && echo "PASS p99 ${p99}us < 5000us" \
  || { echo "FAIL p99 gate: '$p99'"; fail=1; }

# (3) second tool, same blob: no duplicate bootstrap, counter continues
$tool $hp 50 > $out/ping50.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/ping50.out && [[ $rc == 0 ]] \
  && echo "PASS second tool on same blob: $(tail -1 $out/ping50.out)" \
  || { echo "FAIL second round: rc=$rc $(tail -2 $out/ping50.out)"; fail=1; }

# (4) 10,000-ping latency distribution
$tool $hp 10000 > $out/ping10k.out 2>&1; rc=$?
grep -q "n=10000 ok=10000" $out/ping10k.out && [[ $rc == 0 ]] \
  && echo "PASS 10,000 pings: $(tail -1 $out/ping10k.out)" \
  || { echo "FAIL 10k round: rc=$rc $(tail -2 $out/ping10k.out)"; fail=1; }

# (5) tool SIGKILL, PROVEN mid-run: the tool is alive and its 100k round has not
# printed a final line when the -9 lands. Host survives, fresh rendezvous works.
$tool $hp 100000 > $out/kill.out 2>&1 & rp=$!
sleep 1
if kill -0 $rp 2>/dev/null && ! grep -q "n=100000" $out/kill.out; then
    kill -9 $rp 2>/dev/null
    echo "PASS tool killed mid-run (alive, no final line)"
else
    echo "FAIL kill was not mid-run (tool finished first)"; fail=1
    kill -9 $rp 2>/dev/null
fi
sleep 0.5
alive && echo "PASS blob host survives tool SIGKILL" \
  || { echo "FAIL host died with the tool"; fail=1; }
$tool $hp 50 > $out/afterkill.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/afterkill.out && [[ $rc == 0 ]] \
  && echo "PASS fresh rendezvous after tool kill: $(tail -1 $out/afterkill.out)" \
  || { echo "FAIL rendezvous after kill: rc=$rc $(tail -2 $out/afterkill.out)"; fail=1; }

# (6) duplicate install: the per-install nonce name (P1e) means a second install does NOT
# collide — it succeeds with a fresh name. The host must stay alive, the FIRST blob must keep
# serving under its own name (NOBORDER_RZ_NAME, left unchanged), and installing again must not
# grow the first agent's send-right count.
ap=$(agent_port)
sr_before=$(srights $ap)
$probe agent-install $hp > $out/dup.out 2>&1
alive && grep -q "result=ok entryDone=true ready=1" $out/dup.out \
  && echo "PASS duplicate install succeeds with a fresh name, host alive: $(grep -oE 'serviceName=[^ ]+' $out/dup.out)" \
  || { echo "FAIL duplicate install: $(grep result= $out/dup.out) alive=$(alive && echo yes || echo no)"; fail=1; }
$tool $hp 50 > $out/afterdup.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/afterdup.out && [[ $rc == 0 ]] \
  && echo "PASS first blob serves on after duplicate install: $(tail -1 $out/afterdup.out)" \
  || { echo "FAIL blob after duplicate: rc=$rc $(tail -2 $out/afterdup.out)"; fail=1; }
sr_after=$(srights $ap)
[[ -n $sr_before && $sr_before == $sr_after ]] \
  && echo "PASS send-right count stable across duplicate install ($sr_before)" \
  || { echo "FAIL send rights grew: $sr_before -> $sr_after"; fail=1; }

# (7) boundary messages, sent by the production tool AFTER its ping round and at the
# messages' real sizes (the delivered msgh_size is the send_size trap argument; the
# 2026-10-20 "kernel clamps later sends to 40" reading was the tool's latched pingMode,
# fixed 2026-10-21). Each forged message rides its own 10-ping round to the bootstrap
# LOOK-UP name; the counter and cbEntries deltas expose the callback's verdict:
# hello92 under the 96-byte HELLO gate — pure reject; ping36 and shortping32 under the
# 40-byte ping gate — reject; ping44 — processed, its ACK to the just-departed tool's
# port lands in errAck, host survives; unterm HELLO — token stored, scan fails closed
# (errHandshake=1), no handshake sent. A clean round follows.
h2d() { printf "%d" "0x${1:-0}"; }
# forge_round <mode> <label> <want-counter-delta>: 10-ping round + one forged message
forge_round() {
    local c0=$(h2d $(slot counter)) b0=$(h2d $(slot cbEntries))
    $tool $hp 10 forge-$1 > $out/forge_$1.out 2>&1; local rc=$?
    grep -q "forge $2 kr=0" $out/forge_$1.out && alive \
      || { echo "FAIL forge $2: rc=$rc $(grep forge $out/forge_$1.out)"; fail=1; return; }
    sleep 0.3
    local d=$(( $(h2d $(slot counter)) - c0 )) k=$(( $(h2d $(slot cbEntries)) - b0 ))
    [[ $d == $3 ]] \
      && echo "PASS forge $2: counter +$d = $3, callback counted $k" \
      || { echo "FAIL forge $2: counter +$d (want $3)"; fail=1; }
}
forge_round hello92 hello92 10      # under the 96 gate: the 10 pings ACK, the HELLO moves nothing
forge_round ping36 ping36 10        # under the 40 gate: reject
forge_round shortping shortping32 10
forge_round ping44 ping44 11        # >= 40: processed as a ping (+1); its ACK goes to the live round tool's port, kr 0
# ACK-to-departed-port: forge-first sends ping44 with NO handshake, so the blob ACKs to
# the last registered tool's port — that tool exited; the send kr must land in errAck.
$tool $hp forge-first-ping44 > $out/ffping44.out 2>&1; rc=$?
grep -q "forge-first ping44 kr=0" $out/ffping44.out && alive \
  && echo "PASS forged ping44 from a handshook-free sender, host alive" \
  || { echo "FAIL forge-first ping44: rc=$rc $(grep forge $out/ffping44.out)"; fail=1; }
sleep 0.3
errack=$(slot errAck)
[[ -n $errack && $errack != 0 ]] \
  && echo "PASS ACK to the departed tool's port recorded kr (errAck=$errack), host alive" \
  || { echo "FAIL errAck after dead-port ACK: $errack"; fail=1; }
# unterminated name: last, so its token/errHandshake marks are read undisturbed
c0=$(h2d $(slot counter))
$tool $hp 10 forge-unterm > $out/forge_unterm.out 2>&1; rc=$?
grep -q "forge unterminated-name kr=0" $out/forge_unterm.out && alive \
  && echo "PASS unterminated HELLO sent full size, host alive" \
  || { echo "FAIL unterm send: rc=$rc $(grep forge $out/forge_unterm.out)"; fail=1; }
sleep 0.3
token1=$(slot token)
errhs=$(slot errHandshake)
want1=$(printf "%x" $(( $(grep -oE "token [0-9]+" $out/forge_unterm.out | head -1 | awk '{print $2}') + 1 )))
# The token is published only after the name scan and look-up succeed (codex P1c review):
# a failed (unterminated-name) HELLO must leave the live session's token in place.
tok_keep=$(printf "%x" $(grep -oE "token [0-9]+" $out/forge_unterm.out | head -1 | awk '{print $2}'))
[[ $token1 == $tok_keep && $token1 != $want1 ]] \
  && echo "PASS failed HELLO left the session token untouched ($token1 = the last good HELLO's)" \
  || { echo "FAIL unterm token: $token1 (want kept $tok_keep, forged $want1)"; fail=1; }
[[ -n $errhs && $errhs == 1 ]] \
  && echo "PASS unterminated name failed closed (errHandshake=1, no handshake sent)" \
  || { echo "FAIL errHandshake after unterm: $errhs"; fail=1; }
[[ $(( $(h2d $(slot counter)) - c0 )) == 10 ]] \
  && echo "PASS unterm sent no handshake and no ACK (counter +10 = the round only)" \
  || { echo "FAIL counter moved by unterm beyond the round"; fail=1; }
$tool $hp 50 > $out/afterforge.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/afterforge.out && [[ $rc == 0 ]] \
  && echo "PASS blob recovers after boundary messages: $(tail -1 $out/afterforge.out)" \
  || { echo "FAIL blob after boundary messages: rc=$rc $(tail -2 $out/afterforge.out)"; fail=1; }
kill_host

# (8) tracking mode with the blob: install first (a startup pump starves the parked-loop
# executor), then SIGUSR1 starts NSMenuTrackingMode pumps. The blob's source is in
# commonModes and the pump's mode is not one (by hostapp design), so callbacks starve
# during a ~2 s session — the ping loop's 2 s per-ping deadline rides that out; the
# honest report is the round's p99/max plus survival, and recovery after.
run_host trackingsig
sleep 1.2
$probe agent-install $hp > $out/install3.out 2>&1
grep -q "result=ok entryDone=true ready=1" $out/install3.out \
  && echo "PASS install before pump: $(grep result= $out/install3.out)" \
  || { echo "FAIL install before pump: $(grep result= $out/install3.out)"; fail=1; }
base=$(grep -oE "base=0x[0-9a-f]+" $out/install3.out | sed 's/.*0x//')
use_rzname $out/install3.out
$tool $hp 100 > $out/pretig.out 2>&1; rc=$?
grep -q "n=100 ok=100" $out/pretig.out && [[ $rc == 0 ]] \
  && echo "PASS baseline round before pump: $(tail -1 $out/pretig.out)" \
  || { echo "FAIL baseline round: rc=$rc $(tail -2 $out/pretig.out)"; fail=1; }
# Signals spaced past the ~2 s session length: while main is in the pump the signal
# source is queued and DispatchSource coalesces — tight bursts give one session, not three.
( for _ in 1 2 3; do kill -USR1 $hp 2>/dev/null; sleep 2.6; done ) & sigs=$!
$tool $hp 100 > $out/tracking.out 2>&1; rc=$?
wait $sigs 2>/dev/null
echo "note pump round rc=$rc: $(tail -1 $out/tracking.out)"
alive && echo "PASS blob host alive over tracking pump" \
  || { echo "FAIL host died during tracking"; fail=1; }
sessions=$(command grep -c "tracking session" $out/host.out)
[[ $sessions -ge 3 ]] && echo "PASS tracking sessions ran: $sessions" \
  || { echo "FAIL tracking sessions ran: $sessions (want >= 3)"; fail=1; }
$tool $hp 50 > $out/aftertracking.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/aftertracking.out && [[ $rc == 0 ]] \
  && echo "PASS blob recovers after tracking pump: $(tail -1 $out/aftertracking.out)" \
  || { echo "FAIL blob after tracking: rc=$rc $(tail -2 $out/aftertracking.out)"; fail=1; }
kill_host

# (9) fault-install: the guard absorbs, ready stays 0, and the host is RESPONSIVE —
# proven by running a noop script on its main thread, not just kill -0.
run_host
sleep 1.2
$probe agent-install-fault $hp > $out/fault.out 2>&1; rc=$?
grep -q "result=faulted entryDone=false ready=0" $out/fault.out && [[ $rc == 0 ]] \
  && echo "PASS fault-install absorbed: $(grep result= $out/fault.out)" \
  || { echo "FAIL fault-install: rc=$rc $(grep result= $out/fault.out)"; fail=1; }
wid=$(head -1 $out/host.out | awk '{print $2}')
$probe run $hp $wid noop > $out/responsive.out 2>&1; rc=$?
grep -q "result=ok" $out/responsive.out && [[ $rc == 0 ]] \
  && echo "PASS host responsive after fault-install: $(cat $out/responsive.out)" \
  || { echo "FAIL host not responsive after fault-install: rc=$rc $(cat $out/responsive.out)"; fail=1; }
kill_host

# (10) SIGTERM: clean exit, no NEW crash report
run_host
sleep 1.2
$probe agent-install $hp > $out/install4.out 2>&1
use_rzname $out/install4.out
$tool $hp 50 > $out/term.out 2>&1; rc=$?
[[ $rc == 0 ]] && echo "PASS pre-kill round: $(tail -1 $out/term.out)" \
  || { echo "FAIL pre-kill round: $(tail -1 $out/term.out)"; fail=1; }
kill -TERM $hp
deadline=$((SECONDS + 10))
while kill -0 $hp 2>/dev/null && (( SECONDS < deadline )); do sleep 0.2; done
if kill -0 $hp 2>/dev/null; then
    echo "FAIL host survived SIGTERM"; fail=1; kill -9 $hp 2>/dev/null
else
    echo "PASS host exits on SIGTERM"
fi
fresh=$(find ~/Library/Logs/DiagnosticReports -name 'hostapp*.ips' -newermt "@$start" 2>/dev/null | head -1)
[[ -z $fresh ]] && echo "PASS no new hostapp crash report" \
  || { echo "FAIL new crash report: $fresh"; fail=1; }
exit $fail
