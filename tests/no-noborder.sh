# Sourced by every hostapp test harness (and run standalone by the Makefile `test` target).
# NoBorder manages the maximized windows of EVERY app, tests/hostapp included, so a running NoBorder
# squares the test window mid-test and breaks the pixel/shadow/park checks that assume only the test
# drives it (confirmed 2026-10-23: an idle hostapp window was squared by the live app within ~1 s).
# Refuse to run while the app is up. `pgrep -x NoBorder` matches the app binary only, never the test
# binaries (noborder-probe / noborder-tool / noborder-e2e).
if pgrep -x NoBorder >/dev/null 2>&1; then
  print -u2 -- "ABORT: the NoBorder app is running (pid $(pgrep -x NoBorder | tr '\n' ' '))."
  print -u2 -- "It manages tests/hostapp's windows and will corrupt this test. Quit NoBorder, then re-run."
  exit 2
fi
