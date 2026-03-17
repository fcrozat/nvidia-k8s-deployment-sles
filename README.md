# NVIDIA GPU Operator Deployment

This repository provides a streamlined way to deploy the NVIDIA GPU Operator on a remote Kubernetes cluster (K3s or RKE2) running on SUSE Linux Enterprise Server (SLES). It supports multiple target environments (cloud instances, on-premises hardware, etc.) via a flexible per-target configuration.

## Overview

The `deploy.sh` script automates the following steps:

1.  **Dependency Verification**: Checks for local (`kubectl`, `helm`) and remote (`podman`, etc.) dependencies. Removes `nvidia-container-toolkit` from the host if present (it conflicts with the GPU Operator).
2.  **Cluster Management**: Detects or installs K3s/RKE2 on the target host.
3.  **Local Access Configuration**: Fetches the remote `kubeconfig`, updates it with the target host address, and configures local `kubectl` access (with insecure TLS skip for ease of use).
4.  **CoreDNS Tuning**: Configures CoreDNS to respect the host's `/etc/hosts`.
5.  **In-Cluster Registry**: Deploys a private Docker registry within the cluster to host driver and operator images.
6.  **Driver Image Setup**: Either builds the NVIDIA driver container on the remote host, or pulls a prebuilt image. If the target cannot reach the internal registry directly (`NEEDS_MIRROR=true`), images are mirrored via the local system.
7.  **GPU Operator Installation**: Installs the NVIDIA GPU Operator via Helm, configured to use the local or prebuilt images.

## Prerequisites

*   **Local Machine**: `kubectl`, `helm`, and `ssh` client.
*   **Remote Host**: SLES 15 SP6/SP7 recommended. SSH access with sudo privileges.
*   **Network**: Ensure security groups/firewalls allow SSH and Kubernetes API access (typically port 6443).

## Configuration

### Private configuration (`config.sh`)

All host-specific settings are stored in `config.sh` (gitignored). Each target is defined by a set of variables using the pattern `<VAR>_<target>`:

| Variable pattern | Description |
| :--- | :--- |
| `HOST_<target>` | Hostname or IP of the remote machine. |
| `USER_<target>` | SSH user for the remote machine. |
| `K8S_DISTRO_<target>` | Kubernetes distribution (`k3s` or `rke2`). |
| `NEEDS_MIRROR_<target>` | Set to `true` if the target cannot reach `INTERNAL_REGISTRY` directly (images will be mirrored via the local system). |
| `DEFAULT_TARGET` | Target to use when `TARGET_OS` is not set. |
| `INTERNAL_REGISTRY` | Internal registry domain (used for registries.yaml configuration and mirroring). |
| `INTERNAL_DRIVER_REGISTRY_*` | Full registry paths for prebuilt driver containers per SLES service pack. |
| `DEFAULT_UPGRADE_DRIVER_REPOSITORY` | Default prebuilt driver repository for `upgrade.sh`. |

See `config.sh.example` for the full template.

### Environment variable overrides

These environment variables can override config.sh values or control script behavior:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `TARGET_OS` | `DEFAULT_TARGET` from config.sh | Selects a target configuration (e.g. `15.7`, `16.0`, `onprem`). |
| `TARGET_HOST` | `HOST_<target>` from config.sh | Override the hostname or IP of the remote machine. |
| `TARGET_USER` | `USER_<target>` from config.sh | Override the SSH user. |
| `K8S_DISTRO` | `K8S_DISTRO_<target>` from config.sh | Override the Kubernetes distribution. |
| `NEEDS_MIRROR` | `NEEDS_MIRROR_<target>` from config.sh | Override the mirroring behavior (`true` or `false`). |
| `DEPLOY_LOG` | `deploy-sles<VERSION>.log` | Path to the log file for the deployment output (auto-named with OS version). |
| `NVIDIA_DRIVER_VERSION` | `580.126.09` | Version of the NVIDIA driver to build. |
| `GPU_OPERATOR_VERSION` | `v25.10.1` | Version of the GPU Operator to install. |
| `DRIVER_CONTAINER_BRANCH` | `sles15-refresh` | Git branch to use for the driver container repository. |
| `DRIVER_IMAGE_NAME` | `driver` | Name of the driver image to build and push. |
| `DRIVER_REPOSITORY` | _auto-derived_ | Override the prebuilt driver repository location (used with `USE_PREBUILT_CONTAINER=true`). |
| `USE_PREBUILT_CONTAINER` | `false` | If `true`, pulls pre-built images from the internal registry (configured in `config.sh`). If `production`, uses the public `registry.suse.com/third-party/nvidia`. |
| `USE_UPSTREAM_GPU_OPERATOR` | `false` | If `true`, uses the upstream GPU Operator from NVIDIA. If `false` (default), builds and uses a patched version with SUSE-specific modifications. |
| `KERNEL_MODULE_TYPE` | `auto` | Type of kernel module to use (`auto`, `proprietary`, `open-gpu-kernel-modules`). |
| `USE_PRECOMPILED` | `false` | If `true`, enables precompiled driver containers in the GPU Operator. The driver version is automatically set to the branch (e.g. `580` instead of `580.126.09`), and when building locally (`USE_PREBUILT_CONTAINER=false`), the container image tag follows the format `<branch>-<kernel-version>-sles<version>` (e.g. `580-5.14.21-150500.55.73-default-sles15.7`). Also switches GPU operator to `precompiled_lib_modules_mount` branch instead of `suse_lib_modules` (unless `GPU_OPERATOR_BRANCH` is set). See [NVIDIA precompiled drivers docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html). |
| `GPU_OPERATOR_BRANCH` | _auto-detected_ | Override the GPU operator git branch. If not set, defaults to `precompiled_lib_modules_mount` when `USE_PRECOMPILED=true`, otherwise `suse_lib_modules`. Only used when `USE_UPSTREAM_GPU_OPERATOR=false`. |

## Usage

### 1. Create your configuration file

```bash
cp config.sh.example config.sh
# Edit config.sh with your target hosts, registry URLs, and mirroring settings
```

### 2. Run the deployment script

```bash
chmod +x deploy.sh
./deploy.sh
```

To target a specific configuration defined in `config.sh`:

```bash
# Deploy to SLES 15.7
TARGET_OS=15.7 ./deploy.sh

# Deploy to SLES 16.0
TARGET_OS=16.0 ./deploy.sh

# Deploy to an on-premises host (if configured)
TARGET_OS=onprem ./deploy.sh
```

### 3. Verify the installation

Wait for the GPU Operator pods to be ready:

```bash
kubectl get pods -n gpu-operator
```

### 4. Run a CUDA test

Use the provided `cuda-test.yaml` to verify that a container can access the GPU:

```bash
kubectl apply -f cuda-test.yaml
# Wait for completion
kubectl logs gpu-pod
```

### 5. Upgrade the NVIDIA Driver

To upgrade to a different driver version without redeploying the entire operator:

```bash
NVIDIA_DRIVER_VERSION=580.126.09 ./upgrade.sh

# Or target a specific host
TARGET_OS=16.0 NVIDIA_DRIVER_VERSION=580.126.09 ./upgrade.sh
```

## Files

*   `config.sh.example`: Template for private configuration (hosts, registries, mirroring). Copy to `config.sh`.
*   `deploy.sh`: The main deployment orchestration script.
*   `upgrade.sh`: Script to mirror a specific NVIDIA driver version and patch the ClusterPolicy.
*   `container-registry.yaml`: Manifest for the in-cluster Docker registry.
*   `cuda-test.yaml`: A simple CUDA vectorAdd pod to verify GPU functionality.
