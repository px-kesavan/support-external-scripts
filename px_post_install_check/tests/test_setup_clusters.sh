#!/bin/bash
# Drives px_post_install_check.sh through four cluster states by mocking
# the indicator services that setup_clusters keys off of:
#   1. all_present  - PXB-UI, stork-service, portworx-api all reachable
#   2. pxb_missing  - px-backup-ui Service absent on PXB cluster (fail-fast)
#   3. stork_missing - stork-service Service absent on app cluster (fail-fast)
#   4. pxe_missing  - portworx-api absent on app cluster (warn + continue)
#
# For each scenario the test asserts the exit code and key fragments of the
# captured output. Run from the repo root with:
#   bash px_post_install_check/tests/test_setup_clusters.sh

set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$THIS_DIR/../px_post_install_check.sh"
MOCK_BIN="$THIS_DIR/bin"

if [[ ! -x "$MOCK_BIN/kubectl" ]]; then
    chmod +x "$MOCK_BIN/kubectl"
fi
# Provide an 'oc' alias pointing at the same mock so derive_cli_tool sees both.
ln -sf kubectl "$MOCK_BIN/oc"

# Empty kubeconfig files are sufficient: validate_kubeconfig only tests for
# regular-file existence and that derive_cli_tool can run `version`.
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
PXB_KC="$TMPDIR_TEST/pxb.kc"
APP_KC="$TMPDIR_TEST/app.kc"
touch "$PXB_KC" "$APP_KC"

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

# Run setup_clusters under a given scenario in a clean subshell. Echoes:
#   <exit_code>\n<captured stdout+stderr>
run_scenario() {
    local pxb_ui_ns="$1" stork_ns="$2" pxe_ns="$3"
    local out rc
    out=$(
        export PATH="$MOCK_BIN:$PATH"
        export MOCK_PXB_KC="$PXB_KC" MOCK_APP_KC="$APP_KC"
        export MOCK_PXB_UI_NS="$pxb_ui_ns" MOCK_STORK_NS="$stork_ns" MOCK_PXE_NS="$pxe_ns"
        # Source under a child shell so `set -e` and `exit` stay scoped here.
        # Pass a sentinel as $0 so the sourced script does not see
        # BASH_SOURCE[0] == $0 and therefore does not invoke main.
        bash -c '
            source "$1"
            # Disable file-based logging so test output stays on the parent stdout.
            init_logging() { :; }
            NON_INTERACTIVE=true
            PXB_KUBECONFIG="$2"
            APP_KUBECONFIG="$3"
            setup_clusters
        ' _test_runner "$SCRIPT" "$PXB_KC" "$APP_KC" 2>&1
    )
    rc=$?
    printf '%s\n' "$rc"
    printf '%s' "$out"
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        report "$name" true ""
    else
        report "$name" false "expected to contain: $needle"
    fi
}

run_case() {
    local label="$1" pxb_ui="$2" stork="$3" pxe="$4" expected_rc="$5"
    shift 5
    echo ""
    echo "Scenario: $label"
    local raw rc body
    raw=$(run_scenario "$pxb_ui" "$stork" "$pxe")
    rc="${raw%%$'\n'*}"
    body="${raw#*$'\n'}"
    if [[ "$rc" == "$expected_rc" ]]; then
        report "exit code = $expected_rc" true ""
    else
        report "exit code = $expected_rc" false "got rc=$rc"
        echo "----- captured output -----"
        echo "$body"
        echo "---------------------------"
    fi
    while [[ $# -gt 0 ]]; do
        assert_contains "$body" "$1" "output contains '$1'"
        shift
    done
}

run_case "all components present" \
    "central" "kube-system" "portworx" 0 \
    "PXB namespace : central" \
    "Stork namespace: kube-system" \
    "PXE installed : true"

run_case "PX-Backup missing on PXB cluster" \
    "" "kube-system" "portworx" 2 \
    "PX-Backup is not installed on this cluster"

run_case "Stork missing on app cluster" \
    "central" "" "portworx" 2 \
    "Stork is not installed on this cluster"

run_case "PXE missing on app cluster (optional)" \
    "central" "kube-system" "" 0 \
    "App cluster does not have Portworx installed" \
    "PXE installed : false" \
    "PX namespace  : <not installed>"

echo ""
echo "=========================================="
echo "  Summary: $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]] || exit 1
