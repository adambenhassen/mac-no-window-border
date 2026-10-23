#!/bin/zsh
# P1e/P1f border-observer + setHasShadow:-override acceptance. tests/hostapp only — NEVER a live app.
# Proves, without iTerm, that the injected agent stops a window's shadow (the iTerm "border outline")
# from ever turning on for a MANAGED window — iTerm re-enables hasShadow on every tab switch, and the
# only flash-free fix is to override setHasShadow: so YES becomes NO at the setter. Also proves the
# override leaves NON-managed windows alone, and that removing the agent restores the method cleanly
# (no crash on a later shadow change — the critical P1f/P1d teardown hazard).
#
# obsreg's windows are an NSWindow subclass (so class_addMethod lands, as on iTerm's window classes).
# SIGUSR1 sets hasShadow=YES on both max (managed) and other (not managed) and reads back
# SYNCHRONOUSLY: max=0 proves the override forced it at the setter (not the later observer); other=1
# proves non-managed windows keep their shadow.
set -u
source "${0:A:h}/no-noborder.sh"
cd "$(dirname "$0")/.."
host=./tests/hostapp
probe=./build/noborder-probe
tool=./build/noborder-tool
[[ -x $host && -x $probe && -x $tool ]] || { echo "build first (make probe testtools)"; exit 1; }
out=$(mktemp -d /tmp/obsflash.XXXXXX)
fail=0
pkill -f 'tests/hostapp' 2>/dev/null; sleep 1

$host obsreg > $out/host.out 2>&1 &
HP=$!; sleep 3
kill -0 $HP 2>/dev/null || { echo "FAIL host launch"; cat $out/host.out; exit 1; }
WID=$(grep '^max ' $out/host.out | awk '{print $2}')
echo "host pid=$HP wid=$WID"

# Set hasShadow=YES on both windows and read back synchronously; return "<max> <other>".
setread() { kill -USR1 $HP; sleep 0.5; grep 'shadow set' $out/host.out | tail -1 | sed 's/.*max=\([0-9]\) other=\([0-9]\)/\1 \2/'; }

echo "== (1) control: no agent — a set shadow holds on both windows =="
r=$(setread)
[[ "$r" == "1 1" ]] && echo "PASS control max=1 other=1" || { echo "FAIL control got '$r' (want '1 1')"; fail=1; }

echo "== (2) install the agent =="
$probe agent-install $HP > $out/install.out 2>&1
grep -q "result=ok.*ready=1" $out/install.out && echo "PASS install ready=1" \
  || { echo "FAIL install: $(cat $out/install.out)"; fail=1; }
SVC=$(grep -o 'serviceName=[^ ]*' $out/install.out | cut -d= -f2)
BASE=$(grep -o 'base=0x[0-9a-f]*' $out/install.out | sed 's/base=0x//')

echo "== (3) apply, then let the observer install the setHasShadow: override =="
NOBORDER_RZ_NAME=$SVC $tool $HP op apply $WID 0 1 > $out/op.out 2>&1
grep -q "status=1 (applied)" $out/op.out && echo "PASS apply status" \
  || { echo "FAIL apply: $(tail -1 $out/op.out)"; fail=1; }
sleep 1   # the observer fires ~20/s and installs the override on max's class

echo "== (4) the override forces a managed window's setHasShadow:YES to NO, synchronously =="
r=$(setread)
[[ "$r" == "0 1" ]] && echo "PASS override max=0 (forced), other=1 (untouched)" \
  || { echo "FAIL got '$r' (want '0 1' — override not active or leaked to other)"; fail=1; }

echo "== (5) teardown restores the method (no crash, shadow settable again) =="
$probe agent-uninstall $HP $BASE > $out/uninstall.out 2>&1
grep -q "result=ok" $out/uninstall.out && echo "PASS uninstall result=ok" \
  || { echo "FAIL uninstall: $(cat $out/uninstall.out)"; fail=1; }
for i in $(seq 1 8); do kill -USR2 $HP 2>/dev/null; sleep 0.2; done   # drive run-loop ticks post-free
if kill -0 $HP 2>/dev/null; then echo "PASS host survived post-teardown ticks"
else echo "FAIL host crashed after teardown"; fail=1; fi
r=$(setread)
[[ "$r" == "1 1" ]] && echo "PASS post-teardown max=1 (override removed)" \
  || { echo "FAIL post-teardown got '$r' (want '1 1')"; fail=1; }

echo "== (6) REINSTALL: the override installs again though the method already exists =="
# After (5)'s teardown, max's class has an own setHasShadow: (= NSWindow's IMP), so class_addMethod
# now answers NO. A reinstall that only trusted that result would skip — and the flash would return
# silently on every NoBorder restart. The fix forces the IMP with method_setImplementation.
$probe agent-install $HP > $out/install2.out 2>&1
grep -q "result=ok.*ready=1" $out/install2.out && echo "PASS reinstall ready=1" \
  || { echo "FAIL reinstall: $(cat $out/install2.out)"; fail=1; }
SVC2=$(grep -o 'serviceName=[^ ]*' $out/install2.out | cut -d= -f2)
BASE2=$(grep -o 'base=0x[0-9a-f]*' $out/install2.out | sed 's/base=0x//')
NOBORDER_RZ_NAME=$SVC2 $tool $HP op apply $WID 0 1 > $out/op2.out 2>&1
sleep 1
r=$(setread)
[[ "$r" == "0 1" ]] && echo "PASS reinstall override max=0 (forced again)" \
  || { echo "FAIL reinstall got '$r' (want '0 1' — override did not reinstall)"; fail=1; }
$probe agent-uninstall $HP $BASE2 > $out/uninstall2.out 2>&1
grep -q "result=ok" $out/uninstall2.out && echo "PASS reinstall uninstall ok" \
  || { echo "FAIL reinstall uninstall: $(cat $out/uninstall2.out)"; fail=1; }

kill $HP 2>/dev/null
pkill -f 'tests/hostapp' 2>/dev/null
[[ $fail -eq 0 ]] && echo "obsflash: ALL PASS" || echo "obsflash: FAILURES"
exit $fail
