#!/bin/bash

# Portworx Backup Post-Install Validation Script
# version - 0.1
#
# Validates configuration after a PX-Backup deployment by inspecting both
# the PXB cluster (where px-backup runs) and the app/source cluster (where
# Stork and Portworx Enterprise run). Implements the Planned Post-Install
# Script Enhancements:
#   1. Proxy Configuration consistency across PXB / Stork / PXE
#   2. Object Storage Accessibility from PXB, Stork, and PXE pods
#
# It does not make any changes to either cluster.

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Globals populated wby CLI flags or the prompt helpers
PXB_CLI_TOOL=""
APP_CLI_TOOL=""
PXB_KUBECONFIG=""
APP_KUBECONFIG=""
PXB_NAMESPACE=""
PX_NAMESPACE=""
STORK_NAMESPACE=""

# Whether Portworx Enterprise is installed on the app cluster. PXE is
# optional; check_pxe_presence flips this off when 'portworx-api' Service
# is missing so PXE-specific validation is skipped downstream.
PXE_INSTALLED=true

# Non-interactive mode: when true, skip all prompts and fail loudly if a
# required value is missing or invalid.
NON_INTERACTIVE=false

# Extra object storage endpoints supplied via --endpoint flag.
declare -a EXTRA_ENDPOINTS=()

# Whether the BackupLocation S3 endpoint uses HTTPS with a self-signed (or
# privately-signed) certificate. When "y", the script runs an extra wiring
# check that validates the CA cert Secret + Volume + Env across PXB, Stork
# and PXE per the postmortem (PD-5633 / T-Mobile POC). Empty until the user
# answers the prompt or supplies --self-signed-s3 / --no-self-signed-s3.
SELF_SIGNED_S3=""

# Canonical proxy variable names per component. PXB and Stork use the
# standard un-prefixed forms; PXE on the StorageCluster uses PX_-prefixed
# HTTP/HTTPS variants to scope to the PX runtime, but keeps NO_PROXY
# un-prefixed.
PXB_EXPECTED_PROXY_VARS=("HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY")
STORK_EXPECTED_PROXY_VARS=("HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY")
PXE_EXPECTED_PROXY_VARS=("PX_HTTP_PROXY" "PX_HTTPS_PROXY" "NO_PROXY")

# Per-component lists of variable names that are wrong if seen on that
# component. Catches typos (PX_HTTPS_NOPROXY, PX_NO_PROXY) and PX-prefixed
# names used on the wrong side (or un-prefixed forms on PXE).
# Source: PD-5633 / T-Mobile POC.
PXB_INVALID_PROXY_VARS=("PX_HTTP_PROXY" "PX_HTTPS_PROXY" "PX_NO_PROXY" "PX_HTTPS_NOPROXY")
STORK_INVALID_PROXY_VARS=("PX_HTTP_PROXY" "PX_HTTPS_PROXY" "PX_NO_PROXY" "PX_HTTPS_NOPROXY")
PXE_INVALID_PROXY_VARS=("HTTP_PROXY" "HTTPS_PROXY" "PX_NO_PROXY" "PX_HTTPS_NOPROXY")

# Per-run bundle: every dump (log + ConfigMaps + Helm artifacts +
# StorageCluster YAML) lands inside $BUNDLE_DIR. After print_summary the
# directory is tarred to $BUNDLE_FILE and removed, leaving a single
# tar.gz that can be attached to a support ticket.
LOG_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BUNDLE_NAME="px-post-install-check_${LOG_TIMESTAMP}"
BUNDLE_DIR="/tmp/${BUNDLE_NAME}"
BUNDLE_FILE="/tmp/${BUNDLE_NAME}.tar.gz"
LOG_FILE="${BUNDLE_DIR}/run.log"

# Arrays to store warnings and errors for summary
declare -a WARNINGS=()
declare -a ERRORS=()

strip_colors() {
    # sed defaults to block-buffered output when writing to a file, so
    # output written near script-end may sit in sed's stdio buffer past
    # the point bundle_artifacts runs. Force line-buffering so the log
    # stays current. GNU uses `-u`, BSD/macOS uses `-l`.
    if sed --version >/dev/null 2>&1; then
        sed -u 's/\x1b\[[0-9;]*m//g'
    else
        sed -l 's/\x1b\[[0-9;]*m//g'
    fi
}

LOGGING_INITIALIZED=false

# Create the bundle directory and redirect stdout/stderr to both the
# terminal and a stripped log file inside it. Deferred to main() so the
# script can be sourced (e.g. by tests) without capturing the caller's
# stdout or creating a stray bundle dir on import.
init_logging() {
    mkdir -p "$BUNDLE_DIR"
    # Save the original stdout/stderr so finalize_logging can restore
    # them before bundle_artifacts tars the log file. Closing the pipe
    # feeding tee causes tee+strip_colors to receive EOF, flush, exit.
    exec 3>&1 4>&2
    exec > >(tee >(strip_colors >> "$LOG_FILE")) 2>&1
    LOGGING_INITIALIZED=true
}

# Restore the original fds. Process substitutions can't be waited on
# directly; closing the pipe causes the subshells to drain. The brief
# sleep gives the kernel time to commit those final writes before tar
# reads the file.
finalize_logging() {
    [[ "$LOGGING_INITIALIZED" == "true" ]] || return 0
    exec 1>&3 2>&4 3>&- 4>&-
    LOGGING_INITIALIZED=false
    sleep 0.3
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    WARNINGS+=("$msg")
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg"
    ERRORS+=("$msg")
}

print_section() {
    echo ""
    echo "=========================================="
    echo "  $1"
    echo "=========================================="
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

PX-Backup post-install validation. Inspects the PXB cluster and the app
cluster (Stork + Portworx Enterprise) for proxy, object-storage, OCP pod
health, KDMP cloud-snap distribution, and S3 self-signed cert issues.

The CLI tool (kubectl or oc) is auto-detected per cluster.

Options:
  --pxb-kubeconfig PATH   Kubeconfig for the PXB cluster (required)
  --app-kubeconfig PATH   Kubeconfig for the app/source cluster (required)
  --pxb-ns NAME           PX-Backup namespace on the PXB cluster
                          (default: central)
  --px-ns NAME            Portworx namespace on the app cluster
                          (default: portworx)
  --stork-ns NAME         Stork namespace on the app cluster
                          (default: same as --px-ns)
  --endpoint URL          Object-storage endpoint to test. Can be repeated.
  --self-signed-s3        Object-storage endpoint uses HTTPS with a self-
                          signed cert. Enables the CA-bundle wiring check
                          across PXB, Stork and PXE. Skips the prompt.
  --no-self-signed-s3     Object-storage endpoint does NOT use a self-signed
                          cert. Skips the wiring check and the prompt.
  --non-interactive, -y   Do not prompt. Fail loudly if a required value is
                          missing or invalid. Defaults are still applied.
  -h, --help              Show this help and exit.

Examples:
  Run interactively (you'll be prompted for kubeconfig paths):
    $(basename "$0")

  Fully non-interactive with two extra endpoints:
    $(basename "$0") --non-interactive \\
        --pxb-kubeconfig ~/pxb.yaml --app-kubeconfig ~/app.yaml \\
        --pxb-ns central --px-ns portworx --stork-ns portworx \\
        --endpoint https://s3.example.com \\
        --endpoint https://backup.internal:9000
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pxb-kubeconfig) PXB_KUBECONFIG="$2"; shift 2 ;;
            --app-kubeconfig) APP_KUBECONFIG="$2"; shift 2 ;;
            --pxb-ns)         PXB_NAMESPACE="$2"; shift 2 ;;
            --px-ns)          PX_NAMESPACE="$2"; shift 2 ;;
            --stork-ns)       STORK_NAMESPACE="$2"; shift 2 ;;
            --endpoint)       EXTRA_ENDPOINTS+=("$2"); shift 2 ;;
            --self-signed-s3)    SELF_SIGNED_S3="y"; shift ;;
            --no-self-signed-s3) SELF_SIGNED_S3="n"; shift ;;
            --non-interactive|-y) NON_INTERACTIVE=true; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)
                echo -e "${RED}[ERROR]${NC} Unknown argument: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

# Fail (non-interactive) or fall through to caller's prompt logic.
require_value() {
    local label="$1"
    local val="$2"
    if [[ -z "$val" && "$NON_INTERACTIVE" == "true" ]]; then
        echo -e "${RED}[ERROR]${NC} $label is required in --non-interactive mode" >&2
        exit 2
    fi
}


# Ensure user inputs y, Y, n, N only
validate_yes_no_input() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt" response
        if [[ "$response" == "y" ]] || [[ "$response" == "Y" ]]; then
            echo "y"
            return 0
        elif [[ "$response" == "n" ]] || [[ "$response" == "N" ]]; then
            echo "n"
            return 0
        else
            echo -e "${RED}[ERROR]${NC} Invalid input. Please enter 'y' or 'n'." >&2
        fi
    done
}

# Build a kubectl/oc command string with --kubeconfig appended when set.
# Usage: cmd=$(build_cmd "<cli_tool>" "<kubeconfig>"); $cmd get pods ...
build_cmd() {
    local cli="$1"
    local kc="$2"
    local out="$cli"
    if [[ -n "$kc" ]]; then
        out="$out --kubeconfig=$kc"
    fi
    echo "$out"
}

# Run a command with a hard wall-clock timeout (in seconds) and echo its
# stdout. Returns 124 on timeout (mirrors GNU `timeout`). Pure bash, so it
# works on macOS where neither `timeout` nor `gtimeout` ships by default.
# Stderr is suppressed so the helper can be used inside command substitution
# without leaking kubectl/oc warning chatter.
run_with_timeout() {
    local secs="$1"; shift
    local out_file rc
    out_file=$(mktemp 2>/dev/null) || out_file="/tmp/ppic_$$_$RANDOM"
    "$@" >"$out_file" 2>/dev/null &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null
      sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local wd=$!
    if wait "$pid" 2>/dev/null; then
        rc=0
    else
        rc=$?
        # 143 (SIGTERM) / 137 (SIGKILL) come from our watchdog -> report 124.
        case "$rc" in 143|137) rc=124 ;; esac
    fi
    kill -KILL "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    cat "$out_file"
    rm -f "$out_file"
    return "$rc"
}

# Auto-derive the CLI tool (kubectl or oc) for a given kubeconfig. Probes
# both binaries, then prefers oc when the cluster exposes the OpenShift API
# group. Echoes the chosen CLI on stdout. Returns 1 when neither works.
derive_cli_tool() {
    local kc="$1"
    local kubectl_ok=false oc_ok=false
    if command -v kubectl >/dev/null 2>&1 && \
       kubectl --kubeconfig="$kc" version --request-timeout=5s >/dev/null 2>&1; then
        kubectl_ok=true
    fi
    if command -v oc >/dev/null 2>&1 && \
       oc --kubeconfig="$kc" version --request-timeout=5s >/dev/null 2>&1; then
        oc_ok=true
    fi
    if ! $kubectl_ok && ! $oc_ok; then
        return 1
    fi
    if $kubectl_ok && ! $oc_ok; then
        echo "kubectl"; return 0
    fi
    if ! $kubectl_ok && $oc_ok; then
        echo "oc"; return 0
    fi
    # Both work: prefer oc on OpenShift clusters, kubectl otherwise.
    if kubectl --kubeconfig="$kc" api-resources --api-group=apps.openshift.io --no-headers 2>/dev/null | grep -q .; then
        echo "oc"
    else
        echo "kubectl"
    fi
}

# Validate that a kubeconfig file exists. Cluster reachability is verified
# later (in Phase 2 of setup_clusters) so the interactive prompt loop stays
# free of blocking apiserver round-trips.
validate_kubeconfig() {
    local kc="$1"
    kc="${kc/#\~/$HOME}"
    if [[ ! -f "$kc" ]]; then
        echo -e "${RED}[ERROR]${NC} File not found: $kc" >&2
        return 1
    fi
    echo "$kc"
    return 0
}

# Resolve a kubeconfig: validate preset if given, else prompt (no default).
# In non-interactive mode the preset is mandatory.
resolve_kubeconfig() {
    local label="$1"
    local preset="$2"
    local out
    if [[ -n "$preset" ]]; then
        if out=$(validate_kubeconfig "$preset"); then
            echo "$out"
            return 0
        fi
        [[ "$NON_INTERACTIVE" == "true" ]] && exit 2
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo -e "${RED}[ERROR]${NC} $label kubeconfig is required in non-interactive mode (use --pxb-kubeconfig / --app-kubeconfig)." >&2
        exit 2
    fi
    local kc_input
    while true; do
        read -p "[$label] Path to kubeconfig: " kc_input
        if [[ -z "$kc_input" ]]; then
            echo -e "${RED}[ERROR]${NC} A kubeconfig path is required." >&2
            continue
        fi
        if out=$(validate_kubeconfig "$kc_input"); then
            echo "$out"
            return 0
        fi
    done
}

# Find the namespace that hosts a given service. Echoes the first match,
# empty string when the service does not exist anywhere in the cluster.
find_ns_by_service() {
    local cmd="$1"
    local svc_name="$2"
    $cmd get svc -A -o jsonpath="{range .items[?(@.metadata.name=='$svc_name')]}{.metadata.namespace}{'\n'}{end}" 2>/dev/null \
        | head -1
}

# Verify the indicator service for a component exists somewhere in the
# cluster. Aborts the script (exit 2) when missing. Must be called outside
# command substitution so the exit propagates to the parent shell.
require_component_installed() {
    local label="$1"
    local cli="$2"
    local kc="$3"
    local svc_name="$4"
    local component="$5"
    local cmd discovered
    cmd=$(build_cmd "$cli" "$kc")
    discovered=$(find_ns_by_service "$cmd" "$svc_name")
    if [[ -z "$discovered" ]]; then
        print_error "[$label] $component is not installed on this cluster ('$svc_name' Service not found in any namespace). Aborting."
        exit 2
    fi
}

# Take raw user input for a namespace. Does not talk to the cluster, so it
# can be called in the input-gathering phase without producing intermixed
# discovery output. Cluster-side validation is done later by
# validate_namespace_with_svc_fallback.
prompt_namespace() {
    local label="$1"
    local default_ns="$2"
    local preset="$3"
    if [[ -n "$preset" ]]; then
        echo "$preset"
        return 0
    fi
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo "$default_ns"
        return 0
    fi
    local ns_input
    read -p "[$label] Namespace (default: $default_ns): " ns_input
    [[ -z "$ns_input" ]] && ns_input="$default_ns"
    echo "$ns_input"
}

# Validate that a namespace exists and hosts the anchor service. Falls back
# to the namespace where the service actually lives when the chosen namespace
# does not contain it. require_component_installed must have already been
# called so the cluster-wide absence case has been handled.
validate_namespace_with_svc_fallback() {
    local label="$1"
    local cli="$2"
    local kc="$3"
    local ns="$4"
    local svc_name="$5"
    local cmd
    cmd=$(build_cmd "$cli" "$kc")
    if $cmd -n "$ns" get svc "$svc_name" >/dev/null 2>&1; then
        echo "$ns"
        return 0
    fi
    print_info "[$label] Service '$svc_name' not in '$ns'. Searching cluster-wide..." >&2
    local discovered
    discovered=$(find_ns_by_service "$cmd" "$svc_name")
    print_info "[$label] Found '$svc_name' in namespace '$discovered'. Using that namespace." >&2
    echo "$discovered"
}

# Detect Portworx Enterprise on the app cluster via the 'portworx-api'
# Service. PXE is optional in this deployment topology, so absence is a
# warning, not a fatal error. Sets PXE_INSTALLED and, when PXE is present,
# resolves PX_NAMESPACE to the namespace hosting portworx-api (overriding
# any preset that points elsewhere).
check_pxe_presence() {
    local cmd ns
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    ns=$(find_ns_by_service "$cmd" "portworx-api")
    if [[ -z "$ns" ]]; then
        PXE_INSTALLED=false
        print_warning "App cluster does not have Portworx installed ('portworx-api' Service not found in any namespace)."
        print_warning "PXE-specific checks (PXE proxy env, PXE pod object-storage / TLS tests, KDMP cloud-snap) will be skipped."
        return 0
    fi
    PXE_INSTALLED=true
    if [[ -z "$PX_NAMESPACE" ]]; then
        print_info "Portworx Enterprise discovered in namespace '$ns'."
        PX_NAMESPACE="$ns"
    elif [[ "$ns" != "$PX_NAMESPACE" ]]; then
        print_info "Portworx Enterprise discovered in namespace '$ns' (overriding PX namespace '$PX_NAMESPACE')."
        PX_NAMESPACE="$ns"
    fi
}

setup_clusters() {
    print_section "Cluster Setup"
    print_info "PXB cluster: where px-backup is installed."
    print_info "App/source cluster: where Stork and Portworx Enterprise (PXE) run."
    [[ "$NON_INTERACTIVE" == "true" ]] && print_info "Running in non-interactive mode."
    echo ""

    # ---- Phase 1: collect every user input back-to-back -----------------
    # No discovery / info output is emitted between prompts so the caller
    # can supply everything up front, then walk away while the script runs.
    PXB_KUBECONFIG=$(resolve_kubeconfig "PXB cluster" "$PXB_KUBECONFIG")
    APP_KUBECONFIG=$(resolve_kubeconfig "App cluster" "$APP_KUBECONFIG")

    local pxb_ns_input app_stork_ns_input
    pxb_ns_input=$(prompt_namespace "PXB cluster - PX-Backup namespace" "central" "$PXB_NAMESPACE")
    app_stork_ns_input=$(prompt_namespace "App cluster - Stork namespace" "kube-system" "$STORK_NAMESPACE")

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        echo ""
        print_info "Enter additional object storage endpoints to test (one per line, press Enter on an empty line to finish):"
        local extra
        while true; do
            read -p "  Endpoint: " extra
            [[ -z "$extra" ]] && break
            EXTRA_ENDPOINTS+=("$extra")
        done

        # Self-signed S3 endpoint: gates the CA-bundle wiring check across
        # PXB / Stork / PXE. Skip the prompt when the user already passed
        # --self-signed-s3 or --no-self-signed-s3 on the command line.
        if [[ -z "$SELF_SIGNED_S3" ]]; then
            SELF_SIGNED_S3=$(validate_yes_no_input "  Does the BackupLocation S3 endpoint use HTTPS with a self-signed (or privately-signed) certificate? (y/n): ")
        fi
    fi
    echo ""

    # ---- Phase 2: validation, discovery, reporting ----------------------
    if ! PXB_CLI_TOOL=$(derive_cli_tool "$PXB_KUBECONFIG") || [[ -z "$PXB_CLI_TOOL" ]]; then
        print_error "Neither kubectl nor oc can reach the cluster using $PXB_KUBECONFIG"
        exit 2
    fi
    print_info "PXB cluster kubeconfig: $PXB_KUBECONFIG"
    print_info "PXB cluster CLI tool : $PXB_CLI_TOOL"

    if ! APP_CLI_TOOL=$(derive_cli_tool "$APP_KUBECONFIG") || [[ -z "$APP_CLI_TOOL" ]]; then
        print_error "Neither kubectl nor oc can reach the cluster using $APP_KUBECONFIG"
        exit 2
    fi
    print_info "App cluster kubeconfig: $APP_KUBECONFIG"
    print_info "App cluster CLI tool : $APP_CLI_TOOL"

    require_component_installed "PXB cluster" "$PXB_CLI_TOOL" "$PXB_KUBECONFIG" "px-backup-ui" "PX-Backup"
    require_component_installed "App cluster" "$APP_CLI_TOOL" "$APP_KUBECONFIG" "stork-service" "Stork"

    PXB_NAMESPACE=$(validate_namespace_with_svc_fallback "PXB cluster - PX-Backup namespace" "$PXB_CLI_TOOL" "$PXB_KUBECONFIG" "$pxb_ns_input" "px-backup-ui")

    # Detect PXE before reporting namespaces that depend on it. When PXE is
    # absent, PX_NAMESPACE stays unset and downstream PXE-specific checks are
    # skipped via PXE_INSTALLED.
    check_pxe_presence

    STORK_NAMESPACE=$(validate_namespace_with_svc_fallback "App cluster - Stork namespace" "$APP_CLI_TOOL" "$APP_KUBECONFIG" "$app_stork_ns_input" "stork-service")

    print_info "PXB namespace : $PXB_NAMESPACE"
    print_info "PX namespace  : ${PX_NAMESPACE:-<not installed>}"
    print_info "Stork namespace: $STORK_NAMESPACE"
    print_info "PXE installed : $PXE_INSTALLED"
    if [[ ${#EXTRA_ENDPOINTS[@]} -gt 0 ]]; then
        print_info "Extra endpoints to test: ${EXTRA_ENDPOINTS[*]}"
    fi
    # Non-interactive mode without an explicit flag: assume the endpoint is
    # not self-signed so the wiring check is skipped silently.
    [[ -z "$SELF_SIGNED_S3" ]] && SELF_SIGNED_S3="n"
    print_info "Self-signed S3 cert: $SELF_SIGNED_S3"
}

# ------------------------------------------------------------------
# Proxy Configuration Check
# ------------------------------------------------------------------

# Emit NAME=VALUE pairs (one per line) from the JSON env blob produced by
# our kubectl jsonpath template. Each item arrives on a single line in the
# form `{"name":"FOO","value":"bar"},` — splitting on `"` puts the name in
# field 4 and the value in field 8. Items with no value (or with `valueFrom`)
# come through with an empty $8 and are dropped to avoid noise.
flatten_env_pairs() {
    awk -F'"' '
        /"name"[[:space:]]*:.*"value"[[:space:]]*:/ {
            if ($8 != "") print $4 "=" $8
        }
    '
}

# Extract proxy-relevant env vars from a deployment-style env JSON blob on
# stdin. Outputs lines of the form: NAME=VALUE
extract_proxy_env() {
    local pairs
    pairs=$(flatten_env_pairs)
    if [[ -z "$pairs" ]]; then
        return 0
    fi
    echo "$pairs" | grep -E "^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|PX_HTTP[A-Z_]*|PX_NO_PROXY)=" || true
}

# Check a single component's env for invalid proxy variable names. The
# expected/invalid lists are passed as space-separated strings so callers
# can supply per-component vocabularies (PXB/Stork use the un-prefixed
# canonical names, PXE uses PX_HTTP_PROXY / PX_HTTPS_PROXY / NO_PROXY).
# Adds errors for any wrong names found.
check_invalid_proxy_names() {
    local component="$1"
    local env_lines="$2"
    local expected_str="$3"
    local invalid_str="$4"
    local invalid bad
    for bad in $invalid_str; do
        invalid=$(echo "$env_lines" | grep -E "^${bad}=" || true)
        if [[ -n "$invalid" ]]; then
            print_error "$component uses unsupported proxy variable name: $bad"
            print_error "  Expected one of: $expected_str (case-sensitive)"
            print_error "  Found: $invalid"
        fi
    done
}

# Pull the canonical proxy values from env_lines in the order specified by
# expected_str (space-separated). Echoes one line per variable; empty
# lines are printed for unset variables so positional comparison stays
# stable across components with different naming conventions.
extract_canonical_proxy() {
    local env_lines="$1"
    local expected_str="$2"
    local var val
    for var in $expected_str; do
        val=$(echo "$env_lines" | awk -F= -v v="$var" '$1==v {sub(/^[^=]*=/,""); print; exit}')
        echo "$val"
    done
}

# Returns 0 if env_lines defines at least one of the component's
# canonical proxy vars (passed as space-separated names).
has_any_canonical_proxy() {
    local env_lines="$1"
    local expected_str="$2"
    [[ -z "$env_lines" ]] && return 1
    local var pat=""
    for var in $expected_str; do
        if [[ -z "$pat" ]]; then pat="^${var}="; else pat="${pat}|^${var}="; fi
    done
    echo "$env_lines" | grep -qE "$pat"
}

# Get env JSON from a deployment's first container.
get_deployment_env_json() {
    local cmd="$1"
    local namespace="$2"
    local deployment="$3"
    $cmd -n "$namespace" get deployment "$deployment" \
        -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{"{\"name\":\""}{.name}{"\",\"value\":\""}{.value}{"\"},\n"}{end}' 2>/dev/null
}

# Collect PXB proxy env from the px-backup deployment.
collect_pxb_proxy_env() {
    local cmd
    cmd=$(build_cmd "$PXB_CLI_TOOL" "$PXB_KUBECONFIG")
    # px-backup is the canonical deployment name installed by the helm chart
    local deploy
    deploy=$($cmd -n "$PXB_NAMESPACE" get deployment -l app=px-backup \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$deploy" ]]; then
        deploy="px-backup"
    fi
    if ! $cmd -n "$PXB_NAMESPACE" get deployment "$deploy" >/dev/null 2>&1; then
        print_warning "PXB deployment '$deploy' not found in namespace '$PXB_NAMESPACE'. Skipping PXB proxy check."
        return 1
    fi
    get_deployment_env_json "$cmd" "$PXB_NAMESPACE" "$deploy" | extract_proxy_env
}

# Collect Stork proxy env from the stork deployment.
collect_stork_proxy_env() {
    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    local deploy
    deploy=$($cmd -n "$STORK_NAMESPACE" get deployment -l name=stork \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$deploy" ]]; then
        deploy="stork"
    fi
    if ! $cmd -n "$STORK_NAMESPACE" get deployment "$deploy" >/dev/null 2>&1; then
        print_warning "Stork deployment '$deploy' not found in namespace '$STORK_NAMESPACE'. Skipping Stork proxy check."
        return 1
    fi
    get_deployment_env_json "$cmd" "$STORK_NAMESPACE" "$deploy" | extract_proxy_env
}

# Collect PXE proxy env from the StorageCluster spec.env.
collect_pxe_proxy_env() {
    if [[ "$PXE_INSTALLED" != "true" ]]; then
        return 1
    fi
    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    if ! $cmd -n "$PX_NAMESPACE" get stc >/dev/null 2>&1; then
        print_warning "No StorageCluster found in namespace '$PX_NAMESPACE'. Skipping PXE proxy check."
        return 1
    fi
    $cmd -n "$PX_NAMESPACE" get stc \
        -o jsonpath='{range .items[0].spec.env[*]}{"{\"name\":\""}{.name}{"\",\"value\":\""}{.value}{"\"},\n"}{end}' 2>/dev/null \
        | extract_proxy_env
}

# Render the canonical proxy triple as a single comparable string. The
# expected_str argument selects which variable names to read; the slot
# order is preserved so PXE's PX_HTTP_PROXY value lines up with PXB's /
# Stork's HTTP_PROXY for cross-component comparison.
canonicalize_triple() {
    local env_lines="$1"
    local expected_str="$2"
    extract_canonical_proxy "$env_lines" "$expected_str"
}

proxy_check() {
    print_section "Proxy Configuration Check"

    if [[ "$PXE_INSTALLED" == "true" ]]; then
        print_info "Collecting proxy env vars from PXB, Stork and PXE..."
    else
        print_info "Collecting proxy env vars from PXB and Stork (PXE not installed)..."
    fi
    local pxb_env stork_env pxe_env
    pxb_env=$(collect_pxb_proxy_env || true)
    stork_env=$(collect_stork_proxy_env || true)
    pxe_env=$(collect_pxe_proxy_env || true)

    echo ""
    echo "--- PXB (px-backup) proxy env ---"
    if [[ -z "$pxb_env" ]]; then
        echo "  (none)"
    else
        echo "$pxb_env" | sed 's/^/  /'
    fi
    echo ""
    echo "--- Stork proxy env ---"
    if [[ -z "$stork_env" ]]; then
        echo "  (none)"
    else
        echo "$stork_env" | sed 's/^/  /'
    fi
    if [[ "$PXE_INSTALLED" == "true" ]]; then
        echo ""
        echo "--- PXE StorageCluster spec.env (proxy) ---"
        if [[ -z "$pxe_env" ]]; then
            echo "  (none)"
        else
            echo "$pxe_env" | sed 's/^/  /'
        fi
    fi
    echo ""

    # Flag invalid env var names per component. PXB / Stork accept the
    # un-prefixed canonical names; PXE on the StorageCluster requires
    # PX_HTTP_PROXY / PX_HTTPS_PROXY (PX-prefixed) and plain NO_PROXY.
    check_invalid_proxy_names "PXB"   "$pxb_env" \
        "${PXB_EXPECTED_PROXY_VARS[*]}"   "${PXB_INVALID_PROXY_VARS[*]}"
    check_invalid_proxy_names "Stork" "$stork_env" \
        "${STORK_EXPECTED_PROXY_VARS[*]}" "${STORK_INVALID_PROXY_VARS[*]}"
    if [[ "$PXE_INSTALLED" == "true" ]]; then
        check_invalid_proxy_names "PXE StorageCluster" "$pxe_env" \
            "${PXE_EXPECTED_PROXY_VARS[*]}" "${PXE_INVALID_PROXY_VARS[*]}"
    fi

    # If none of the components define any canonical proxy, treat as no-proxy
    # deployment and skip the consistency check.
    if ! has_any_canonical_proxy "$pxb_env"   "${PXB_EXPECTED_PROXY_VARS[*]}" \
        && ! has_any_canonical_proxy "$stork_env" "${STORK_EXPECTED_PROXY_VARS[*]}" \
        && ! has_any_canonical_proxy "$pxe_env"   "${PXE_EXPECTED_PROXY_VARS[*]}"; then
        print_info "No proxy variables configured on any component."
        print_info "Skipping cross-component proxy consistency check."
        return 0
    fi

    print_info "Comparing canonical proxy values across components..."
    local pxb_triple stork_triple pxe_triple
    pxb_triple=$(canonicalize_triple "$pxb_env"   "${PXB_EXPECTED_PROXY_VARS[*]}")
    stork_triple=$(canonicalize_triple "$stork_env" "${STORK_EXPECTED_PROXY_VARS[*]}")
    pxe_triple=$(canonicalize_triple "$pxe_env"   "${PXE_EXPECTED_PROXY_VARS[*]}")

    # Mismatch detection: only compare components that have at least one
    # value. Triples are positionally aligned (slot 1 = HTTP-equivalent,
    # slot 2 = HTTPS-equivalent, slot 3 = NO_PROXY) so PXE's PX_HTTP_PROXY
    # value is compared directly with PXB's / Stork's HTTP_PROXY.
    local mismatch=0
    if [[ -n "$pxb_triple" && -n "$stork_triple" && "$pxb_triple" != "$stork_triple" ]]; then
        print_warning "PXB and Stork have different canonical proxy values."
        mismatch=1
    fi
    if [[ -n "$pxb_triple" && -n "$pxe_triple" && "$pxb_triple" != "$pxe_triple" ]]; then
        print_warning "PXB and PXE have different canonical proxy values."
        mismatch=1
    fi
    if [[ -n "$stork_triple" && -n "$pxe_triple" && "$stork_triple" != "$pxe_triple" ]]; then
        print_warning "Stork and PXE have different canonical proxy values."
        mismatch=1
    fi

    if [[ $mismatch -eq 0 ]]; then
        print_info "Canonical proxy values are consistent across configured components."
    else
        if [[ "$PXE_INSTALLED" == "true" ]]; then
            print_warning "RECOMMENDATION: Align proxy values across PXB / Stork (HTTP_PROXY, HTTPS_PROXY, NO_PROXY) and PXE (PX_HTTP_PROXY, PX_HTTPS_PROXY, NO_PROXY)."
        else
            print_warning "RECOMMENDATION: Align HTTP_PROXY / HTTPS_PROXY / NO_PROXY across PXB and Stork."
        fi
    fi
}


# ------------------------------------------------------------------
# Object Storage Accessibility Check (TLS verification skipped)
# ------------------------------------------------------------------

# Pick a Ready pod matching a label on a cluster. Echoes the pod name.
pick_ready_pod() {
    local cmd="$1"
    local namespace="$2"
    local selector="$3"
    $cmd -n "$namespace" get pods -l "$selector" \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}' 2>/dev/null \
        | tr ' ' '\n' | head -1
}

# Strip scheme and trailing slashes/paths to get a host[:port] for curl tests.
endpoint_to_url() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        echo ""
        return 0
    fi
    # If user already gave a scheme, keep it; otherwise default to https.
    if [[ "$raw" == http://* || "$raw" == https://* ]]; then
        echo "$raw"
    else
        echo "https://$raw"
    fi
}

# Run curl from inside a pod against an endpoint and report reachability.
# Uses -k intentionally so a self-signed / privately-signed certificate
# does not mask the underlying TCP / DNS / proxy reachability signal. TLS
# trust is validated separately by test_tls_from_pod (S3 TLS Verification
# Check). A non-zero curl exit code is treated as failure. Any HTTP status
# response (including 403/401) is treated as TCP/TLS-level reachable.
test_endpoint_from_pod() {
    local label="$1"
    local cmd="$2"
    local namespace="$3"
    local pod="$4"
    local url="$5"

    if [[ -z "$pod" ]]; then
        print_warning "$label: no Running pod available to test endpoint reachability."
        return 1
    fi

    print_info "$label: testing $url from pod $pod ..."
    local out
    local code
    out=$($cmd -n "$namespace" exec "$pod" -- \
        curl -s -k -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 "$url" 2>&1) || code=$?
    code=${code:-0}

    if [[ $code -ne 0 ]]; then
        print_error "$label: curl from pod failed (exit code $code) for $url"
        print_error "  Output: $out"
        return 1
    fi
    if [[ "$out" == "000" ]]; then
        print_error "$label: $url is NOT reachable from $pod (no HTTP response, http_code=000)."
        return 1
    fi
    print_info "$label: $url reachable from $pod (http_code=$out)."
    return 0
}

object_storage_check() {
    print_section "Object Storage Accessibility Check (TLS verification skipped)"
    print_info "TLS verification is skipped (curl -k); certificate trust is validated separately in the S3 TLS Verification Check."

    local endpoints=""
    if [[ ${#EXTRA_ENDPOINTS[@]} -gt 0 ]]; then
        print_info "Testing ${#EXTRA_ENDPOINTS[@]} user-supplied endpoint(s)."
        local e
        for e in "${EXTRA_ENDPOINTS[@]}"; do
            endpoints=$(printf "%s\n%s" "$endpoints" "$e")
        done
    fi

    # Deduplicate
    endpoints=$(echo "$endpoints" | awk 'NF && !seen[$0]++')
    if [[ -z "$endpoints" ]]; then
        print_info "No object storage endpoints supplied. Skipping check."
        print_info "  Pass --endpoint URL (repeatable) or use the interactive prompt to test endpoints."
        return 0
    fi

    # Resolve test pods (one per component)
    local pxb_cmd app_cmd
    pxb_cmd=$(build_cmd "$PXB_CLI_TOOL" "$PXB_KUBECONFIG")
    app_cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")

    local pxb_pod stork_pod px_pod=""
    pxb_pod=$(pick_ready_pod "$pxb_cmd" "$PXB_NAMESPACE" "app=px-backup")
    stork_pod=$(pick_ready_pod "$app_cmd" "$STORK_NAMESPACE" "name=stork")
    if [[ "$PXE_INSTALLED" == "true" ]]; then
        px_pod=$(pick_ready_pod "$app_cmd" "$PX_NAMESPACE" "name=portworx")
    fi

    [[ -z "$pxb_pod" ]]   && print_warning "Could not locate a Running PXB pod (label app=px-backup) in $PXB_NAMESPACE."
    [[ -z "$stork_pod" ]] && print_warning "Could not locate a Running Stork pod (label name=stork) in $STORK_NAMESPACE."
    if [[ "$PXE_INSTALLED" == "true" && -z "$px_pod" ]]; then
        print_warning "Could not locate a Running Portworx pod (label name=portworx) in $PX_NAMESPACE."
    fi

    while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        local url
        url=$(endpoint_to_url "$ep")
        echo ""
        echo "--- Endpoint: $url ---"
        test_endpoint_from_pod "PXB"   "$pxb_cmd" "$PXB_NAMESPACE"   "$pxb_pod"   "$url" || true
        test_endpoint_from_pod "Stork" "$app_cmd" "$STORK_NAMESPACE" "$stork_pod" "$url" || true
        if [[ "$PXE_INSTALLED" == "true" ]]; then
            test_endpoint_from_pod "PXE" "$app_cmd" "$PX_NAMESPACE" "$px_pod" "$url" || true
        fi
    done <<< "$endpoints"
}


# ------------------------------------------------------------------
# Pod Health Check (PXB cluster)
# ------------------------------------------------------------------

# Returns 0 when the cluster targeted by $cmd is OpenShift.
is_openshift_cluster() {
    local cmd="$1"
    $cmd api-resources --api-group=apps.openshift.io --no-headers 2>/dev/null | grep -q .
}

pod_health_check() {
    print_section "Pod Health Check (PXB cluster)"

    local cmd
    cmd=$(build_cmd "$PXB_CLI_TOOL" "$PXB_KUBECONFIG")

    local is_ocp=false
    if is_openshift_cluster "$cmd"; then
        is_ocp=true
        print_info "OpenShift detected on PXB cluster."
    else
        print_info "PXB cluster is not OpenShift."
    fi

    # Pull every pod in the PXB namespace with all its container statuses so
    # multi-container pods (where container 0 is fine but container N is
    # crash-looping) are still flagged. Format per line:
    #   <pod>|<phase>|<c0>~<restarts>~<reason>;<c1>~<restarts>~<reason>;...
    local pods_raw
    pods_raw=$($cmd -n "$PXB_NAMESPACE" get pods \
        -o jsonpath='{range .items[*]}{.metadata.name}|{.status.phase}|{range .status.containerStatuses[*]}{.name}~{.restartCount}~{.state.waiting.reason};{end}{"\n"}{end}' 2>/dev/null)

    if [[ -z "$pods_raw" ]]; then
        print_warning "No pods found in namespace '$PXB_NAMESPACE'. Skipping pod health check."
        return 0
    fi

    # Pods belonging to the 'px-backup' Deployment follow the ReplicaSet
    # naming convention <deploy>-<rsHash>-<podHash>; both hashes are
    # alphanumeric so a dash inside the suffix means a different Deployment
    # (e.g. px-backup-ui-..., px-backup-stork-...).
    local pxb_pod_re='^px-backup-[a-z0-9]+-[a-z0-9]+$'
    local unhealthy=0
    local pxb_pod_unhealthy=false
    local pod_name pod_phase containers_str
    while IFS='|' read -r pod_name pod_phase containers_str; do
        [[ -z "$pod_name" ]] && continue
        local pod_unhealthy=0

        if [[ "$pod_phase" != "Running" && "$pod_phase" != "Succeeded" ]]; then
            # Surface the first non-empty waiting reason across the pod's
            # containers as context (ImagePullBackOff, CrashLoopBackOff, ...).
            local first_reason="" c cname crestarts creason
            local -a _carr=()
            IFS=';' read -ra _carr <<< "$containers_str"
            for c in "${_carr[@]}"; do
                [[ -z "$c" ]] && continue
                IFS='~' read -r cname crestarts creason <<< "$c"
                if [[ -n "$creason" ]]; then first_reason="$creason"; break; fi
            done
            print_error "Pod '$pod_name' in phase '$pod_phase' (reason: ${first_reason:-n/a})."
            pod_unhealthy=1
        fi

        # Per-container scan: catch waiting containers in an otherwise-Running
        # pod and flag any container at >= 5 restarts.
        local -a _carr2=()
        IFS=';' read -ra _carr2 <<< "$containers_str"
        for c in "${_carr2[@]}"; do
            [[ -z "$c" ]] && continue
            IFS='~' read -r cname crestarts creason <<< "$c"
            crestarts=${crestarts:-0}
            if [[ -n "$creason" && "$pod_phase" == "Running" ]]; then
                print_error "Pod '$pod_name' container '$cname' is waiting (reason: $creason)."
                pod_unhealthy=1
            fi
            if [[ "$crestarts" =~ ^[0-9]+$ && "$crestarts" -ge 5 ]]; then
                print_warning "Pod '$pod_name' container '$cname' has $crestarts restarts."
                pod_unhealthy=1
            fi
        done

        if [[ $pod_unhealthy -eq 1 ]]; then
            unhealthy=1
            if [[ "$pod_name" =~ $pxb_pod_re ]]; then
                pxb_pod_unhealthy=true
            fi
        fi
    done <<< "$pods_raw"

    if [[ $unhealthy -eq 0 ]]; then
        print_info "All pods in '$PXB_NAMESPACE' look healthy."
        return 0
    fi

    # OpenShift-specific recommendation: only when the px-backup Deployment
    # pod is unhealthy AND its pod template still carries the non-OCP
    # securityContext (runAsUser=1000, fsGroup=1000). The Helm chart clears
    # both when installed with --set isOpenshift=true so OCP can assign UIDs
    # via SCC annotations.
    if $is_ocp && $pxb_pod_unhealthy; then
        local run_as_user fs_group
        run_as_user=$($cmd -n "$PXB_NAMESPACE" get deployment px-backup \
            -o jsonpath='{.spec.template.spec.securityContext.runAsUser}' 2>/dev/null || true)
        fs_group=$($cmd -n "$PXB_NAMESPACE" get deployment px-backup \
            -o jsonpath='{.spec.template.spec.securityContext.fsGroup}' 2>/dev/null || true)
        if [[ "$run_as_user" == "1000" && "$fs_group" == "1000" ]]; then
            print_warning "RECOMMENDATION: On OpenShift, install px-backup with --set isOpenshift=true."
            print_warning "  Detected px-backup Deployment securityContext runAsUser=1000, fsGroup=1000 (default for non-OpenShift)."
            print_warning "  See: https://docs.portworx.com/portworx-backup-on-prem/install/install-openshift"
        fi
    fi
}


# ------------------------------------------------------------------
# KDMP Cloud-Snap Distribution Check
# ------------------------------------------------------------------

# Returns "true" when val is one of the truthy spellings used by Stork /
# the kdmp-config ConfigMap (true / yes / 1, case-insensitive).
is_truthy_kdmp_value() {
    local v
    v=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        true|yes|1) return 0 ;;
        *)          return 1 ;;
    esac
}

# Probe TCP connectivity from a pod to host:port using bash's /dev/tcp
# pseudo-device. Echoes one of OPEN / CLOSED / TIMEOUT / NO_BASH so the
# caller can distinguish "blocked by network" from "container has no bash"
# from "port is up but service rejected the byte we sent".
probe_tcp_from_pod() {
    local cmd="$1" namespace="$2" pod="$3" host="$4" port="$5"
    local out
    out=$(run_with_timeout 12 \
        $cmd -n "$namespace" exec "$pod" --request-timeout=10s -- \
        bash -c "exec 3<>/dev/tcp/${host}/${port} && echo OPEN || echo CLOSED" \
        2>&1) || true
    case "$out" in
        *OPEN*)                              echo "OPEN" ;;
        *CLOSED*)                            echo "CLOSED" ;;
        *"executable file not found"*|*"no such file"*|*"not found"*)
                                             echo "NO_BASH" ;;
        *)                                   echo "TIMEOUT" ;;
    esac
}

kdmp_config_check() {
    print_section "KDMP Configuration Check (app cluster)"

    if [[ "$PXE_INSTALLED" != "true" ]]; then
        print_info "Portworx Enterprise is not installed on the app cluster. Skipping KDMP cloud-snap distribution check."
        return 0
    fi

    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")

    # kdmp-config lives in kube-system and is created by Stork / KDMP on
    # the first KDMP backup. Missing ConfigMap is reported as a warning
    # but does not skip the connectivity probe below — the probe is
    # independent and useful even on a fresh install.
    local kdmp_ns="kube-system"
    local cm_present="false"
    local disable_val=""
    local kdmp_dump_name="kdmp-config.yaml"
    local kdmp_dump="${BUNDLE_DIR}/${kdmp_dump_name}"
    if run_with_timeout 15 $cmd -n "$kdmp_ns" --request-timeout=10s \
            get configmap kdmp-config >/dev/null 2>&1; then
        cm_present="true"
        if run_with_timeout 15 $cmd -n "$kdmp_ns" --request-timeout=10s \
                get configmap kdmp-config -o yaml > "$kdmp_dump" 2>&1; then
            print_info "kdmp-config dumped to: $kdmp_dump_name"
        else
            print_warning "Failed to dump kdmp-config to $kdmp_dump_name (see file for error)."
        fi
        disable_val=$(run_with_timeout 10 $cmd -n "$kdmp_ns" --request-timeout=10s \
            get configmap kdmp-config -o jsonpath='{.data.DISABLE_PX_CS_DISTRIBUTION}' 2>/dev/null || true)
        if [[ -z "$disable_val" ]]; then
            print_info "DISABLE_PX_CS_DISTRIBUTION = <unset> (default false; cloud-snap traffic distributed across PX node IPs)"
        elif is_truthy_kdmp_value "$disable_val"; then
            print_info "DISABLE_PX_CS_DISTRIBUTION = '$disable_val' (cloud-snap distribution disabled; traffic uses the PXE Service ClusterIP)"
        else
            print_info "DISABLE_PX_CS_DISTRIBUTION = '$disable_val' (non-truthy; distribution remains enabled across PX node IPs)"
        fi
    else
        print_warning "ConfigMap kdmp-config not found in '$kdmp_ns'. It is created by Stork on the first KDMP backup; absence on a fresh install can be normal."
    fi

    # Active probe: Stork → each PXE node IP on the OpenStorage API port.
    # The T-Mobile POC (postmortem section 4) hit a backup-time I/O timeout
    # because direct node-IP communication was blocked on the customer
    # network. We replay that exact path here so the issue surfaces at
    # install time instead of on the first backup.
    local pxe_node_port=9001
    print_info "Probing TCP connectivity from Stork to PXE node IPs on port ${pxe_node_port}..."

    local stork_pod
    stork_pod=$(pick_ready_pod "$cmd" "$STORK_NAMESPACE" "name=stork" || true)
    if [[ -z "$stork_pod" ]]; then
        print_warning "No Running Stork pod (label name=stork) in '$STORK_NAMESPACE'. Skipping connectivity probe."
        return 0
    fi

    local node_ips
    node_ips=$(run_with_timeout 15 $cmd -n "$PX_NAMESPACE" --request-timeout=10s \
        get pods -l name=portworx \
        -o jsonpath='{range .items[*]}{.status.hostIP}{"\n"}{end}' 2>/dev/null \
        | awk 'NF && !seen[$0]++' || true)
    if [[ -z "$node_ips" ]]; then
        print_warning "No portworx pods found in '$PX_NAMESPACE'. Skipping connectivity probe."
        return 0
    fi

    local total=0 unreachable=0 no_bash=0 ip result
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        total=$((total + 1))
        result=$(probe_tcp_from_pod "$cmd" "$STORK_NAMESPACE" "$stork_pod" "$ip" "$pxe_node_port")
        case "$result" in
            OPEN)
                print_info "  ${ip}:${pxe_node_port} -> OPEN"
                ;;
            CLOSED)
                print_warning "  ${ip}:${pxe_node_port} -> CLOSED (port not listening on this node)"
                unreachable=$((unreachable + 1))
                ;;
            TIMEOUT)
                print_warning "  ${ip}:${pxe_node_port} -> TIMEOUT (network blocking direct node access)"
                unreachable=$((unreachable + 1))
                ;;
            NO_BASH)
                print_info "  ${ip}:${pxe_node_port} -> SKIPPED (bash not available in Stork container; cannot probe)"
                no_bash=$((no_bash + 1))
                ;;
        esac
    done <<< "$node_ips"

    if [[ $no_bash -gt 0 && $unreachable -eq 0 ]]; then
        print_warning "Connectivity probe could not run inside the Stork container (bash unavailable). Verify manually that Stork can reach each PXE node on port ${pxe_node_port}."
        return 0
    fi

    if [[ $unreachable -gt 0 ]]; then
        print_warning "${unreachable}/${total} PXE node(s) unreachable from Stork on port ${pxe_node_port}."
        if [[ "$cm_present" == "true" ]] && is_truthy_kdmp_value "$disable_val"; then
            print_info "DISABLE_PX_CS_DISTRIBUTION is already set; cloud-snap traffic uses the PXE Service ClusterIP, so backups should still succeed."
        else
            print_warning "RECOMMENDATION: Set DISABLE_PX_CS_DISTRIBUTION=true in ConfigMap 'kdmp-config' (namespace 'kube-system') to force cloud-snap traffic via the PXE Service ClusterIP instead of node IPs."
            print_warning "  Reference: https://docs.portworx.com/portworx-backup-on-prem/reference/configmap-parameters/kdmp-config-parameters#cloudsnap-configuration"
        fi
    else
        print_info "All ${total} PXE node(s) reachable from Stork on port ${pxe_node_port}."
    fi
}


# ------------------------------------------------------------------
# S3 TLS Verification Check
# ------------------------------------------------------------------

# Run a curl that does NOT use -k against an https endpoint from inside a pod
# and report TLS / cert errors. Counterpart to test_endpoint_from_pod (Object
# Storage Accessibility Check): same pods and endpoints, but with TLS
# verification enabled so cert-trust failures surface. Returns 0 when TLS
# verification succeeds, 1 on any TLS-level failure (including a curl exit
# code), 2 when the test is skipped.
test_tls_from_pod() {
    local label="$1"
    local cmd="$2"
    local namespace="$3"
    local pod="$4"
    local url="$5"

    if [[ -z "$pod" ]]; then
        return 2
    fi

    local out rc=0
    out=$($cmd -n "$namespace" exec "$pod" -- \
        curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 "$url" 2>&1) || rc=$?

    # curl exit codes 35/51/58/60/77/82/83 are TLS / cert related per curl docs.
    if [[ $rc -ne 0 ]]; then
        if echo "$out" | grep -qiE 'self.signed|certificate|SSL|TLS|x509|verify failed'; then
            print_error "$label: TLS verification failed against $url (curl exit $rc)."
            print_error "  Output: $out"
            return 1
        fi
        # Non-TLS connection error - object_storage_check already covered reachability.
        return 2
    fi
    print_info "$label: TLS verification succeeded against $url (http_code=$out)."
    return 0
}

s3_cert_check() {
    print_section "S3 TLS Verification Check"
    print_info "Re-runs each HTTPS endpoint with TLS verification enabled (no curl -k); complements the Object Storage Accessibility Check above."

    local endpoints=""
    if [[ ${#EXTRA_ENDPOINTS[@]} -gt 0 ]]; then
        local e
        for e in "${EXTRA_ENDPOINTS[@]}"; do
            endpoints=$(printf "%s\n%s" "$endpoints" "$e")
        done
    fi
    endpoints=$(echo "$endpoints" | awk 'NF && !seen[$0]++')
    if [[ -z "$endpoints" ]]; then
        print_info "No object storage endpoints supplied. Skipping S3 cert check."
        return 0
    fi

    local pxb_cmd app_cmd
    pxb_cmd=$(build_cmd "$PXB_CLI_TOOL" "$PXB_KUBECONFIG")
    app_cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")

    local pxb_pod stork_pod px_pod=""
    pxb_pod=$(pick_ready_pod "$pxb_cmd" "$PXB_NAMESPACE" "app=px-backup")
    stork_pod=$(pick_ready_pod "$app_cmd" "$STORK_NAMESPACE" "name=stork")
    if [[ "$PXE_INSTALLED" == "true" ]]; then
        px_pod=$(pick_ready_pod "$app_cmd" "$PX_NAMESPACE" "name=portworx")
    fi

    local any_tls_failure=0
    while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        local url
        url=$(endpoint_to_url "$ep")
        # Skip non-https endpoints (no cert to check).
        if [[ "$url" != https://* ]]; then
            print_info "Skipping non-HTTPS endpoint: $url"
            continue
        fi
        echo ""
        echo "--- TLS check: $url ---"
        local r
        test_tls_from_pod "PXB"   "$pxb_cmd" "$PXB_NAMESPACE"   "$pxb_pod"   "$url"; r=$?; [[ $r -eq 1 ]] && any_tls_failure=1
        test_tls_from_pod "Stork" "$app_cmd" "$STORK_NAMESPACE" "$stork_pod" "$url"; r=$?; [[ $r -eq 1 ]] && any_tls_failure=1
        if [[ "$PXE_INSTALLED" == "true" ]]; then
            test_tls_from_pod "PXE" "$app_cmd" "$PX_NAMESPACE" "$px_pod" "$url"; r=$?; [[ $r -eq 1 ]] && any_tls_failure=1
        fi
    done <<< "$endpoints"

    if [[ $any_tls_failure -eq 1 ]]; then
        print_warning "RECOMMENDATION: Object-storage endpoint(s) appear to use a self-signed or"
        print_warning "  privately-signed certificate. Configure the CA bundle on PXB:"
        print_warning "  - PXB: helm install ... --set caCertsSecretName=<secret>"
        if [[ "$PXE_INSTALLED" == "true" ]]; then
            print_warning "  - PXE: see https://docs.portworx.com/portworx-enterprise/operations/operate-kubernetes/storage-operations/create-snapshots/cloudsnaps/cloud-snapshots-config-private"
        fi
    fi
}


# ------------------------------------------------------------------
# S3 Self-Signed Certificate Configuration Check
# ------------------------------------------------------------------
#
# Validates the CA-bundle wiring documented in the postmortem (PD-5633 /
# T-Mobile POC) when the operator confirms the BackupLocation endpoint uses
# HTTPS with a self-signed cert. For each component (PXB, Stork, PXE) we
# verify three things:
#   1. The expected env var is set (SSL_CERT_DIR for PXB; AWS_CA_BUNDLE +
#      SSL_CERT_DIR for Stork; AWS_CA_BUNDLE for PXE on the StorageCluster).
#   2. A volumeMount/volume entry covers the directory the env var points at.
#   3. The referenced Secret exists and contains at least one cert-looking
#      data key (suffix .crt or .pem).
# Anything missing is reported as a warning so the operator can fix it
# before the first BackupLocation add fails in the UI.

# Pull a single env value (by name) from a deployment's first container.
# Echoes nothing when the var is unset.
get_deployment_env_value() {
    local cmd="$1" namespace="$2" deployment="$3" name="$4"
    get_deployment_env_json "$cmd" "$namespace" "$deployment" \
        | flatten_env_pairs \
        | awk -F= -v n="$name" '$1==n {sub("^"n"=",""); print; exit}'
}

# Pull a single env value from the first StorageCluster's spec.env.
get_stc_env_value() {
    local cmd="$1" namespace="$2" name="$3"
    $cmd -n "$namespace" get stc \
        -o jsonpath='{range .items[0].spec.env[*]}{"{\"name\":\""}{.name}{"\",\"value\":\""}{.value}{"\"},\n"}{end}' 2>/dev/null \
        | flatten_env_pairs \
        | awk -F= -v n="$name" '$1==n {sub("^"n"=",""); print; exit}'
}

# For a deployment, find the volumeMount whose mountPath equals (or is a
# prefix of) the supplied path; emit "<volumeName>|<secretName>" or empty.
# Walks volumeMounts to find the matching volume name, then looks up the
# secret in spec.template.spec.volumes.
deployment_volume_for_path() {
    local cmd="$1" namespace="$2" deployment="$3" target_path="$4"
    local mounts volumes vol_name
    mounts=$($cmd -n "$namespace" get deployment "$deployment" \
        -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"|"}{.mountPath}{"\n"}{end}' 2>/dev/null)
    vol_name=$(echo "$mounts" | awk -F'|' -v p="$target_path" '
        $2 != "" && (p == $2 || index(p, $2"/") == 1) { print $1; exit }')
    [[ -z "$vol_name" ]] && return 0
    volumes=$($cmd -n "$namespace" get deployment "$deployment" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"|"}{.secret.secretName}{"\n"}{end}' 2>/dev/null)
    echo "$volumes" | awk -F'|' -v n="$vol_name" '$1==n {print n"|"$2; exit}'
}

# Same idea for a StorageCluster: spec.volumes carries name + mountPath +
# secret.secretName in a single entry.
stc_volume_for_path() {
    local cmd="$1" namespace="$2" target_path="$3"
    $cmd -n "$namespace" get stc \
        -o jsonpath='{range .items[0].spec.volumes[*]}{.name}{"|"}{.mountPath}{"|"}{.secret.secretName}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' -v p="$target_path" '
            $2 != "" && (p == $2 || index(p, $2"/") == 1) { print $1"|"$3; exit }'
}

# Verify a Secret exists in the given namespace and carries at least one
# cert-looking data key. Adds a warning when missing or empty.
verify_cert_secret() {
    local label="$1" cmd="$2" namespace="$3" secret="$4"
    if ! $cmd -n "$namespace" get secret "$secret" >/dev/null 2>&1; then
        print_error "$label: Secret '$secret' not found in namespace '$namespace'."
        return 1
    fi
    # go-template over .data emits one key name per line.
    local keys
    keys=$($cmd -n "$namespace" get secret "$secret" \
        -o go-template='{{range $k, $_ := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null)
    if ! echo "$keys" | grep -qiE '\.(crt|pem)$'; then
        print_error "$label: Secret '$secret' has no .crt/.pem data key. Found keys: $(echo "$keys" | tr '\n' ' ')"
        return 1
    fi
    print_info "$label: Secret '$secret' present with cert key(s): $(echo "$keys" | tr '\n' ' ')"
    return 0
}

# Common per-component validator. env_path = directory the cert is mounted
# at (derived from SSL_CERT_DIR for PXB/Stork or the dirname of
# AWS_CA_BUNDLE for Stork/PXE). When env_path is empty the helper returns
# silently so the caller can emit a consolidated error.
check_cert_wiring_deployment() {
    local label="$1" cmd="$2" namespace="$3" deployment="$4" env_path="$5"
    if [[ -z "$env_path" ]]; then
        return 1
    fi
    local pair vol secret
    pair=$(deployment_volume_for_path "$cmd" "$namespace" "$deployment" "$env_path")
    if [[ -z "$pair" ]]; then
        print_error "$label: no volumeMount covers '$env_path' on deployment '$deployment'. Mount the CA-cert Secret there."
        return 1
    fi
    vol=${pair%%|*}; secret=${pair##*|}
    if [[ -z "$secret" ]]; then
        print_error "$label: volume '$vol' is mounted at '$env_path' but is not backed by a Secret."
        return 1
    fi
    print_info "$label: volume '$vol' at '$env_path' -> secret '$secret'."
    verify_cert_secret "$label" "$cmd" "$namespace" "$secret"
}

# PXB: caCertsSecretName=<x> sets SSL_CERT_DIR on the px-backup deployment
# and mounts the secret at that directory. AWS_CA_BUNDLE is not used by PXB.
check_pxb_self_signed_cert_wiring() {
    local cmd
    cmd=$(build_cmd "$PXB_CLI_TOOL" "$PXB_KUBECONFIG")
    # `jsonpath={.items[0]...}` returns rc=1 ("array index out of bounds") on
    # an empty list, which would trip set -e. Append `|| true` so the empty
    # case falls through to the fallback name + existence check below.
    local deploy
    deploy=$($cmd -n "$PXB_NAMESPACE" get deployment -l app=px-backup \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "$deploy" ]] && deploy="px-backup"
    if ! $cmd -n "$PXB_NAMESPACE" get deployment "$deploy" >/dev/null 2>&1; then
        print_warning "PXB deployment '$deploy' not found in namespace '$PXB_NAMESPACE'. Skipping PXB cert wiring check."
        return 0
    fi
    echo ""
    echo "--- PXB (px-backup) cert wiring ---"
    local ssl_dir
    ssl_dir=$(get_deployment_env_value "$cmd" "$PXB_NAMESPACE" "$deploy" "SSL_CERT_DIR")
    if [[ -z "$ssl_dir" ]]; then
        print_error "PXB: SSL_CERT_DIR is not set on deployment '$deploy'. Reinstall/upgrade PX-Backup with --set caCertsSecretName=<secret> (https://docs.portworx.com/portworx-backup-on-prem/install/configure-certs/s3-cert-bkpcluster)."
        return 0
    fi
    print_info "PXB: SSL_CERT_DIR='$ssl_dir' on deployment '$deploy'."
    check_cert_wiring_deployment "PXB" "$cmd" "$PXB_NAMESPACE" "$deploy" "$ssl_dir"
}

# Stork: needs both AWS_CA_BUNDLE (full file path) and SSL_CERT_DIR
# (directory) per the PXB on-prem docs. Cert mount = SSL_CERT_DIR.
check_stork_self_signed_cert_wiring() {
    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    local deploy
    deploy=$($cmd -n "$STORK_NAMESPACE" get deployment -l name=stork \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "$deploy" ]] && deploy="stork"
    if ! $cmd -n "$STORK_NAMESPACE" get deployment "$deploy" >/dev/null 2>&1; then
        print_warning "Stork deployment '$deploy' not found in namespace '$STORK_NAMESPACE'. Skipping Stork cert wiring check."
        return 0
    fi
    echo ""
    echo "--- Stork cert wiring ---"
    local bundle ssl_dir
    bundle=$(get_deployment_env_value "$cmd" "$STORK_NAMESPACE" "$deploy" "AWS_CA_BUNDLE")
    ssl_dir=$(get_deployment_env_value "$cmd" "$STORK_NAMESPACE" "$deploy" "SSL_CERT_DIR")
    [[ -n "$bundle"  ]] && print_info "Stork: AWS_CA_BUNDLE='$bundle'."
    [[ -n "$ssl_dir" ]] && print_info "Stork: SSL_CERT_DIR='$ssl_dir'."
    # Consolidate missing-env findings into a single error so the summary
    # carries one Stork wiring entry, not three.
    local missing=()
    [[ -z "$bundle"  ]] && missing+=("AWS_CA_BUNDLE")
    [[ -z "$ssl_dir" ]] && missing+=("SSL_CERT_DIR")
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Stork: missing env var(s) on deployment '$deploy': ${missing[*]}. Set AWS_CA_BUNDLE to the cert file path and SSL_CERT_DIR to its directory (https://docs.portworx.com/portworx-backup-on-prem/configure/configure-with-s3/s3-cert-appcluster)."
        return 0
    fi
    check_cert_wiring_deployment "Stork" "$cmd" "$STORK_NAMESPACE" "$deploy" "$ssl_dir"
}

# PXE: StorageCluster spec.env carries AWS_CA_BUNDLE; spec.volumes carries
# the secret-backed mount whose mountPath should be the dirname of the
# bundle path.
check_pxe_self_signed_cert_wiring() {
    if [[ "$PXE_INSTALLED" != "true" ]]; then
        print_info "PXE not installed; skipping PXE cert wiring check."
        return 0
    fi
    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    if ! $cmd -n "$PX_NAMESPACE" get stc >/dev/null 2>&1; then
        print_warning "No StorageCluster in namespace '$PX_NAMESPACE'. Skipping PXE cert wiring check."
        return 0
    fi
    echo ""
    echo "--- PXE (StorageCluster) cert wiring ---"
    local bundle
    bundle=$(get_stc_env_value "$cmd" "$PX_NAMESPACE" "AWS_CA_BUNDLE")
    if [[ -z "$bundle" ]]; then
        print_error "PXE: AWS_CA_BUNDLE not set in StorageCluster spec.env. Configure per https://docs.portworx.com/portworx-enterprise/how-to-guides/certs."
        return 0
    fi
    print_info "PXE: AWS_CA_BUNDLE='$bundle' on StorageCluster."
    local mount_dir="${bundle%/*}"
    local pair vol secret
    pair=$(stc_volume_for_path "$cmd" "$PX_NAMESPACE" "$mount_dir")
    if [[ -z "$pair" ]]; then
        print_error "PXE: no spec.volumes entry mounts '$mount_dir' on the StorageCluster. Add a Secret-backed volume there."
        return 0
    fi
    vol=${pair%%|*}; secret=${pair##*|}
    if [[ -z "$secret" ]]; then
        print_error "PXE: spec.volumes entry '$vol' at '$mount_dir' is not backed by a Secret."
        return 0
    fi
    print_info "PXE: volume '$vol' at '$mount_dir' -> secret '$secret'."
    # PXE secret typically lives in the PX namespace; verify there.
    verify_cert_secret "PXE" "$cmd" "$PX_NAMESPACE" "$secret"
}

s3_self_signed_cert_config_check() {
    print_section "S3 Self-Signed Certificate Configuration Check"

    if [[ "$SELF_SIGNED_S3" != "y" ]]; then
        print_info "Endpoint not flagged as self-signed. Skipping CA-bundle wiring check."
        return 0
    fi

    print_info "Validating CA-bundle Secret + Volume + Env wiring across PXB, Stork and PXE."
    print_info "Reference: https://purestorage.atlassian.net/wiki/x/EIBmKAE (BackupLocation Addition Failure section)."

    # Each per-component helper returns non-zero on a failed validation
    # (missing env var, mount, or secret key). Those are reported as
    # warnings, not script-fatal — wrap with `|| true` so set -e doesn't
    # abort the remaining components.
    check_pxb_self_signed_cert_wiring   || true
    check_stork_self_signed_cert_wiring || true
    check_pxe_self_signed_cert_wiring   || true
}




# ------------------------------------------------------------------
# Platform Detection (informational)
# ------------------------------------------------------------------

# Detect Kubernetes distribution, version, managed-cluster vendor and a few
# adjacent facts (provider, node count, node OS image, container runtime) for
# a single cluster. Pure auto-detection, best-effort: every probe falls back
# to "-" rather than failing the run. Never adds entries to ERRORS/WARNINGS.
detect_platform_for_cluster() {
    local label="$1"
    local cli="$2"
    local kc="$3"
    local cmd
    cmd=$(build_cmd "$cli" "$kc")
    # Pair the kubectl/oc API request timeout with a wall-clock watchdog so a
    # slow apiserver, OIDC/aws-iam-authenticator round-trip, or stuck TCP
    # connection cannot freeze the section. Per-probe budget = 8s.
    local cmd_t="$cmd --request-timeout=10s"
    local TO=8

    echo ""
    echo "--- $label ---"

    local distro="Vanilla Kubernetes"
    local distro_ver="-"
    local managed="No"

    # OCP: clusterversion CR is the canonical source for the OCP release.
    local ocp_ver
    ocp_ver=$(run_with_timeout "$TO" $cmd_t get clusterversion version -o jsonpath='{.status.desired.version}' || true)
    if [[ -n "$ocp_ver" ]]; then
        distro="OpenShift Container Platform (OCP)"
        distro_ver="$ocp_ver"
    fi

    # Rancher (RKE / RKE2 / K3s / imported clusters under Rancher control).
    if run_with_timeout "$TO" $cmd_t get ns cattle-system -o name >/dev/null 2>&1; then
        if [[ "$distro" == "Vanilla Kubernetes" ]]; then
            distro="Rancher-managed Kubernetes"
        else
            distro="$distro (Rancher-managed)"
        fi
        local rancher_ver
        rancher_ver=$(run_with_timeout "$TO" $cmd_t -n cattle-system get deploy rancher \
                          -o jsonpath='{.spec.template.spec.containers[0].image}' \
                  | awk -F: 'NF>1 {print $NF}' || true)
        [[ -n "$rancher_ver" && "$distro_ver" == "-" ]] && distro_ver="$rancher_ver"
    fi

    # vSphere with Tanzu (TKGS) exposes the run.tanzu.vmware.com API group.
    if run_with_timeout "$TO" $cmd_t get crd tanzukubernetesreleases.run.tanzu.vmware.com -o name >/dev/null 2>&1; then
        distro="vSphere with Tanzu (TKGS)"
    fi

    # Single `get nodes` call carries every node-derived field (labels,
    # provider, OS image, container runtime). Each record is one node, fields
    # separated by '|'. node_count is just the line count.
    local nodes_data
    nodes_data=$(run_with_timeout "$TO" $cmd_t get nodes \
        -o jsonpath='{range .items[*]}{.metadata.labels}{"|"}{.spec.providerID}{"|"}{.status.nodeInfo.osImage}{"|"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}' || true)

    # Managed-cluster vendor: search across every node's label dump. ROKS =
    # OCP control-plane + IBM Cloud labels.
    if grep -q 'eks.amazonaws.com/nodegroup' <<<"$nodes_data"; then
        managed="Yes - Amazon EKS"
    elif grep -q 'kubernetes.azure.com/cluster' <<<"$nodes_data"; then
        managed="Yes - Azure AKS"
    elif grep -q 'cloud.google.com/gke-nodepool' <<<"$nodes_data"; then
        managed="Yes - Google GKE"
    elif grep -q 'ibm-cloud.kubernetes.io/iaas-provider' <<<"$nodes_data"; then
        if [[ "$distro" == OpenShift* ]]; then
            managed="Yes - IBM Cloud ROKS"
        else
            managed="Yes - IBM Cloud IKS"
        fi
    fi

    local first_node="${nodes_data%%$'\n'*}"
    local provider_id="" node_os="-" node_cri="-"
    if [[ -n "$first_node" ]]; then
        provider_id=$(awk -F'|' '{print $2}' <<<"$first_node")
        local _os _cri
        _os=$(awk -F'|' '{print $3}' <<<"$first_node")
        _cri=$(awk -F'|' '{print $4}' <<<"$first_node")
        [[ -n "$_os" ]] && node_os="$_os"
        [[ -n "$_cri" ]] && node_cri="$_cri"
    fi
    local provider="-"
    if [[ -n "$provider_id" && "$provider_id" == *"://"* ]]; then
        provider="${provider_id%%://*}"
    fi

    local node_count
    node_count=$(grep -c . <<<"$nodes_data" || true)
    [[ -z "$node_count" || "$node_count" == "0" ]] && node_count="-"

    # Kubernetes server gitVersion via /version raw API (portable, no jq).
    local k8s_ver
    k8s_ver=$(run_with_timeout "$TO" $cmd_t get --raw /version \
              | awk -F'"' '/"gitVersion"/ {print $4; exit}' || true)
    [[ -z "$k8s_ver" ]] && k8s_ver="-"

    print_info "Distribution     : $distro"
    print_info "Distribution ver : $distro_ver"
    print_info "Kubernetes ver   : $k8s_ver"
    print_info "Managed cluster  : $managed"
    print_info "Provider         : $provider"
    print_info "Node count       : $node_count"
    print_info "Node OS image    : $node_os"
    print_info "Container runtime: $node_cri"
}

platform_detection_check() {
    print_section "Platform Detection"
    detect_platform_for_cluster "PXB cluster" "$PXB_CLI_TOOL" "$PXB_KUBECONFIG"
    detect_platform_for_cluster "App cluster" "$APP_CLI_TOOL" "$APP_KUBECONFIG"
}

# ------------------------------------------------------------------
# Helm Inspection (PXB cluster)
#
# px-backup ships as the `px-central` chart; the release name is
# user-chosen. We list everything in the PXB namespace, then for each
# release whose chart starts with "px-central" dump the merged values
# (`helm get values --all`) and full revision history. Inline output is
# kept short (helm ls table + last 5 history rows); full payloads land
# in /tmp so the operator can attach them to a support case.
# ------------------------------------------------------------------

helm_inspection_check() {
    print_section "Helm Inspection (PXB cluster)"

    if ! command -v helm >/dev/null 2>&1; then
        print_info "helm binary not found in PATH; skipping helm inspection."
        return 0
    fi

    local kc="$PXB_KUBECONFIG"
    local ns="$PXB_NAMESPACE"
    local helm_cmd="helm"
    [[ -n "$kc" ]] && helm_cmd="helm --kubeconfig=$kc"

    # 1. Inline helm ls table (all release states) for the PXB namespace.
    print_info "helm ls -n $ns -a:"
    run_with_timeout 20 $helm_cmd ls -n "$ns" -a 2>/dev/null || true
    echo ""

    # 2. Discover every release in the PXB namespace whose chart starts
    #    with `px-central`. JSON output is parsed without jq: split per
    #    release on '{', keep lines whose chart matches, then extract the
    #    release name. Works in bash 3.x on macOS.
    local ls_json releases=()
    ls_json=$(run_with_timeout 20 $helm_cmd ls -n "$ns" -a -o json 2>/dev/null || true)
    while IFS= read -r r; do
        [[ -n "$r" ]] && releases+=("$r")
    done < <(
        printf '%s' "$ls_json" \
            | tr '{' '\n' \
            | grep '"chart":"px-central' \
            | grep -oE '"name":"[^"]*"' \
            | sed -E 's/"name":"([^"]*)"/\1/'
    )

    if [[ ${#releases[@]} -eq 0 ]]; then
        print_info "No px-central chart release found in namespace '$ns'."
        return 0
    fi

    print_info "px-central release(s) found in '$ns': ${releases[*]}"

    # 3. Per release: dump merged values + full history to files, print
    #    a brief inline summary (last 5 history revisions).
    local r values_name history_name values_file history_file
    for r in "${releases[@]}"; do
        echo ""
        print_info "--- Release: $r ---"

        values_name="helm-values-${r}.yaml"
        history_name="helm-history-${r}.txt"
        values_file="${BUNDLE_DIR}/${values_name}"
        history_file="${BUNDLE_DIR}/${history_name}"

        # Merged values: user-supplied + chart defaults. -o yaml strips
        # helm's "USER-SUPPLIED VALUES:" / "COMPUTED VALUES:" headers so
        # the file is directly re-usable as a values overlay.
        if run_with_timeout 30 $helm_cmd get values "$r" -n "$ns" --all -o yaml \
                >"$values_file" 2>&1; then
            print_info "Merged values dumped to: $values_name"
        else
            print_info "Failed to fetch values for '$r' (see $values_name for details)."
        fi

        # Full history (no --max).
        if run_with_timeout 20 $helm_cmd history "$r" -n "$ns" \
                >"$history_file" 2>&1; then
            print_info "Full history dumped to: $history_name"
        else
            print_info "Failed to fetch history for '$r' (see $history_name for details)."
        fi

        # Inline summary: header + up to last 5 revision rows.
        if [[ -s "$history_file" ]]; then
            local lines
            lines=$(wc -l < "$history_file" 2>/dev/null | tr -d ' ')
            lines=${lines:-0}
            print_info "Last 5 history rows:"
            if [[ "$lines" -le 6 ]]; then
                cat "$history_file"
            else
                head -1 "$history_file"
                tail -n 5 "$history_file"
            fi
        fi
    done
}


# ------------------------------------------------------------------
# StorageCluster Dump (App cluster)
#
# PXE's StorageCluster CR carries the entire Portworx Enterprise
# install spec (cloud drives, network, security, KVDB, env vars, etc.)
# Dumping it to /tmp gives the operator a single artifact to attach to
# a support case. App cluster only, since PXE doesn't run on the PXB
# cluster. Skipped cleanly when PXE was not detected.
# ------------------------------------------------------------------

storagecluster_dump_check() {
    print_section "StorageCluster Dump (App cluster)"

    if [[ "$PXE_INSTALLED" != "true" ]]; then
        print_info "PXE not installed on the app cluster; skipping StorageCluster dump."
        return 0
    fi

    local ns="$PX_NAMESPACE"
    if [[ -z "$ns" ]]; then
        print_info "Portworx namespace unknown; skipping StorageCluster dump."
        return 0
    fi

    local cmd
    cmd=$(build_cmd "$APP_CLI_TOOL" "$APP_KUBECONFIG")
    local cmd_t="$cmd --request-timeout=10s"

    local out_name="storagecluster.yaml"
    local out_file="${BUNDLE_DIR}/${out_name}"

    # Single call dumps every StorageCluster in the PX namespace as one
    # YAML stream (kubectl already separates multi-item lists with ---
    # markers). Stderr is kept in the file so any RBAC / CRD-missing
    # error is visible to the operator alongside the YAML.
    if run_with_timeout 20 $cmd_t get storagecluster -n "$ns" -o yaml \
            >"$out_file" 2>&1; then
        print_info "StorageCluster YAML dumped to: $out_name"
    else
        print_info "Failed to dump StorageCluster (see $out_name for details)."
    fi
}


# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

print_summary() {
    print_section "Post-Install Check Summary"

    if [[ ${#ERRORS[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
        print_info "All checks passed. No issues found."
    else
        if [[ ${#ERRORS[@]} -gt 0 ]]; then
            echo -e "${RED}Errors (${#ERRORS[@]}):${NC}"
            local i
            for ((i=0; i<${#ERRORS[@]}; i++)); do
                echo -e "  ${RED}- ${ERRORS[$i]}${NC}"
            done
        fi
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            echo -e "${YELLOW}Warnings (${#WARNINGS[@]}):${NC}"
            local j
            for ((j=0; j<${#WARNINGS[@]}; j++)); do
                echo -e "  ${YELLOW}- ${WARNINGS[$j]}${NC}"
            done
        fi
    fi

}

# Tar the per-run bundle directory and remove the directory on success.
# Runs after print_summary so the final terminal line is the bundle path.
# Uses tar.gz to match other PX support tooling.
bundle_artifacts() {
    if [[ ! -d "$BUNDLE_DIR" ]]; then
        return 0
    fi
    # Flush + close the tee/sed redirect so run.log is fully written
    # before tar reads it. After this point, stdout/stderr go to the
    # original terminal only -- the bundle is sealed.
    finalize_logging
    echo ""
    if tar -czf "$BUNDLE_FILE" -C /tmp "$BUNDLE_NAME" 2>/dev/null; then
        rm -rf "$BUNDLE_DIR"
        print_info "Bundle: $BUNDLE_FILE"
    else
        print_warning "Failed to create $BUNDLE_FILE; raw dumps left in $BUNDLE_DIR."
    fi
}

main() {
    init_logging
    parse_args "$@"

    echo ""
    echo "=========================================="
    echo "  PX-Backup Post-Install Validation"
    echo "=========================================="
    print_info "Bundle directory: $BUNDLE_DIR (archived to ${BUNDLE_FILE} on completion)"

    setup_clusters
    platform_detection_check
    helm_inspection_check
    storagecluster_dump_check
    proxy_check
    object_storage_check
    pod_health_check
    kdmp_config_check
    s3_self_signed_cert_config_check
    s3_cert_check
    print_summary
    bundle_artifacts
}

# Only run main when executed directly. Allows tests to source this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

