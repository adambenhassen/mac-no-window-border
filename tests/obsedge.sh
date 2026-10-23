#!/bin/zsh
# P1f setHasShadow:-override edge cases. tests/hostapp only — NEVER a live app.
# Each scenario runs a fresh `hostapp obsedge` (driven over stdin) so the 4-slot class table and the
# installed methods start clean:
#   full     5 window classes managed: 4 overridden, the 5th left to the backstop; after teardown a
#            setHasShadow: on every class still works (an unrecorded override would jump into the
#            freed pages and crash the host).
#   own      a class with its OWN setHasShadow: keeps it through install and teardown.
#   kvo      a window whose hasShadow is KVO-observed is still forced NO at the setter.
#   reopen   a closed managed window's same-class successors keep their shadow.
#   swizzle  a swizzle stacked on the override survives teardown, and the pages stay mapped.
#   intent   restore hands back the app's own latest setHasShadow: request, not the apply snapshot.
set -u
source "${0:A:h}/no-noborder.sh"
cd "$(dirname "$0")/.."
host=./tests/hostapp
probe=./build/noborder-probe
tool=./build/noborder-tool
[[ -x $host && -x $probe && -x $tool ]] || { echo "build first (make probe testtools)"; exit 1; }
out=$(mktemp -d /tmp/obsedge.XXXXXX)
# BlobClient install/adopt scenarios (async, barrier) persist an agent registry; point it at a temp
# file so the tests never touch the real controller's registry in ~/Library/Application Support.
export NOBORDER_REGISTRY_PATH=$out/registry.json
fail=0
typeset -A W
only=("$@")

pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { [[ "$2" == "$3" ]] && pass "$1 ($2)" || bad "$1: got '$2', want '$3'"; }

# start <scenario>: a fresh obsedge host fed through a FIFO on fd 3. Scenario names given as
# arguments run only those.
start() {
  (( ${#only} > 0 && ! ${only[(Ie)$1]} )) && return 1
  echo "== $1 =="
  pkill -f 'tests/hostapp' 2>/dev/null; sleep 0.5
  rm -f $out/in; mkfifo $out/in
  log=$out/$1.out
  $host obsedge < $out/in > $log 2>&1 &
  HP=$!
  exec 3> $out/in
  sleep 2
  kill -0 $HP 2>/dev/null || { bad "host launch: $(cat $log)"; return 1; }
}
# ask <command...>: send one command, print its answer (without the seq). The seq lives in a file:
# callers run ask inside $(...), a subshell that would drop a variable increment.
ask() {
  local n=$(( $(cat $out/seq 2>/dev/null || echo 0) + 1 ))
  echo $n > $out/seq
  print -r -- "$n $*" >&3
  local line=""
  for _ in {1..50}; do
    line=$(grep -m1 "^$n " $log) && break
    sleep 0.1
  done
  print -r -- "${line#$n }"
}
open() { local r=$(ask open $1 $2); W[$1]=${r##* }; }
shadow() { local r=$(ask $1 $2 ${3:-}); print -r -- "${r##*=}"; }
count() { ask count | grep -o "$1=[0-9]*" | cut -d= -f2; }
install() {
  $probe agent-install $HP > $out/install.out 2>&1
  grep -q "result=ok.*ready=1" $out/install.out || { bad "install: $(cat $out/install.out)"; return 1; }
  SVC=$(grep -o 'serviceName=[^ ]*' $out/install.out | cut -d= -f2)
  BASE=$(grep -o 'base=0x[0-9a-f]*' $out/install.out | sed 's/base=0x//')
}
# op apply|restore <name>: the tool's op, checked for its status.
op() {
  local want=$([[ $1 == apply ]] && echo "status=1 (applied)" || echo "status=2 (restored)")
  NOBORDER_RZ_NAME=$SVC $tool $HP op $1 ${W[$2]} 0 1 > $out/op.out 2>&1
  grep -q "$want" $out/op.out || bad "op $1 $2: $(tail -1 $out/op.out)"
}
# opraw apply|restore <name>: run the op, print the raw status number.
opraw() {
  NOBORDER_RZ_NAME=$SVC $tool $HP op $1 ${W[$2]} 0 1 > $out/op.out 2>&1
  grep -o 'status=[0-9]*' $out/op.out | head -1 | cut -d= -f2
}
uninstall() { $probe agent-uninstall $HP $BASE 2>&1; }
# alive: drive run-loop ticks after the pages are gone, then check the host is still there.
alive() {
  for _ in {1..8}; do ask count > /dev/null; sleep 0.1; done
  kill -0 $HP 2>/dev/null && pass "host survived post-teardown ticks" || bad "host crashed after teardown"
}
finish() { exec 3>&-; kill $HP 2>/dev/null; wait $HP 2>/dev/null; }

if start full; then
  for c in a b c d e; do open w$c $c; done
  install && {
    for c in a b c d e; do op apply w$c; done
    sleep 1.5
    for c in a b c d; do check "class $c overridden (forced NO)" "$(shadow set w$c 1)" 0; done
    check "5th class not overridden (table full)" "$(shadow set we 1)" 1
    check "recorded classes" "$($probe agent-dump $HP $BASE | grep -o 'shadowClassCount=0x[0-9a-f]*')" "shadowClassCount=0x4"
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    for c in a b c d e; do check "class $c after teardown" "$(shadow set w$c 1)" 1; done
    alive
  }
  finish
fi

if start own; then
  open o own
  install && {
    op apply o
    sleep 1
    before=$(count own)
    check "own setter keeps its shadow request (not overridden)" "$(shadow set o 1)" 1
    (( $(count own) > before )) && pass "own setHasShadow: still runs" || bad "own setHasShadow: was replaced"
    sleep 1
    check "backstop clears the own-class window" "$(shadow read o)" 0
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    before=$(count own)
    check "own class after teardown" "$(shadow set o 1)" 1
    (( $(count own) > before )) && pass "own setHasShadow: still runs after teardown" || bad "own setter lost after teardown"
    alive
  }
  finish
fi

if start kvo; then
  open k kvo
  install && {
    op apply k
    sleep 1
    check "KVO-observed window forced NO" "$(shadow set k 1)" 0
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    check "KVO-observed window after teardown" "$(shadow set k 1)" 1
    alive
  }
  finish
fi

if start reopen; then
  open r1 obs
  install && {
    op apply r1
    sleep 1
    check "managed window forced NO" "$(shadow set r1 1)" 0
    ask close r1 > /dev/null
    for i in 2 3 4 5 6; do open r$i obs; check "same-class successor r$i keeps its shadow" "$(shadow set r$i 1)" 1; done
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    alive
  }
  finish
fi

if start swizzle; then
  open s obs
  install && {
    op apply s
    sleep 1
    check "managed window forced NO" "$(shadow set s 1)" 0
    ask swizzle s > /dev/null
    check "stacked swizzle still reaches the override" "$(shadow set s 1)" 0
    check "swizzle calls" "$(count swizzle)" 1
    op restore s
    check "restore hands back the app's last request" "$(shadow read s)" 1
    r=$(uninstall)
    [[ $r == *"result=ok"* && $r == *"failure=kept-pages-stacked-swizzle"* ]] && pass "uninstall kept the pages" \
      || bad "uninstall: $r (want kept-pages-stacked-swizzle)"
    before=$(count swizzle)
    check "after teardown" "$(shadow set s 1)" 1
    (( $(count swizzle) > before )) && pass "the stacked swizzle survived teardown" \
      || bad "the stacked swizzle was dropped by teardown"
    alive
  }
  finish
fi

if start intent; then
  open i obs
  check "natural shadow" "$(shadow read i)" 1
  install && {
    op apply i
    sleep 1
    check "app asks YES while managed (forced NO)" "$(shadow set i 1)" 0
    op restore i
    check "restore hands back the app's YES" "$(shadow read i)" 1
    op apply i
    sleep 0.5
    check "app asks NO while managed (forced NO)" "$(shadow set i 0)" 0
    op restore i
    check "restore keeps the app's NO (the snapshot said YES)" "$(shadow read i)" 0
    # Third cycle, no app request: restore must use the first-apply snapshot (1), not the stale NO.
    op apply i
    sleep 0.5
    op restore i
    check "restore with no new request uses the snapshot (1), not the stale NO" "$(shadow read i)" 1
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    alive
  }
  finish
fi

if start retire; then
  # #3: a window applied (op==1) at teardown, under a stacked swizzle that keeps the pages, must
  # stop being forced — teardown retires the rows so our IMP becomes a pass-through.
  open t obs
  install && {
    op apply t
    sleep 1
    check "managed window forced NO" "$(shadow set t 1)" 0
    ask swizzle t > /dev/null
    r=$(uninstall)
    [[ $r == *"failure=kept-pages-stacked-swizzle"* ]] && pass "uninstall kept the pages" || bad "uninstall: $r"
    check "an op==1 row is no longer forced after teardown" "$(shadow set t 1)" 1
    alive
  }
  finish
fi

if start rows; then
  # Op-table eviction: 16 rows fill, a 17th apply is refused (table-full) while every row is a live
  # apply; once one row is restored (finished) the 17th apply reuses it.
  for i in $(seq 1 16); do open r$i obs; done
  install && {
    for i in $(seq 1 16); do op apply r$i; done
    open r17 obs
    check "17th apply refused while the table is full of applies" "$(opraw apply r17)" 7
    op restore r1
    check "17th apply reuses the finished restore row" "$(opraw apply r17)" 1
    sleep 1
    check "the evicted-into window is forced NO" "$(shadow set r17 1)" 0
    r=$(uninstall); [[ $r == *"result=ok"* && $r != *failure* ]] && pass "uninstall" || bad "uninstall: $r"
    alive
  }
  finish
fi

if start reclaim; then
  # A force-kill leaves a prior agent's override wired into a class (teardown never ran). A fresh
  # agent must RECOGNIZE that leftover (by the agent magic before its IMP) and reclaim it, not skip
  # it as a foreign setHasShadow:. Simulate with two agents in one host: A installs the override,
  # then B installs WITHOUT A being uninstalled, and must reclaim (shadowClassCount=1).
  open m obs
  install && {
    op apply m
    sleep 1
    check "agent A forces NO" "$(shadow set m 1)" 0
    SVC_A=$SVC; BASE_A=$BASE
    install && {                       # agent B, A still resident (its override stranded on the class)
      op apply m
      sleep 1
      scc=$($probe agent-dump $HP $BASE | grep -o 'shadowClassCount=0x[0-9a-f]*')
      check "agent B reclaimed the leftover override" "$scc" "shadowClassCount=0x1"
      check "still forced NO after reclaim" "$(shadow set m 1)" 0
      $probe agent-uninstall $HP $BASE > /dev/null 2>&1     # B restores the method
    }
    $probe agent-uninstall $HP $BASE_A > /dev/null 2>&1
    check "after both removed, shadow settable" "$(shadow set m 1)" 1
    alive
  }
  finish
fi

if start async; then
  # Async-adopt: a tiny stop budget forces the install to time out (entry enqueued, not yet run);
  # the client keeps the pages, reports pending, and a later poll adopts once the entry has run —
  # then an op confirms the adopted agent is live. This is the busy-target (Vivaldi) path.
  open m obs
  if ./build/noborder-probe agent-async $HP ${W[m]} > $out/async.out 2>&1; then
    r=$(grep -o 'sawPending=[a-z]*' $out/async.out)
    check "async-adopt timed out, then adopted + applied" "$r" "sawPending=true"
  else
    bad "async-adopt: $(cat $out/async.out)"
  fi
  finish
fi

if start barrier; then
  # Double-install barrier: client A installs and records itself; a fresh client B on the same pid
  # must ADOPT A's agent through the registry (same base, no second install) and drive it. This is the
  # relaunch-after-unclean-exit path that otherwise stacks a second observer in the target. A temp
  # registry keeps the real controller's untouched.
  open m obs
  if ./build/noborder-probe agent-barrier $HP ${W[m]} > $out/barrier.out 2>&1; then
    r="$(grep -o 'bAdopted=[a-z]*' $out/barrier.out) $(grep -o 'sameBase=[a-z]*' $out/barrier.out)"
    check "fresh client adopted the recorded agent (no 2nd install)" "$r" "bAdopted=true sameBase=true"
  else
    bad "agent-barrier: $(cat $out/barrier.out)"
  fi
  finish
fi

pkill -f 'tests/hostapp' 2>/dev/null
[[ $fail -eq 0 ]] && echo "obsedge: ALL PASS" || echo "obsedge: FAILURES"
exit $fail
