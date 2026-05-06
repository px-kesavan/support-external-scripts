#!/bin/bash
# Drives pod_health_check through the scenarios it has to discriminate:
#   1. healthy_non_ocp        - every pod Running, no waiters, low restarts
#   2. waiter_non_ocp         - multi-container Running pod, one container
#                               waiting (CrashLoopBackOff)
#   3. restarts_non_ocp       - container with >=5 restarts
#   4. px_backup_ocp_default  - OCP, px-backup pod unhealthy, Deployment still
#                               carries non-OCP securityContext (UID/GID 1000)
#                               -> RECOMMENDATION expected
#   5. px_backup_ocp_cleared  - OCP, px-backup pod unhealthy, securityContext
#                               cleared (chart installed with isOpenshift=true)
#                               -> no RECOMMENDATION
#   6. px_backup_ui_ocp       - OCP, px-backup-ui pod unhealthy (not the
#                               px-backup Deployment) -> no RECOMMENDATION
#
# Run from the repo root with:
#   bash px_post_install_check/tests/test_pod_health.sh

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
PXB_KC="$TMPDIR_TEST/pxb.kc"
touch "$PXB_KC"

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

# Run pod_health_check in a clean subshell driven by MOCK_PHC_* envvars.
# Echoes captured stdout+stderr.
run_phc() {
    local is_ocp="$1" pods="$2" run_as_user="$3" fs_group="$4"
    (
        export PATH="$MOCK_BIN:$PATH"
        export MOCK_PXB_KC="$PXB_KC" MOCK_APP_KC=""
        export MOCK_PHC_OCP="$is_ocp"
        export MOCK_PHC_PODS="$pods"
        export MOCK_PHC_RUN_AS_USER="$run_as_user"
        export MOCK_PHC_FS_GROUP="$fs_group"
        bash -c '
            source "$1"
            init_logging() { :; }
            NON_INTERACTIVE=true
            PXB_CLI_TOOL="kubectl"
            PXB_KUBECONFIG="$2"
            PXB_NAMESPACE="central"
            pod_health_check
        ' _test_runner "$SCRIPT" "$PXB_KC" 2>&1
    )
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        report "$name" true ""
    else
        report "$name" false "expected to contain: $needle"
        echo "----- captured output -----"
        echo "$haystack"
        echo "---------------------------"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        report "$name" true ""
    else
        report "$name" false "expected to NOT contain: $needle"
        echo "----- captured output -----"
        echo "$haystack"
        echo "---------------------------"
    fi
}

# ---- Scenario 1: healthy non-OCP ----
echo ""
echo "Scenario: healthy non-OCP"
PODS=$'px-backup-aaaa-bbbb|Running|px-backup~0~;\npx-backup-ui-cccc-dddd|Running|ui~1~;\n'
OUT=$(run_phc "false" "$PODS" "" "")
assert_contains     "$OUT" "PXB cluster is not OpenShift"                "non-ocp banner"
assert_contains     "$OUT" "All pods in 'central' look healthy."         "healthy summary"
assert_not_contains "$OUT" "[ERROR]"                                     "no errors"
assert_not_contains "$OUT" "RECOMMENDATION"                              "no recommendation"

# ---- Scenario 2: multi-container with one waiter, non-OCP ----
echo ""
echo "Scenario: multi-container waiter (non-OCP)"
PODS=$'px-backup-aaaa-bbbb|Running|px-backup~0~;sidecar~2~CrashLoopBackOff;\n'
OUT=$(run_phc "false" "$PODS" "" "")
assert_contains     "$OUT" "container 'sidecar' is waiting (reason: CrashLoopBackOff)" "waiter flagged"
assert_not_contains "$OUT" "RECOMMENDATION"                              "no recommendation (non-OCP)"

# ---- Scenario 3: high restart count, non-OCP ----
echo ""
echo "Scenario: high restart count (non-OCP)"
PODS=$'px-backup-aaaa-bbbb|Running|px-backup~7~;\n'
OUT=$(run_phc "false" "$PODS" "" "")
assert_contains     "$OUT" "container 'px-backup' has 7 restarts"        "restart warning"
assert_not_contains "$OUT" "RECOMMENDATION"                              "no recommendation (non-OCP)"

# ---- Scenario 4: OCP, px-backup unhealthy, default securityContext ----
echo ""
echo "Scenario: OCP px-backup unhealthy + runAsUser/fsGroup 1000"
PODS=$'px-backup-aaaa-bbbb|Pending|px-backup~0~ContainerCreating;\n'
OUT=$(run_phc "true" "$PODS" "1000" "1000")
assert_contains "$OUT" "OpenShift detected on PXB cluster."              "ocp banner"
assert_contains "$OUT" "Pod 'px-backup-aaaa-bbbb' in phase 'Pending'"    "unhealthy reported"
assert_contains "$OUT" "RECOMMENDATION: On OpenShift, install px-backup with --set isOpenshift=true." "recommendation fired"
assert_contains "$OUT" "runAsUser=1000, fsGroup=1000"                    "recommendation cites secctx"

# ---- Scenario 5: OCP, px-backup unhealthy, securityContext cleared ----
echo ""
echo "Scenario: OCP px-backup unhealthy + securityContext cleared"
PODS=$'px-backup-aaaa-bbbb|Pending|px-backup~0~ContainerCreating;\n'
OUT=$(run_phc "true" "$PODS" "" "")
assert_contains     "$OUT" "Pod 'px-backup-aaaa-bbbb' in phase 'Pending'" "unhealthy reported"
assert_not_contains "$OUT" "RECOMMENDATION"                              "no recommendation (secctx cleared)"

# ---- Scenario 6: OCP, only px-backup-ui unhealthy ----
echo ""
echo "Scenario: OCP px-backup-ui unhealthy (px-backup healthy)"
PODS=$'px-backup-aaaa-bbbb|Running|px-backup~0~;\npx-backup-ui-cccc-dddd|Running|ui~0~CrashLoopBackOff;\n'
OUT=$(run_phc "true" "$PODS" "1000" "1000")
assert_contains     "$OUT" "container 'ui' is waiting (reason: CrashLoopBackOff)" "ui waiter flagged"
assert_not_contains "$OUT" "RECOMMENDATION"                              "no recommendation (px-backup healthy)"

echo ""
echo "=========================================="
echo "  Summary: $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]] || exit 1
