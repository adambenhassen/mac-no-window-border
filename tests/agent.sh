#!/bin/zsh
# P1a-0 resident-transport acceptance (codex verdict 5 gates), tests/hostapp only.
# The rendezvous client is build/noborder-tool (the P1a binary shape that measures kr 0 on
# these sends; the probe's own sends answer 0x10000010 — matrix in
# .superpowers/sdd/2026-10-20-noborder-dispatch-entry/progress.md).
# Transport: mutual bootstrap registration (agent: "com.noborder.rz.<agent-pid>",
# tool: "com.noborder.tool.<tool-pid>"), plain HELLO {token,pid}, agent's COMPLEX
# handshake MOVing a SEND on its CFMachPort back to the tool's registered port,
# then ping (id 2001) / ACK (id 2002) over plain messaging. Zero task-port ops after
# bootstrap; the agent's CFMachPort callback executes the work directly (verdict 5).
# Gates: (1) handshake + 200 pings, ok==n, p99 < 5000us; (2) 10,000-ping latency
# distribution; (3) tool SIGKILL mid-ping: agent survives, fresh rendezvous works;
# (4) two rounds against one agent: one bootstrap, counter continues; (5) tracking:
# agent survives the NSMenuTrackingMode pump (honest starvation report); (6) SIGTERM:
# clean exit, no new crash report.
set -u
typeset -F SECONDS
cd "${0:A:h}/.."
fail=0
out=build/agent
mkdir -p $out
host=./tests/hostapp
probe=build/noborder-probe
tool=build/noborder-tool
[[ -x $probe && -x $tool && -x $host ]] || { echo "FAIL build the tools first (make testtools probe)"; exit 1 }
start=$(date +%s)

hp=""
run_host() {
    $host "$@" > $out/$1.host.out 2>&1 & hp=$!
}
kill_host() { [[ -n $hp ]] && { kill $hp 2>/dev/null; wait $hp 2>/dev/null; }; hp="" }
trap 'kill $hp 2>/dev/null' EXIT

# (1) handshake + 200 pings
run_host agent
sleep 1.2
$tool $hp 200 > $out/ping200.out 2>&1; rc=$?
grep -q "n=200 ok=200" $out/ping200.out && [[ $rc == 0 ]] \
  && echo "PASS handshake + 200 pings: $(tail -1 $out/ping200.out)" \
  || { echo "FAIL ping round: rc=$rc $(tail -2 $out/ping200.out)"; fail=1; }
p99=$(awk '/n=200 ok=200/{for(i=1;i<=NF;i++)if($i~/^p99_us=/){sub(/^p99_us=/,"",$i);print $i}}' $out/ping200.out)
[[ -n $p99 && $p99 -lt 5000 ]] && echo "PASS p99 ${p99}us < 5000us" \
  || { echo "FAIL p99 gate: '$p99'"; fail=1; }

# (4) second tool, same agent: no duplicate bootstrap, counter continues
$tool $hp 50 > $out/ping50.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/ping50.out && [[ $rc == 0 ]] \
  && echo "PASS second tool on same agent: $(tail -1 $out/ping50.out)" \
  || { echo "FAIL second round: rc=$rc $(tail -2 $out/ping50.out)"; fail=1; }
bootstraps=$(command grep -c "agent service" $out/agent.host.out)
[[ $bootstraps == 1 ]] && echo "PASS one bootstrap for two tools" \
  || { echo "FAIL bootstrap count: $bootstraps"; fail=1; }

# (2) 10,000-ping latency distribution
$tool $hp 10000 > $out/ping10k.out 2>&1; rc=$?
grep -q "n=10000 ok=10000" $out/ping10k.out && [[ $rc == 0 ]] \
  && echo "PASS 10,000 pings: $(tail -1 $out/ping10k.out)" \
  || { echo "FAIL 10k round: rc=$rc $(tail -2 $out/ping10k.out)"; fail=1; }

# (3) tool SIGKILL mid-ping: the agent survives, a fresh rendezvous works after it
$tool $hp 100000 > $out/kill.out 2>&1 & rp=$!
sleep 1
kill -9 $rp 2>/dev/null
sleep 0.5
kill -0 $hp 2>/dev/null && echo "PASS agent survives tool SIGKILL" \
  || { echo "FAIL agent died with the tool"; fail=1; }
$tool $hp 50 > $out/afterkill.out 2>&1; rc=$?
grep -q "n=50 ok=50" $out/afterkill.out && [[ $rc == 0 ]] \
  && echo "PASS fresh rendezvous after tool kill: $(tail -1 $out/afterkill.out)" \
  || { echo "FAIL rendezvous after kill: rc=$rc $(tail -2 $out/afterkill.out)"; fail=1; }
kill_host

# (5) tracking mode: honest report, the agent must survive the NSMenuTrackingMode pump
run_host tracking agent
sleep 1.2
$tool $hp 300 > $out/tracking.out 2>&1; rc=$?
echo "note tracking round rc=$rc: $(tail -1 $out/tracking.out)"
kill -0 $hp 2>/dev/null && echo "PASS agent alive over tracking pump" \
  || { echo "FAIL agent died during tracking"; fail=1; }
sessions=$(command grep -c "tracking session" $out/tracking.host.out)
[[ $sessions -ge 1 ]] && echo "PASS tracking sessions ran: $sessions" \
  || { echo "FAIL no tracking sessions ran"; fail=1; }
kill_host

# (6) SIGTERM: clean exit, no NEW crash report
run_host agent
sleep 1.2
$tool $hp 50 > $out/term.out 2>&1; rc=$?
[[ $rc == 0 ]] && echo "PASS pre-kill round: $(tail -1 $out/term.out)" \
  || { echo "FAIL pre-kill round: $(tail -1 $out/term.out)"; fail=1; }
kill -TERM $hp
deadline=$((SECONDS + 10))
while kill -0 $hp 2>/dev/null && (( SECONDS < deadline )); do sleep 0.2; done
if kill -0 $hp 2>/dev/null; then
    echo "FAIL agent survived SIGTERM"; fail=1; kill -9 $hp 2>/dev/null
else
    echo "PASS agent exits on SIGTERM"
fi
fresh=$(find ~/Library/Logs/DiagnosticReports -name 'hostapp*.ips' -newermt "@$start" 2>/dev/null | head -1)
[[ -z $fresh ]] && echo "PASS no new hostapp crash report" \
  || { echo "FAIL new crash report: $fresh"; fail=1; }
exit $fail
