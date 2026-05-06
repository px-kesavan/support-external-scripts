# px_post_install_check.sh

## Description

Validates a PX-Backup deployment after installation by inspecting **two
clusters in one run**:

- **PXB cluster** — where `px-backup` is installed (control plane).
- **App / source cluster** — where Stork is installed. Portworx Enterprise
  (PXE) is optional; PXE-specific checks are skipped automatically when
  PXE is not installed.

The script is read-only; it does not modify either cluster. Output is
streamed to the terminal and captured in a per-run bundle directory
under `/tmp/`, which is compressed to a single `.tar.gz` on completion
for easy attachment to a support case.

The checks are derived from the *Planned Post-Install Script Enhancements*
section of the [Postmortem of T-Mobile POC Deployment Issues](https://purestorage.atlassian.net/wiki/x/EIBmKAE)
Confluence page.

## Health Checks Performed

The script runs the following checks in order. Each section prints a
banner so the output (and the archived `run.log`) is easy to navigate.

| Check | Description |
|-------|-------------|
| `platform_detection_check` | Auto-detects Kubernetes distribution (Vanilla, OpenShift, Rancher-managed, vSphere with Tanzu / TKGS), distribution version, server `gitVersion`, managed-cluster vendor (EKS / AKS / GKE / IKS / ROKS), cloud provider, node count, node OS image, and container runtime — per cluster. Informational only; never adds errors or warnings. |
| `helm_inspection_check` | Lists Helm releases in the PXB namespace, identifies every `px-central` chart release, and dumps the merged values (`helm get values --all -o yaml`) and full revision history (`helm history`) to the bundle. Last 5 history rows are also printed inline. Skipped cleanly when `helm` is not on `PATH`. |
| `storagecluster_dump_check` | Dumps the StorageCluster CR (`storagecluster.yaml`) from the app cluster to the bundle. Skipped when PXE is not installed. |
| `proxy_check` | Reads `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` from the `px-backup` Deployment, the `stork` Deployment, and the `StorageCluster.spec.env`. Flags unsupported variants on the wrong component (e.g. `PX_HTTPS_NOPROXY`, `PX_HTTP_PROXY` on PXB / Stork, `HTTP_PROXY` on PXE). Compares canonical proxy triples across components and reports any drift. PXB / Stork use the un-prefixed forms; PXE uses `PX_HTTP_PROXY` / `PX_HTTPS_PROXY` / `NO_PROXY`. |
| `object_storage_check` (banner: *Object Storage Accessibility Check (TLS verification skipped)*) | For each endpoint supplied via `--endpoint` (repeatable) or the interactive prompt, runs `curl -k` from one Running pod per component (PXB, Stork, PXE) and reports HTTP code / reachability. `-k` is intentional — TLS verification is skipped so this check isolates the TCP / DNS / proxy reachability signal from cert issues. Certificate trust is validated separately by `s3_cert_check`. Skipped when no endpoints are supplied. |
| `pod_health_check` | Scans every pod in the PXB namespace on the PXB cluster (OCP and non-OCP). For each pod, checks **all containers** (not just container 0) and flags: pods not in phase `Running` / `Succeeded` (ERROR, includes the first non-empty `state.waiting.reason`), any container stuck in `waiting` while the pod is otherwise `Running` (ERROR), and any container with ≥5 restarts (WARNING). On OpenShift, if the `px-backup` Deployment's pod is the one that is unhealthy **and** its pod-template `securityContext` still shows `runAsUser=1000` / `fsGroup=1000` (the non-OCP default), the check also recommends reinstalling with `--set isOpenshift=true`. |
| `kdmp_config_check` | Inspects `kube-system/kdmp-config` ConfigMap on the app cluster, dumps it to the bundle (`kdmp-config.yaml`), and reports the value of `DISABLE_PX_CS_DISTRIBUTION`. Then actively probes TCP connectivity from a Stork pod to every PXE node IP on port `9001` (OpenStorage API) using bash `/dev/tcp`, distinguishing OPEN / CLOSED / TIMEOUT / NO_BASH. Recommends `DISABLE_PX_CS_DISTRIBUTION=true` when nodes are unreachable. Skipped when PXE is not installed. |
| `s3_self_signed_cert_config_check` | Gated by `--self-signed-s3` (or the interactive prompt). Validates the CA-bundle wiring across all three components against the [postmortem reference](https://purestorage.atlassian.net/wiki/x/EIBmKAE): <ul><li>**PXB** — `SSL_CERT_DIR` on the `px-backup` Deployment + matching `volumeMount` backed by a Secret containing `.crt` / `.pem` keys.</li><li>**Stork** — `AWS_CA_BUNDLE` *and* `SSL_CERT_DIR` on the `stork` Deployment + matching mount + Secret (consolidated into a single error when env vars are missing).</li><li>**PXE** — `AWS_CA_BUNDLE` in `StorageCluster.spec.env` + matching `spec.volumes` entry backed by a Secret.</li></ul> Reports each component's misconfiguration as a separate `ERROR` so it surfaces in the summary. |
| `s3_cert_check` (banner: *S3 TLS Verification Check*) | Re-runs each user-supplied HTTPS endpoint with `curl` **without** `-k` from the same PXB / Stork / PXE pods used by `object_storage_check`. A TLS / certificate error here indicates the object-storage endpoint uses a self-signed or privately-signed cert and the CA bundle is not configured. Recommends configuring the CA bundle on PXB / PXE when failures occur. |

## Features

- **Dual-cluster** — manages two kubeconfigs and per-cluster CLI tools simultaneously.
- **Auto-detected CLI** — `kubectl` or `oc` is selected per cluster; `oc` is preferred on OpenShift.
- **PXE-optional** — Portworx Enterprise is detected via the `portworx-api` Service; PXE-specific checks are skipped (not failed) when PXE is not installed.
- **Service-anchored namespace discovery** — PXB namespace is anchored on `px-backup-ui` Service, Stork namespace on `stork-service`, PXE namespace on `portworx-api`. The script auto-falls back to the correct namespace when the user-supplied / default namespace doesn't host the anchor.
- **Hard-coded apiserver timeouts** — every cluster call uses a per-request `--request-timeout` paired with a pure-bash wall-clock watchdog so a slow apiserver, OIDC round-trip, or wedged TCP connection cannot freeze the run.
- **Interactive prompts** — guides the user through kubeconfig, namespace, and endpoint selection.
- **Non-interactive mode** — accepts every value via flags so it can run in CI / automation.
- **Color-coded output** — Green (INFO), Yellow (WARNING), Red (ERROR). Colors are stripped from the archived log.
- **Aggregated summary** — all errors and warnings are listed at the end.
- **Bundle archive** — all dumps + the run log land in a per-run directory which is compressed to a single `.tar.gz` on completion (the directory is deleted).
- **Test suite** — the helpers (`setup_clusters`, platform detection helpers) are covered by unit tests under `tests/`.

## Prerequisites

- `kubectl` and / or `oc` on `PATH`.
- `helm` on `PATH` (optional — the helm inspection check is skipped silently when missing).
- `tar` (default everywhere; required for bundling).
- Two kubeconfigs with read access to:
  - **PXB cluster** — `pods`, `deployments`, `configmaps`, `services`, `secrets`, `pods/exec`, `apiservices`, `nodes`.
  - **App cluster** — `pods`, `deployments`, `configmaps`, `services`, `secrets`, `nodes`, `storagecluster`, `pods/exec`.
- `curl` and `bash` available inside the `px-backup`, `stork`, and `portworx` pods (they are by default).

## Usage

### Download and Execute

```bash
# Download the script
curl -O https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_post_install_check/px_post_install_check.sh

# Make it executable
chmod +x px_post_install_check.sh

# Run interactively
./px_post_install_check.sh
```

### Command-Line Flags

The CLI tool (`kubectl` or `oc`) is auto-detected per cluster. If both
binaries can reach the cluster, `oc` is preferred when the cluster
exposes the OpenShift API group.

| Flag | Description |
|------|-------------|
| `--pxb-kubeconfig PATH` | Kubeconfig for the PXB cluster. |
| `--app-kubeconfig PATH` | Kubeconfig for the app / source cluster. |
| `--pxb-ns NAME` | PX-Backup namespace (default: `central`). Auto-falls back to the namespace that hosts the `px-backup-ui` Service. |
| `--px-ns NAME` | Portworx namespace on the app cluster. Auto-resolved to the namespace hosting the `portworx-api` Service when PXE is installed; left unset when PXE is absent. |
| `--stork-ns NAME` | Stork namespace on the app cluster (default: `kube-system`). Auto-falls back to the namespace that hosts the `stork-service` Service. |
| `--endpoint URL` | Extra object-storage endpoint to test. Can be repeated. |
| `--self-signed-s3` | BackupLocation S3 endpoint uses HTTPS with a self-signed / privately-signed cert. Enables the CA-bundle wiring check across PXB / Stork / PXE. Skips the interactive prompt. |
| `--no-self-signed-s3` | Endpoint does not use a self-signed cert. Skips the CA-bundle wiring check and the prompt. |
| `--non-interactive`, `-y` | Skip all prompts. Fails loudly if a required value is missing. |
| `-h`, `--help` | Show help and exit. |

### Non-Interactive Example

```bash
./px_post_install_check.sh --non-interactive \
    --pxb-kubeconfig ~/pxb.yaml \
    --app-kubeconfig ~/app.yaml \
    --pxb-ns central --px-ns portworx --stork-ns portworx \
    --self-signed-s3 \
    --endpoint https://s3.example.com \
    --endpoint https://backup.internal:9000
```

### Interactive Prompts

When run without flags, the script prompts up-front for:

1. Path to the PXB kubeconfig.
2. Path to the app cluster kubeconfig.
3. PXB namespace and Stork namespace.
4. (Optional) Additional object-storage endpoints — one per line, blank to finish.
5. Whether the BackupLocation S3 endpoint uses a self-signed cert (y/n).

All inputs are collected before any cluster discovery starts, so the
operator can supply everything and walk away.

### Namespace Discovery

The PXB, Stork, and PXE namespaces are anchored on stable Service names
so the script keeps working when the components are installed in
non-default namespaces:

- **PXB namespace** — anchored on the `px-backup-ui` Service.
- **Stork namespace** — anchored on the `stork-service` Service.
- **PXE namespace** — anchored on the `portworx-api` Service.

If the resolved namespace does not contain the anchor Service, the
script searches the cluster for that Service and switches to the
namespace where it is found. If the anchor Service for **PXB** or
**Stork** is not found anywhere, the script aborts with `exit 2`:

```
[ERROR] [PXB cluster] PX-Backup is not installed on this cluster
        ('px-backup-ui' Service not found in any namespace). Aborting.
[ERROR] [App cluster] Stork is not installed on this cluster
        ('stork-service' Service not found in any namespace). Aborting.
```

This guards against running the dependent checks against a cluster
where the component is missing.

### Portworx Enterprise (Optional)

Portworx Enterprise is **not required**. After resolving the Stork
namespace, the script probes the app cluster for the `portworx-api`
Service:

- **Found** — `PXE_INSTALLED=true`. The script auto-corrects
  `PX_NAMESPACE` to the namespace hosting `portworx-api` (overriding
  any preset that points elsewhere).
- **Not found** — `PXE_INSTALLED=false`. The script emits a warning
  and skips the PXE-specific portions of every downstream check:
  - `proxy_check` — does not collect StorageCluster `spec.env`.
  - `object_storage_check` — does not run `curl` from a `name=portworx` pod.
  - `s3_cert_check` — does not run TLS verification from a `name=portworx` pod.
  - `s3_self_signed_cert_config_check` — skips the PXE wiring check.
  - `kdmp_config_check` — entirely skipped.
  - `storagecluster_dump_check` — entirely skipped.

PXB and Stork checks still run as usual.

## Output

### Bundle Archive

All dumps and the run log land inside a per-run bundle directory which
is compressed to a single `.tar.gz` on completion. The directory is
removed after a successful archive.

```
/tmp/px-post-install-check_<YYYYMMDD_HHMMSS>.tar.gz
```

Contents:

| File | Source |
|------|--------|
| `run.log` | Full run output with ANSI color codes stripped. |
| `kdmp-config.yaml` | `kube-system/kdmp-config` ConfigMap dump (app cluster). |
| `storagecluster.yaml` | `StorageCluster` CR dump (app cluster). |
| `helm-values-<release>.yaml` | `helm get values --all -o yaml` per `px-central` release. |
| `helm-history-<release>.txt` | `helm history` per `px-central` release. |

The final terminal line is the bundle path so it's easy to attach to a
support ticket:

```
[INFO] Bundle: /tmp/px-post-install-check_20260512_102207.tar.gz
```

### Summary Report

```
==========================================
  Post-Install Check Summary
==========================================

Errors (3):
  - PXB: SSL_CERT_DIR is not set on deployment 'px-backup'. ...
  - Stork: missing env var(s) on deployment 'stork': AWS_CA_BUNDLE SSL_CERT_DIR. ...
  - PXE: AWS_CA_BUNDLE not set in StorageCluster spec.env. ...
Warnings (2):
  - PXB and Stork have different canonical proxy values.
  - DISABLE_PX_CS_DISTRIBUTION='true'.

[INFO] Bundle: /tmp/px-post-install-check_20260512_102207.tar.gz
```

## Tests

Unit tests for the helper functions live under `tests/` and use a
mocked `kubectl` / `oc` (`tests/bin/`) so they run without a live
cluster:

```bash
bash px_post_install_check/tests/test_setup_clusters.sh
bash px_post_install_check/tests/test_platform_detection.sh
```

## Troubleshooting

### `Cannot reach cluster using <kubeconfig>`

The script runs `kubectl/oc --kubeconfig=<path> version` against each
kubeconfig before proceeding. Confirm the path is correct, the embedded
context is current, and any required VPN / bastion is up.

### TLS errors only on PXB / only on PXE

If the same endpoint passes from PXE but fails on PXB (or vice-versa),
the CA bundle is configured on one component but not the other.
Configure the CA bundle on both:

- **PXB**: `helm install ... --set caCertsSecretName=<secret>` — see [PXB on-prem cert config](https://docs.portworx.com/portworx-backup-on-prem/install/configure-certs/s3-cert-bkpcluster).
- **Stork**: set `AWS_CA_BUNDLE` and `SSL_CERT_DIR` on the `stork` Deployment — see [Stork cert config](https://docs.portworx.com/portworx-backup-on-prem/configure/configure-with-s3/s3-cert-appcluster).
- **PXE**: set `AWS_CA_BUNDLE` in `StorageCluster.spec.env` and mount the secret — see [PXE cert config](https://docs.portworx.com/portworx-enterprise/how-to-guides/certs).

### Stork → PXE node IPs unreachable on port 9001

The KDMP check probes direct connectivity from a Stork pod to each PXE
node IP on the OpenStorage API port (`9001`). When the customer network
blocks direct node-IP traffic (T-Mobile POC scenario), cloud-snap
backups will time out. Either open the network path or set
`DISABLE_PX_CS_DISTRIBUTION=true` in the `kdmp-config` ConfigMap so
cloud-snap traffic uses the PXE Service ClusterIP instead — see
[KDMP config parameters](https://docs.portworx.com/portworx-backup-on-prem/reference/configmap-parameters/kdmp-config-parameters#cloudsnap-configuration).
