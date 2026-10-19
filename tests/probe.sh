#!/bin/zsh
# Check that build/noborder-probe exists, carries the debugger entitlement, and can get the
# task port of a live test app. Run by `make test`.
set -u
cd "${0:A:h}/.."
fail=0

if [[ ! -x build/noborder-probe ]]; then
    echo "FAIL probe missing: build/noborder-probe (make probe)"
    exit 1
fi

if ! codesign -d --entitlements - build/noborder-probe 2>&1 | grep -q "com.apple.security.cs.debugger"; then
    echo "FAIL probe entitlement: com.apple.security.cs.debugger not in the signature"
    fail=1
fi

./tests/hostapp > /dev/null &
host=$!
sleep 1
out=$(build/noborder-probe taskport $host)
kill $host
if [[ "$out" == "taskport $host ok" ]]; then
    echo "PASS probe taskport: $out"
else
    echo "FAIL probe taskport: got '$out'"
    fail=1
fi

exit $fail
