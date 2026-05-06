#!/bin/bash
# Regression coverage for platform detection running under the script's set -e.
# A non-OCP app cluster makes `get clusterversion` return nonzero; detection
# must keep going and print best-effort facts instead of exiting after the
# "--- App cluster ---" header.

set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$THIS_DIR/../px_post_install_check.sh"
MOCK_BIN="$THIS_DIR/bin"

if [[ ! -x "$MOCK_BIN/kubectl" ]]; then
    chmod +x "$MOCK_BIN/kubectl"
fi
ln -sf kubectl "$MOCK_BIN/oc"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
APP_KC="$TMPDIR_TEST/app.kc"
PXB_KC="$TMPDIR_TEST/pxb.kc"
touch "$APP_KC" "$PXB_KC"

PASS=0
FAIL=0
report() {
    local name="$1" ok="$2" detail="$3"
    if [[ "$ok" == "true" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name -- $detail"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        report "$name" true ""
    else
        report "$name" false "expected to contain: $needle"
    fi
}

echo ""
echo "Scenario: non-OCP app cluster platform detection"
out=$(
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_APP_KC="$APP_KC" MOCK_PXB_KC="$PXB_KC"
    export MOCK_PLATFORM_NON_OCP=true
    bash -c '
        source "$1"
        init_logging() { :; }
        detect_platform_for_cluster "App cluster" "kubectl" "$2"
    ' _test_runner "$SCRIPT" "$APP_KC" 2>&1
)
rc=$?

if [[ "$rc" == "0" ]]; then
    report "exit code = 0" true ""
else
    report "exit code = 0" false "got rc=$rc"
    echo "----- captured output -----"
    echo "$out"
    echo "---------------------------"
fi

assert_contains "$out" "--- App cluster ---" "output contains app cluster header"
assert_contains "$out" "Distribution     : Vanilla Kubernetes" "output contains vanilla distribution"
assert_contains "$out" "Kubernetes ver   : v1.27.3" "output contains Kubernetes version"
assert_contains "$out" "Managed cluster  : Yes - Google GKE" "output contains managed-cluster detection"
assert_contains "$out" "Provider         : gce" "output contains provider detection"

echo ""
echo "=========================================="
echo "  Summary: $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]] || exit 1
