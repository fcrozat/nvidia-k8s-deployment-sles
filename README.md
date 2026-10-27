# NVIDIA GPU & Network Operator Deployment

This repository provides a streamlined way to deploy the NVIDIA GPU Operator and NVIDIA Network Operator on a remote Kubernetes cluster (K3s or RKE2) running on SUSE Linux Enterprise Server (SLES). It supports multiple target environments (cloud instances, on-premises hardware, etc.) via a flexible per-target configuration.

## Overview

The `deploy.sh` script automates the following steps:

1. **Dependency Verification**: Checks for local (`kubectl`, `helm`) and remote (`podman`, etc.) dependencies. Removes `nvidia-container-toolkit` from the host if present (it conflicts with the GPU Operator).
2. **Cluster Management**: Detects or installs K3s/RKE2 on the target host.
3. **Local Access Configuration**: Fetches the remote `kubeconfig`, updates it with the target host address, and configures local `kubectl` access (with insecure TLS skip for ease of use).
4. **CoreDNS Tuning**: Configures CoreDNS to respect the host's `/etc/hosts`.
5. **In-Cluster Registry**: Deploys a private Docker registry within the cluster to host driver and operator images.
6. **Driver Image Setup**: Either builds the NVIDIA GPU driver container on the remote host, or pulls a prebuilt image. If the target cannot reach the internal registry directly (`NEEDS_MIRROR=true`), images are mirrored via the local system.
7. **DOCA Driver Image Setup (Optional)**: If `--build-doca-driver` is enabled, compiles the DOCA-OFED driver container using `doca-driver-build` (with support for SLES 16.0 and SLES 16.1 multi-flavor kernels such as `nvidia64kb` on `aarch64`) and pushes it to the in-cluster registry.
8. **Operator Installation**: Installs the NVIDIA GPU Operator and/or NVIDIA Network Operator via Helm, configured to use the local or prebuilt images. Optionally applies `NicClusterPolicy` if specified.

## Prerequisites

* **Local Machine**: `kubectl`, `helm`, and `ssh` client.
* **Remote Host**: SLES 15 SP6/SP7 recommended. SSH access with sudo privileges.
* **Network**: Ensure security groups/firewalls allow SSH and Kubernetes API access (typically port 6443).

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
| `USE_HELM_PRIVATE_REGISTRY` | Set to `true` (globally or per-target) to use a private Helm repository for the GPU Operator chart instead of the default NVIDIA repository. |
| `HELM_PRIVATE_URL` | **Global**: Base URL or full path to a private Helm chart for the GPU Operator. If it's a base URL (no `.tgz`), the filename is assumed to be `gpu-operator-${GPU_OPERATOR_VERSION}.tgz`. |
| `NGC_API_KEY` | **Global**: API Key for authenticating with the private Helm repository (used as the password with `$oauthtoken` as the username). |

See `config.sh.example` for the full template.

### Environment variable overrides

These environment variables can override config.sh values or control script behavior:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `TARGET_OS` | `DEFAULT_TARGET` from config.sh | Selects a target configuration (e.g. `15.7`, `16.0`, `16.1`, `onprem`, `vera72`). |
| `TARGET_HOST` | `HOST_<target>` from config.sh | Override the hostname or IP of the remote machine. |
| `TARGET_USER` | `USER_<target>` from config.sh | Override the SSH user. |
| `K8S_DISTRO` | `K8S_DISTRO_<target>` from config.sh | Override the Kubernetes distribution. |
| `RKE2_NO_RPM` | `false` | If `true`, installs RKE2 from the tarball (`INSTALL_RKE2_METHOD=tar`) instead of the RPM package. Useful when RKE2 RPMs are not available for the target OS (e.g. SLES 16). |
| `NEEDS_MIRROR` | `NEEDS_MIRROR_<target>` from config.sh | Override the mirroring behavior (`true` or `false`). |
| `DEPLOY_LOG` | `deploy-sles<VERSION>.log` | Path to the log file for the deployment output (auto-named with OS version). |
| `NVIDIA_DRIVER_VERSION` | _auto-detected_ | Version of the NVIDIA driver to build (`615.71.09` on SLES 16.1, `595.91.07` otherwise). |
| `GPU_OPERATOR_VERSION` | `v26.7.2` | Version of the GPU Operator to install. |
| `DRIVER_CONTAINER_REPO` | `https://github.com/SUSE/BCI-dockerfile-generator.git` | Git repository for driver container Dockerfiles. |
| `DRIVER_CONTAINER_BRANCH` | _auto-detected_ | Git branch for driver container repo (`16.1` for SLES 16.1, `16.0` for SLES 16.0, `sle15-sp7` for SLES 15.7). |
| `DRIVER_IMAGE_NAME` | `driver` | Name of the driver image to build and push. |
| `DRIVER_REPOSITORY` | _auto-derived_ | Override the prebuilt driver repository location (used with `USE_PREBUILT_CONTAINER=true`). |
| `USE_PREBUILT_CONTAINER` | `production` | If `production` (default), uses the public `registry.suse.com/third-party/nvidia`. If `true`, pulls pre-built images from the internal registry (configured in `config.sh`). If `false`, builds driver container locally. |
| `USE_UPSTREAM_GPU_OPERATOR` | `true` | If `true` (default), uses the upstream GPU Operator from NVIDIA. The upstream GPU Operator dynamically mounts host `/lib/modules` into precompiled driver daemonsets (`USE_PRECOMPILED=true` on versions `> v26.3.0`). For other configurations, `deploy.sh` injects the `/lib/modules` host mount into the operator manifest before enabling the driver. |
| `KERNEL_MODULE_TYPE` | `auto` | Type of kernel module to use (`auto`, `proprietary`, `open-gpu-kernel-modules`). |
| `USE_PRECOMPILED` | `false` | If `true`, enables precompiled driver containers in the GPU Operator (overridable per target with `USE_PRECOMPILED_<TARGET>`). The driver version in ClusterPolicy is automatically set to the branch (e.g. `615`), and when building locally (`USE_PREBUILT_CONTAINER=false`), the image is tagged following `<branch>-<kernel-version>-sles<version>` (e.g. `615-6.12.0-160100.1-nvidia64kb-sles16.1`). See [NVIDIA precompiled drivers docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html). |
| `GPU_OPERATOR_BRANCH` | _auto-detected_ | Override the GPU operator git branch. If not set, defaults to `precompiled_lib_modules_mount` when `USE_PRECOMPILED=true`, otherwise `suse_lib_modules`. Only used when `USE_UPSTREAM_GPU_OPERATOR=false`. |
| `GPU_OPERATOR_IMAGE` | _empty_ | Optional override for the GPU operator image. If set and `USE_UPSTREAM_GPU_OPERATOR=false`, this image will be mirrored to the in-cluster registry and used instead of building the operator from source. If `NEEDS_MIRROR=true`, the image is mirrored via the local system. |
| `USE_HELM_PRIVATE_REGISTRY` | `false` | If `true`, enables the use of a private Helm registry for the GPU Operator chart. Can be overridden per target. |
| `HELM_PRIVATE_URL` | _empty_ | **Global**: Base URL or full path to a private Helm chart for the GPU Operator. |
| `NGC_API_KEY` | _empty_ | **Global**: API Key for NGC authentication when `HELM_PRIVATE_URL` is used. |
| `DEPLOY_NETWORK_OPERATOR` | `false` | If `true`, deploys NVIDIA Network Operator via Helm (overridable per target with `DEPLOY_NETWORK_OPERATOR_<TARGET>` or CLI flag `--network-operator`). |
| `NETWORK_OPERATOR_ONLY` | `false` | If `true` (or CLI flag `--network-operator-only`), skips GPU Operator / driver builds and deploys only Network Operator. |
| `NETWORK_OPERATOR_VERSION` | `v26.7.0` | Version of the `nvidia/network-operator` Helm chart to install. |
| `NETWORK_OPERATOR_NAMESPACE` | `nvidia-network-operator` | Namespace for Network Operator (automatically labeled with privileged Pod Security Admission). |
| `NIC_CLUSTER_POLICY_FILE` | _empty_ | Optional path to a `NicClusterPolicy` YAML manifest to apply after deploying Network Operator (see `nic-cluster-policy.yaml.example`). |
| `BUILD_DOCA_DRIVER` | `false` | If `true` (or CLI flag `--build-doca-driver`), builds the precompiled DOCA-OFED driver container using `doca-driver-build` and pushes it to the in-cluster registry. Overridable per target with `BUILD_DOCA_DRIVER_<TARGET>`. |
| `DOCA_VERSION` | `3.5.0` | Version of DOCA sources to download (used with `BUILD_DOCA_DRIVER=true`). |
| `DOCA_OFED_VERSION` | `26.07-0.7.7.0` | Version of MLNX_OFED sources (used with `BUILD_DOCA_DRIVER=true`). |
| `DOCA_CONTAINER_VER` | `0` | Container version suffix for the DOCA driver image tag. |
| `DOCA_DRIVER_REPO` | `https://github.com/fcrozat/doca-driver-build.git` | Git repository for DOCA driver container builds. |
| `DOCA_DRIVER_BRANCH` | `SLES16` | Git branch for DOCA driver container builds (supports SLES 16.0 and SLES 16.1 multi-flavor kernels). |
| `DOCA_DRIVER_IMAGE` | `doca-driver` | Name of the DOCA driver image pushed to the in-cluster registry. |

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

# Deploy to SLES 16.1
TARGET_OS=16.1 ./deploy.sh

# Deploy to an on-premises host (if configured)
TARGET_OS=onprem ./deploy.sh

# Deploy to a baremetal host (if configured)
TARGET_OS=vera72 ./deploy.sh
```

#### Deploying with NVIDIA Network Operator and DOCA Driver

```bash
# Deploy GPU Operator and Network Operator together
TARGET_OS="vera72" ./deploy.sh --network-operator

# Deploy Network Operator and build/push precompiled DOCA driver container
TARGET_OS="vera72" ./deploy.sh --network-operator --build-doca-driver

# Deploy only the Network Operator and build/push DOCA driver container
TARGET_OS="vera72" ./deploy.sh --network-operator-only --build-doca-driver
```

#### Only install Kubernetes (k3s or rke2)

If you only want to install the Kubernetes cluster (K3s or RKE2) and fetch the kubeconfig without deploying the GPU Operator, use the `--k3s-only` or `--rke2-only` flags:

```bash
./deploy.sh --k3s-only
# OR
./deploy.sh --rke2-only
```

This will force the respective `K8S_DISTRO`, install/start the cluster on the target, fetch the kubeconfig locally, and then stop execution.

### 3. Verify the installation

Wait for the GPU Operator pods to be ready:

```bash
kubectl get pods -n gpu-operator
```

If Network Operator was deployed:

```bash
kubectl get pods -n nvidia-network-operator
kubectl get nicclusterpolicy
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

* `config.sh.example`: Template for private configuration (hosts, registries, mirroring). Copy to `config.sh`.
* `deploy.sh`: The main deployment orchestration script.
* `upgrade.sh`: Script to mirror a specific NVIDIA driver version and patch the ClusterPolicy.
* `container-registry.yaml`: Manifest for the in-cluster Docker registry.
* `cuda-test.yaml`: A simple CUDA vectorAdd pod to verify GPU functionality.
* `nic-cluster-policy.yaml.example`: Template for NVIDIA Network Operator `NicClusterPolicy` resource, including precompiled driver configuration.
