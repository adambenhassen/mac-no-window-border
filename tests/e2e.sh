#!/bin/zsh
# End-to-end check of noborder.py against tests/hostapp only. Needs SIP disabled and no other
# noborder daemon running (only one debugger can hold Dock).
set -u
typeset -F SECONDS  # fractional, so short check timeouts are exact
cd "${0:A:h}/.."
out=build/e2e
mkdir -p $out
fail=0

probe() {  # probe <wid>: sets cols and px from the current screen state
    cols=$(./winscan --all | awk -F'\t' -v w=$1 '$1==w {print $(NF-1), $NF}')
    screencapture -x -o -l $1 $out/w.png
    px=$(tests/winpixels $out/w.png)
}

check() {  # check <label> <wid> <want winscan columns> <want winpixels output> [timeout s, default 15]
    local cols px deadline=$((SECONDS + ${5:-15}))
    while true; do
        probe $2
        [[ "$cols" == "$3" && "$px" == "$4" ]] && break
        (( SECONDS >= deadline )) && break
        sleep 0.5
    done
    if [[ "$cols" == "$3" && "$px" == "$4" ]]; then
        echo "PASS $1: $cols $px"
    else
        echo "FAIL $1: got '$cols' '$px', want '$3' '$4'"
        fail=1
    fi
}

tagcount() {  # tagcount <log> <wid>: number of "tagging" log lines that name <wid>
    awk -v w=$2 '$3=="tagging" { for (i = 4; i <= NF; i++) if ($i == w) { n++; break } } END { print n + 0 }' $1
}

strip() {  # strip <png>: capture a 40 px strip across the maximized window's left edge
    typeset x y w h
    read _ x y w h < <(tests/wbounds $max)
    # y+150 and h-400 keep the strip away from the corners and the titlebar, so what it can show is
    # the outline along the left edge — nothing else changes over that span.
    screencapture -x -o -R"$x,$(( y + 150 )),40,$(( h - 400 ))" $1
}

edge() {  # edge <a.png> <b.png>: the two edge columns of a strip comparison
    tests/pxband $1 $2 $edgeThr 0 2
}

edgeVerdict() {  # edgeVerdict <pxband line>: tall (edge changed over almost the whole strip),
                 # edge (both edge columns moved), clean (nothing at all differs)
    print -r -- "$1" | awk '
    {   h = 0; rows = -1; split("", c)
        for (i = 1; i <= NF; i++) {
            f = $i
            if (f ~ /^height=/)        { sub(/^height=/, "", f);        h = f + 0 }
            else if (f ~ /^rows_with_diff=/) { sub(/^rows_with_diff=/, "", f); rows = f + 0 }
            else { sub(/^cols=/, "", f)
                   if (f ~ /^[0-9]+:[0-9]+$/) { split(f, kv, ":"); c[kv[1]] = kv[2] + 0 } }
        }
        printf "tall=%d edge=%d clean=%d", (rows >= 0.9 * h), (c[0] > 0 && c[1] > 0), (rows == 0)
    }'
}

edgeThr=32

native_path() {  # the native engine, driven through the probe, verified on pixels
    typeset out=build/e2e
    [[ -f build/noborder-probe ]] || { echo "FAIL no build/noborder-probe (make probe)"; fail=1; return; }

    strip $out/pre.png
    log=$out/native.log
    build/noborder-probe apply $host $max > $log 2>&1
    grep -q "^applying $max" $log && echo "PASS native logs applying: $(head -1 $log)" \
        || echo "FAIL native did not log applying: $(head -3 $log)"
    grep -q "^applying $max" $log || fail=1

    # corners and rim, the same reading the legacy path uses
    probe_px
    [[ "$px" == "square=1 rim=0" ]] && echo "PASS native applied on pixels: $px" \
        || { echo "FAIL native applied on pixels: got '$px', want 'square=1 rim=0'"; fail=1; }
    # Spec finding 3: winscan's shadow column keeps reporting a shadow after the outline is gone. It
    # is printed here to show the native path never consults it: every decision above is pixels.
    echo "note winscan after native apply (not a signal): $(./winscan --all | awk -F'\t' -v w=$max '$1==w {print $(NF-1), $NF}')"

    # The outline itself: the left edge of the window, over almost the whole strip height.
    strip $out/applied.png
    band=$(edge $out/pre.png $out/applied.png)
    verdict=$(edgeVerdict $band)
    [[ "$verdict" == "tall=1 edge=1 clean=0" ]] && echo "PASS native changed the outline: $band" \
        || { echo "FAIL native outline unchanged: $band ($verdict)"; fail=1; }

    build/noborder-probe restore $host $max > $out/native-restore.log 2>&1
    grep -q "^restoring $max" $out/native-restore.log && echo "PASS native logs restoring: $(head -1 $out/native-restore.log)" \
        || { echo "FAIL native did not log restoring: $(head -3 $out/native-restore.log)"; fail=1; }
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS native restored on pixels: $px" \
        || { echo "FAIL native restored on pixels: got '$px', want 'square=0 rim=1'"; fail=1; }
    strip $out/restored.png
    band=$(edge $out/pre.png $out/restored.png)
    verdict=$(edgeVerdict $band)
    [[ "$verdict" == *"clean=1"* ]] && echo "PASS native restore returns the original edge: $band" \
        || { echo "FAIL native restore left the edge changed: $band ($verdict)"; fail=1; }

    # Review Focus: a target that is not an AppKit app. It has no window to check, so the assertion
    # is that the engine says why it stopped, and that hostapp's window is left as it was.
    tests/plainrunloop > $out/plain.txt & plain=$!
    for _ in {1..20}; do [[ -s $out/plain.txt ]] && break; sleep 0.25; done
    build/noborder-probe apply $plain 4242 > $out/plain.log 2>&1
    grep -q "skipped (not AppKit) $plain" $out/plain.log \
        && echo "PASS native skips a target that is not AppKit: $(head -1 $out/plain.log)" \
        || { echo "FAIL native on a non-AppKit target: $(head -3 $out/plain.log)"; fail=1; }
    kill $plain 2>/dev/null; wait $plain 2>/dev/null
    probe_px
    [[ "$px" == "square=0 rim=1" ]] && echo "PASS non-AppKit target left the window alone: $px" \
        || { echo "FAIL non-AppKit target changed the window: $px"; fail=1; }
}

probe_px() {  # probe_px: sets px from a window capture of the maximized window
    screencapture -x -o -l $max $out/w.png
    px=$(tests/winpixels $out/w.png)
}

host=""
daemon=""
parent=""
daemon2=""
cleanup() {
    [[ -n $parent ]] && kill -9 $parent 2>/dev/null
    for d in $daemon $daemon2; do  # SIGTERM restores; wait up to 30 s before killing the host
        kill -TERM $d 2>/dev/null || continue
        for _ in {1..60}; do kill -0 $d 2>/dev/null || break; sleep 0.5; done
        kill -9 $d 2>/dev/null
    done
    [[ -n $host ]] && kill $host 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if pgrep -f 'noborder.py' >/dev/null; then
    echo "stop the running noborder daemon first"
    exit 2
fi
tests/hostapp > $out/host.txt & host=$!
sleep 1.5
max=$(awk '$1=="max" {print $2}' $out/host.txt)
float=$(awk '$1=="floating" {print $2}' $out/host.txt)

export NOBORDER_GRACE_S=0  # the test app was just launched

if [[ "${NOBORDER_ENGINE:-}" == native ]]; then   # the native engine: no daemon, the probe drives it
    native_path
    exit $fail
fi

./noborder.py --pids $host > $out/daemon.log 2>&1 & daemon=$!
check "maximized applied" $max "[noshadow] [max]" "square=1 rim=0"
before=$(tagcount $out/daemon.log $max)
sleep 6
after=$(tagcount $out/daemon.log $max)
if (( after == before )); then
    echo "PASS no re-tagging of an applied window: $after tagging lines"
else
    echo "FAIL applied window re-tagged: $before -> $after tagging lines in 6 s"
    fail=1
fi
check "floating untouched" $float "[shadow] [nomax]" "square=0 rim=1"

kill -USR1 $host
check "un-maximized restored" $max "[shadow] [nomax]" "square=0 rim=1"
kill -USR2 $host
check "re-maximized applied (warm, within 5 s)" $max "[noshadow] [max]" "square=1 rim=0" 5

kill -TERM $daemon
for _ in {1..60}; do kill -0 $daemon 2>/dev/null || break; sleep 0.5; done
if kill -0 $daemon 2>/dev/null; then
    echo "FAIL daemon did not exit within 30 s; killing"
    kill -9 $daemon
    fail=1
fi
wait $daemon
code=$?
daemon=""  # reaped; never signal its pid again
check "restored on SIGTERM" $max "[shadow] [max]" "square=0 rim=1"
if [[ $code == 0 ]] && grep -q '^status: stopped' $out/daemon.log; then
    echo "PASS clean exit with 'status: stopped'"
else
    echo "FAIL exit code $code or no 'status: stopped' line"
    fail=1
fi

# The app reads the daemon's output through a pipe. When the app dies, the daemon must still
# restore every window although the pipe has no reader.
python3 -c 'import subprocess, sys
p = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(p.pid, flush=True)
for line in p.stdout:
    sys.stdout.buffer.write(line)
    sys.stdout.flush()' ./noborder.py --pids $host > $out/parent.log & parent=$!
for _ in {1..20}; do daemon2=$(head -n 1 $out/parent.log); [[ -n $daemon2 ]] && break; sleep 0.25; done
check "maximized applied under a piped parent" $max "[noshadow] [max]" "square=1 rim=0"
kill -9 $parent
wait $parent 2>/dev/null
killed=$SECONDS
while kill -0 $daemon2 2>/dev/null && (( SECONDS < killed + 15 )); do sleep 0.25; done
if kill -0 $daemon2 2>/dev/null; then
    echo "FAIL daemon did not exit within 15 s of its parent's death"
    fail=1
else
    daemon2=""
    printf "PASS daemon exited %.1f s after its parent's death\n" $((SECONDS - killed))
fi
left=$((killed + 15 - SECONDS))
check "restored after parent death" $max "[shadow] [max]" "square=0 rim=1" $(( left > 1 ? left : 1 ))
exit $fail
