#!/bin/bash -ex
#
# need to configure ec2 instance with policy allowing kubectl remote control
#

# Load private configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
if [ -f "$SCRIPT_DIR/config.sh" ]; then
  source "$SCRIPT_DIR/config.sh"
else
  echo "Error: config.sh not found. Copy config.sh.example to config.sh and fill in your values."
  exit 1
fi

# Parse arguments
K3S_ONLY=false
RKE2_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
  --k3s-only)
    K3S_ONLY=true
    shift
    ;;
  --rke2-only)
    RKE2_ONLY=true
    shift
    ;;
  *)
    shift
    ;;
  esac
done

# Defaults (can be overridden by env vars)
# TARGET_OS selects a host configuration from config.sh (e.g. 15.7, 16.0, 16.1, onprem, vera72)
TARGET_KEY="${TARGET_OS:-$DEFAULT_TARGET}"
TARGET_KEY="${TARGET_KEY//./_}" # Replace dots for valid variable names
TARGET_KEY="${TARGET_KEY//-/_}" # Replace hyphens for valid variable names

host_var="HOST_${TARGET_KEY}"
user_var="USER_${TARGET_KEY}"
distro_var="K8S_DISTRO_${TARGET_KEY}"
mirror_var="NEEDS_MIRROR_${TARGET_KEY}"
helm_priv_reg_var="USE_HELM_PRIVATE_REGISTRY_${TARGET_KEY}"

if [ -z "${!host_var}" ]; then
  echo "Unknown TARGET_OS: $TARGET_OS (no HOST_${TARGET_KEY} defined in config.sh)"
  exit 1
fi

TARGET_HOST="${TARGET_HOST:-${!host_var}}"
TARGET_USER="${TARGET_USER:-${!user_var}}"
K8S_DISTRO="${K8S_DISTRO:-${!distro_var}}"
if [ "$K3S_ONLY" == "true" ]; then
  K8S_DISTRO="k3s"
fi
if [ "$RKE2_ONLY" == "true" ]; then
  K8S_DISTRO="rke2"
fi
NEEDS_MIRROR="${NEEDS_MIRROR:-${!mirror_var:-false}}"
use_prebuilt_var="USE_PREBUILT_CONTAINER_${TARGET_KEY}"
USE_PREBUILT_CONTAINER="${USE_PREBUILT_CONTAINER:-${!use_prebuilt_var:-production}}"
use_upstream_var="USE_UPSTREAM_GPU_OPERATOR_${TARGET_KEY}"
USE_UPSTREAM_GPU_OPERATOR="${USE_UPSTREAM_GPU_OPERATOR:-${!use_upstream_var:-true}}"
RKE2_NO_RPM="${RKE2_NO_RPM:-false}"
KERNEL_MODULE_TYPE="${KERNEL_MODULE_TYPE:-auto}"
use_precompiled_var="USE_PRECOMPILED_${TARGET_KEY}"
USE_PRECOMPILED="${USE_PRECOMPILED:-${!use_precompiled_var:-false}}"
GPU_OPERATOR_BRANCH="${GPU_OPERATOR_BRANCH:-}" # Optional override for GPU operator branch
GPU_OPERATOR_IMAGE="${GPU_OPERATOR_IMAGE:-}"   # Optional override for GPU operator image

# Handle private Helm registry settings
USE_HELM_PRIVATE_REGISTRY="${USE_HELM_PRIVATE_REGISTRY:-${!helm_priv_reg_var:-false}}"
# HELM_PRIVATE_URL and NGC_API_KEY are global (from environment or config.sh)

# Detect SLES version early for log filename
echo "Detecting SLES version on remote host..."
SLES=$(ssh $TARGET_USER@$TARGET_HOST 'source /etc/os-release && echo $VERSION_ID')
if [ -z "$SLES" ]; then
  echo "Failed to detect SLES version. Defaulting to 15.7"
  SLES=15.7
fi
echo "Detected SLES version: $SLES"

# Detect kernel version if using precompiled drivers
if [ "$USE_PRECOMPILED" == "true" ]; then
  echo "Detecting kernel version on remote host for precompiled drivers..."
  KERNEL_VERSION=$(ssh $TARGET_USER@$TARGET_HOST 'uname -r')
  if [ -z "$KERNEL_VERSION" ]; then
    echo "Error: Failed to detect kernel version. Required for USE_PRECOMPILED=true"
    exit 1
  fi
  echo "Detected kernel version: $KERNEL_VERSION"
fi

# Set up logging with OS version in filename
DEPLOY_LOG="${DEPLOY_LOG:-deploy-sles${SLES}.log}"
# Redirect all output to log file while still showing it in the terminal
exec > >(tee -a "$DEPLOY_LOG") 2>&1

echo "Targeting: $TARGET_USER@$TARGET_HOST (Distro: $K8S_DISTRO)"

# --- Local Dependency Checks ---
for cmd in kubectl helm; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Error: $cmd could not be found. Please install it."
    exit 1
  fi
done

# --- Remote Dependency Checks ---
# Install required packages on the remote host if they are not already present.
ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
  sudo zypper --non-interactive refresh || true
  for pkg in git-core podman make; do
    if ! rpm -q $pkg > /dev/null 2>&1; then
      echo "Installing remote package: $pkg"
      sudo zypper in -y $pkg || true
    fi
  done

  missing_pkgs=()
  for pkg in git-core podman make; do
    if ! rpm -q $pkg > /dev/null 2>&1; then
      missing_pkgs+=("$pkg")
    fi
  done
  if [ ${#missing_pkgs[@]} -gt 0 ]; then
    echo "Warning: Missing required packages: ${missing_pkgs[*]}"
    echo "Please ensure zypper repositories are enabled on the remote host (e.g. check 'zypper lr')."
  fi

  # nvidia-container-toolkit must NOT be installed on the host as it conflicts with the GPU Operator
  if rpm -q nvidia-container-toolkit > /dev/null 2>&1; then
    echo "Removing nvidia-container-toolkit from host (conflicts with GPU Operator)..."
    sudo zypper rm -y nvidia-container-toolkit
  fi
EOF

# get.k3s.io runs "semodule -r k3s" and then treats an already installed k3s-selinux
# RPM as a no-op, which leaves k3s running without its SELinux policy. Load the
# module from the .pp that RPM already ships - no download, no forced reinstall.
# shellcheck disable=SC2029
ensure_k3s_selinux_module() {
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
      rpm -q k3s-selinux > /dev/null 2>&1 || exit 0
      sudo semodule -l 2>/dev/null | grep -q '^k3s' && exit 0
      pp="$(rpm -ql k3s-selinux | grep '\.pp$' | head -1)"
      if [ -n "$pp" ]; then
        echo "Loading k3s SELinux module from $pp..."
        sudo semodule -i "$pp"
      fi
EOF
}

# --- Cluster Setup (K3s or RKE2) ---
if [ "$K8S_DISTRO" == "k3s" ]; then
  # Stop and disable RKE2 if it is deployed on the system
  echo "Checking if rke2 is deployed on remote host..."
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
      rke2_found=false
      for service in rke2-server rke2-agent; do
        if systemctl list-unit-files "${service}.service" >/dev/null 2>&1 || [ -f "/etc/systemd/system/${service}.service" ] || [ -f "/usr/lib/systemd/system/${service}.service" ] || [ -f "/lib/systemd/system/${service}.service" ]; then
          echo "rke2 is deployed (${service}). Stopping and disabling it..."
          sudo systemctl stop "${service}" >/dev/null 2>&1 || true
          sudo systemctl disable "${service}" >/dev/null 2>&1 || true
          rke2_found=true
        fi
      done

      if [ "$rke2_found" = true ]; then
        killall_cmd=""
        for path in /usr/local/bin/rke2-killall.sh /usr/bin/rke2-killall.sh /opt/rke2/bin/rke2-killall.sh /var/lib/rancher/rke2/bin/rke2-killall.sh; do
          if [ -x "$path" ]; then
            killall_cmd="$path"
            break
          fi
        done
        if [ -z "$killall_cmd" ] && command -v rke2-killall.sh >/dev/null 2>&1; then
          killall_cmd=$(command -v rke2-killall.sh)
        fi
        if [ -n "$killall_cmd" ]; then
          echo "Running $killall_cmd to clean up rke2..."
          sudo "$killall_cmd" >/dev/null 2>&1 || true
        fi
      fi
EOF

  # Remove rke2-selinux RPM if present (conflicts with k3s-selinux)
  echo "Removing rke2-selinux RPM if present..."
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
      if rpm -q rke2-selinux > /dev/null 2>&1; then
        echo "Removing rke2-selinux (conflicts with k3s-selinux)..."
        sudo zypper rm -y rke2-selinux
      fi
      # The rke2 SELinux module can remain loaded after the RPM is removed and
      # conflicts with the k3s one ("Conflicting name type transition rules", which
      # makes the k3s-selinux %posttrans semodule load fail). semodule -l prints
      # "<name> <version>", so match on the name only.
      if sudo semodule -l 2>/dev/null | grep -q '^rke2'; then
        echo "Removing leftover rke2 SELinux module..."
        sudo semodule -r rke2
      fi
EOF

  echo "Checking k3s status on remote host..."
  # Check if k3s service is active on the remote machine
  if ! ssh $TARGET_USER@$TARGET_HOST "sudo systemctl is-active --quiet k3s"; then
    echo "k3s not found or not active on remote host. Installing k3s..."
    # Use the official install script
    # Refresh repositories first so stale metadata doesn't cause 404s on package downloads
    ssh $TARGET_USER@$TARGET_HOST "sudo zypper --non-interactive refresh" || true
    if ! ssh $TARGET_USER@$TARGET_HOST "curl -sfL https://get.k3s.io | sudo sh -"; then
      # The k3s install script adds its own repo; refresh it and retry once
      echo "k3s install failed. Refreshing repositories and retrying..."
      ssh $TARGET_USER@$TARGET_HOST "sudo zypper --non-interactive refresh -f" || true
      ssh $TARGET_USER@$TARGET_HOST "curl -sfL https://get.k3s.io | sudo sh -"
    fi
    echo "k3s installed. Waiting for it to be ready..."
    # Wait for kubeconfig to be available
    until ssh $TARGET_USER@$TARGET_HOST "sudo test -f /etc/rancher/k3s/k3s.yaml"; do
      echo -n "."
      sleep 5
    done
    echo -e "\nk3s is ready."
  else
    echo "k3s is already installed and active on remote host."
  fi
  ensure_k3s_selinux_module
  REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  REGISTRY_FILE="/etc/rancher/k3s/registries.yaml"
  SERVICE_NAME="k3s"
  CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
elif [ "$K8S_DISTRO" == "rke2" ]; then
  # Stop and disable K3s if it is deployed on the system
  echo "Checking if k3s is deployed on remote host..."
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
      k3s_found=false
      for service in k3s k3s-agent; do
        if systemctl list-unit-files "${service}.service" >/dev/null 2>&1 || [ -f "/etc/systemd/system/${service}.service" ] || [ -f "/usr/lib/systemd/system/${service}.service" ] || [ -f "/lib/systemd/system/${service}.service" ]; then
          echo "k3s is deployed (${service}). Stopping and disabling it..."
          sudo systemctl stop "${service}" >/dev/null 2>&1 || true
          sudo systemctl disable "${service}" >/dev/null 2>&1 || true
          k3s_found=true
        fi
      done

      if [ "$k3s_found" = true ]; then
        killall_cmd=""
        for path in /usr/local/bin/k3s-killall.sh /usr/bin/k3s-killall.sh /opt/k3s/bin/k3s-killall.sh /var/lib/rancher/k3s/bin/k3s-killall.sh; do
          if [ -x "$path" ]; then
            killall_cmd="$path"
            break
          fi
        done
        if [ -z "$killall_cmd" ] && command -v k3s-killall.sh >/dev/null 2>&1; then
          killall_cmd=$(command -v k3s-killall.sh)
        fi
        if [ -n "$killall_cmd" ]; then
          echo "Running $killall_cmd to clean up k3s..."
          sudo "$killall_cmd" >/dev/null 2>&1 || true
        fi
      fi
EOF

  # Remove k3s-selinux RPM if present (conflicts with rke2)
  echo "Removing k3s-selinux RPM if present..."
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<'EOF'
      if rpm -q k3s-selinux > /dev/null 2>&1; then
        echo "Removing k3s-selinux (conflicts with rke2)..."
        sudo zypper rm -y k3s-selinux
      fi
EOF

  echo "Checking rke2 status on remote host..."
  if ! ssh $TARGET_USER@$TARGET_HOST "sudo systemctl is-active --quiet rke2-server"; then
    echo "rke2-server not found or not active on remote host. Installing rke2..."
    if [ "$RKE2_NO_RPM" == "true" ]; then
      echo "Installing rke2 without RPM (tarball method)..."
      ssh $TARGET_USER@$TARGET_HOST "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_METHOD=tar sh -"
    else
      ssh $TARGET_USER@$TARGET_HOST "curl -sfL https://get.rke2.io | sudo sh -"
    fi
    ssh $TARGET_USER@$TARGET_HOST "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service"
    echo "rke2 installed and started. Waiting for it to be ready..."
    # Wait for kubeconfig to be available
    until ssh $TARGET_USER@$TARGET_HOST "sudo test -f /etc/rancher/rke2/rke2.yaml"; do
      echo -n "."
      sleep 5
    done
    echo -e "\nrke2 is ready."
  else
    echo "rke2 is already installed and active on remote host."
  fi
  REMOTE_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
  REGISTRY_FILE="/etc/rancher/rke2/registries.yaml"
  SERVICE_NAME="rke2-server" # Assuming server node
  # RKE2 usually uses this socket path as well (symlinked or direct)
  CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
else
  echo "Unknown K8S_DISTRO: $K8S_DISTRO"
  exit 1
fi

# Configure firewall on remote host if firewalld is active
echo "Checking firewall on remote host..."
# shellcheck disable=SC2029
ssh $TARGET_USER@$TARGET_HOST "bash -s" <<EOF
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "firewalld is active on remote host. Opening required ports and trusting cluster subnets..."
    sudo firewall-cmd --permanent --add-port=6443/tcp
    if [ "$K8S_DISTRO" == "rke2" ]; then
      sudo firewall-cmd --permanent --add-port=9345/tcp
    fi
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 2>/dev/null || true
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 2>/dev/null || true
    sudo firewall-cmd --reload
  fi
EOF

# SLES version was already detected at the beginning of the script

# Fetch the kubeconfig from the remote node and update it for local access
KUBECONFIG_PATH="$PWD/${K8S_DISTRO}-sles${SLES}.yaml"
echo "Fetching kubeconfig from remote host..."
# shellcheck disable=SC2029
if ! ssh $TARGET_USER@$TARGET_HOST "sudo cat $REMOTE_KUBECONFIG" >$KUBECONFIG_PATH; then
  echo "Failed to fetch kubeconfig from remote host."
  exit 1
fi
sed -i "s/127.0.0.1/$TARGET_HOST/g" $KUBECONFIG_PATH
# Configure insecure-skip-tls-verify since the hostname won't match the cert
sed -i 's/certificate-authority-data:.*/insecure-skip-tls-verify: true/g' $KUBECONFIG_PATH
export KUBECONFIG=$KUBECONFIG_PATH
echo "Kubeconfig saved to $KUBECONFIG"

# Wait for the Kubernetes API to become reachable locally
echo "Waiting for Kubernetes API to be reachable at https://$TARGET_HOST:6443..."
api_ready=false
for _i in {1..30}; do
  if kubectl get nodes >/dev/null 2>&1; then
    api_ready=true
    break
  fi
  echo -n "."
  sleep 3
done
echo ""

if [ "$api_ready" != "true" ]; then
  echo "Error: Kubernetes API at https://$TARGET_HOST:6443 is not reachable."
  echo "Check if a firewall is blocking port 6443 on $TARGET_HOST, or check service status: ssh $TARGET_USER@$TARGET_HOST 'sudo systemctl status $SERVICE_NAME'"
  exit 1
fi

if [ "$K3S_ONLY" == "true" ] || [ "$RKE2_ONLY" == "true" ]; then
  echo "$K8S_DISTRO setup complete. Stopping here."
  exit 0
fi

# --- Configure CoreDNS ---
echo "Configuring CoreDNS to use /etc/hosts from the instance..."
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  hosts.server: |
    hosts /etc/hosts
EOF

echo "Waiting for CoreDNS deployment to be created..."
for _i in {1..30}; do
  if kubectl -n kube-system get deployment coredns >/dev/null 2>&1 ||
    kubectl -n kube-system get deployment rke2-coredns-rke2-coredns >/dev/null 2>&1 ||
    kubectl -n kube-system get deployment -l k8s-app=kube-dns >/dev/null 2>&1; then
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

echo "Restarting CoreDNS to apply the new configuration..."
# Detect CoreDNS deployment name
if kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
  COREDNS_DEPLOYMENT="coredns"
elif kubectl -n kube-system get deployment rke2-coredns-rke2-coredns >/dev/null 2>&1; then
  COREDNS_DEPLOYMENT="rke2-coredns-rke2-coredns"
else
  COREDNS_DEPLOYMENT=$(kubectl -n kube-system get deployment -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [ -n "$COREDNS_DEPLOYMENT" ]; then
  kubectl -n kube-system rollout restart deployment $COREDNS_DEPLOYMENT
  kubectl -n kube-system rollout status deployment/$COREDNS_DEPLOYMENT --timeout=5m
else
  echo "Warning: Could not find CoreDNS deployment. Skipping restart."
fi

# --- In-Cluster Registry Setup ---
kubectl config use-context default
kubectl get node -o wide
kubectl apply -f container-registry.yaml

# Wait for the registry to be ready
kubectl -n local-registry rollout status deployment/docker-registry --timeout=5m

# Get the ClusterIP of the registry service.
REGISTRY_IP=$(kubectl -n local-registry get service docker-registry -o jsonpath='{.spec.clusterIP}')
if [ -z "$REGISTRY_IP" ]; then
  echo "Failed to get registry ClusterIP"
  exit 1
fi
echo "Registry ClusterIP: $REGISTRY_IP"

# --- Configure K8s Node for insecure registry ---
# shellcheck disable=SC2029
CONFIG_CHECK=$(ssh $TARGET_USER@$TARGET_HOST "grep -q '$REGISTRY_IP:5000' $REGISTRY_FILE 2>/dev/null && grep -q '$INTERNAL_REGISTRY' $REGISTRY_FILE 2>/dev/null && echo 'CONFIGURED' || true")

if [ "$CONFIG_CHECK" == "CONFIGURED" ]; then
  echo "Cluster already configured for insecure registry."
else
  echo "Configuring node to trust the insecure registry..."
  # shellcheck disable=SC2087
  ssh $TARGET_USER@$TARGET_HOST "bash -s" <<EOF
set -e
# Ensure dir exists (likely already does)
sudo mkdir -p $(dirname $REGISTRY_FILE)
cat << REG_EOF | sudo tee $REGISTRY_FILE
mirrors:
  "$REGISTRY_IP:5000":
    endpoint:
      - "http://$REGISTRY_IP:5000"
  "$INTERNAL_REGISTRY":
    endpoint:
      - "https://$INTERNAL_REGISTRY"
configs:
  "$INTERNAL_REGISTRY":
    tls:
      insecure_skip_verify: true
REG_EOF
echo "Restarting service $SERVICE_NAME to apply registry configuration..."
sudo systemctl restart $SERVICE_NAME
EOF

  # Wait for the cluster to become ready again
  echo "Waiting for Kubernetes API to be ready after restart..."
  until kubectl get nodes &>/dev/null; do
    echo -n "."
    sleep 5
  done
  echo -e "\nKubernetes API is ready."
fi

# --- Remote Container Build and Push ---
DRIVER_CONTAINER_REPO="${DRIVER_CONTAINER_REPO:-https://github.com/SUSE/BCI-dockerfile-generator.git}"

if [ -z "$NVIDIA_DRIVER_VERSION" ]; then
  driver_ver_var="NVIDIA_DRIVER_VERSION_${TARGET_KEY}"
  if [ -n "${!driver_ver_var}" ]; then
    NVIDIA_DRIVER_VERSION="${!driver_ver_var}"
  elif [[ "$SLES" == "16.1"* ]]; then
    NVIDIA_DRIVER_VERSION="615.71.09"
  else
    NVIDIA_DRIVER_VERSION="595.91.07"
  fi
fi

GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.2}"
if [[ "$GPU_OPERATOR_VERSION" != v* ]]; then
  GPU_OPERATOR_VERSION="v${GPU_OPERATOR_VERSION}"
fi
SLES_MAJOR="${SLES%%.*}"
if [ -z "$DRIVER_CONTAINER_BRANCH" ]; then
  driver_branch_var="DRIVER_CONTAINER_BRANCH_${TARGET_KEY}"
  if [ -n "${!driver_branch_var}" ]; then
    DRIVER_CONTAINER_BRANCH="${!driver_branch_var}"
  elif [[ "$SLES" == "15.7"* ]]; then
    DRIVER_CONTAINER_BRANCH="sle15-sp7"
  elif [[ "$SLES" == "16.0"* ]]; then
    DRIVER_CONTAINER_BRANCH="16.0"
  elif [[ "$SLES" == "16.1"* ]]; then
    DRIVER_CONTAINER_BRANCH="16.1"
  elif [[ "$SLES" == "15"* ]]; then
    DRIVER_CONTAINER_BRANCH="sle15-sp7"
  else
    DRIVER_CONTAINER_BRANCH="${SLES}"
  fi
fi
DRIVER_IMAGE_NAME="${DRIVER_IMAGE_NAME:-driver}"

# SLES version was already detected earlier for kubeconfig naming
# For precompiled drivers, use branch-kernel-os format; otherwise use version-os format
if [ "$USE_PRECOMPILED" == "true" ]; then
  DRIVER_BRANCH="${NVIDIA_DRIVER_VERSION%%.*}"
  FINAL_REGISTRY_TAG="${DRIVER_BRANCH}-${KERNEL_VERSION}-sles${SLES}"
else
  FINAL_REGISTRY_TAG="${NVIDIA_DRIVER_VERSION}-sles${SLES}"
fi

if [ "$USE_PREBUILT_CONTAINER" != "false" ]; then
  if [ "$USE_PREBUILT_CONTAINER" == "production" ]; then
    PREBUILT_DRIVER_REPOSITORY="registry.suse.com/third-party/nvidia"
  else
    if [[ "$SLES" == "15.6" ]]; then
      DEFAULT_INTERNAL_REGISTRY="$INTERNAL_DRIVER_REGISTRY_15SP6"
    elif [[ "$SLES" == "15.7" ]]; then
      DEFAULT_INTERNAL_REGISTRY="$INTERNAL_DRIVER_REGISTRY_15SP7"
    else
      DEFAULT_INTERNAL_REGISTRY="$INTERNAL_DRIVER_REGISTRY_16"
    fi
    PREBUILT_DRIVER_REPOSITORY=${DRIVER_REPOSITORY:-"$DEFAULT_INTERNAL_REGISTRY"}
  fi
  PREBUILT_DRIVER_IMAGE="${PREBUILT_DRIVER_REPOSITORY}/${DRIVER_IMAGE_NAME}:${FINAL_REGISTRY_TAG}"

  # Mirror if target cannot reach internal registry directly
  if [[ "$NEEDS_MIRROR" == "true" && "$USE_PREBUILT_CONTAINER" != "production" && "$PREBUILT_DRIVER_REPOSITORY" == *"$INTERNAL_REGISTRY"* ]]; then
    echo "Target needs mirroring and fetching from $INTERNAL_REGISTRY, mirroring prebuilt image via local system..."
    DRIVER_REPOSITORY="${REGISTRY_IP}:5000/nvidia"
    if ! podman pull "$PREBUILT_DRIVER_IMAGE"; then
      echo "Error: Failed to pull prebuilt driver image $PREBUILT_DRIVER_IMAGE"
      exit 1
    fi
    if ! podman save "$PREBUILT_DRIVER_IMAGE" | ssh $TARGET_USER@$TARGET_HOST "podman load"; then
      echo "Error: Failed to transfer prebuilt driver image to remote host"
      exit 1
    fi
  else
    DRIVER_REPOSITORY="$PREBUILT_DRIVER_REPOSITORY"
  fi
  echo "Using driver repository: $DRIVER_REPOSITORY"

  # Mirror GPU operator image if needed
  if [[ -n "$GPU_OPERATOR_IMAGE" && "$NEEDS_MIRROR" == "true" ]]; then
    echo "Target needs mirroring and GPU_OPERATOR_IMAGE is set, mirroring via local system..."
    if ! podman pull "$GPU_OPERATOR_IMAGE"; then
      echo "Error: Failed to pull GPU operator image $GPU_OPERATOR_IMAGE"
      exit 1
    fi
    if ! podman save "$GPU_OPERATOR_IMAGE" | ssh $TARGET_USER@$TARGET_HOST "podman load"; then
      echo "Error: Failed to transfer GPU operator image to remote host"
      exit 1
    fi
  fi
else
  DRIVER_REPOSITORY="${REGISTRY_IP}:5000/nvidia"
fi

echo "Building and pushing container on remote host..."
if ! ssh $TARGET_USER@$TARGET_HOST \
  NVIDIA_DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" \
  GPU_OPERATOR_VERSION="$GPU_OPERATOR_VERSION" \
  GPU_OPERATOR_BRANCH="$GPU_OPERATOR_BRANCH" \
  GPU_OPERATOR_IMAGE="$GPU_OPERATOR_IMAGE" \
  SLES="$SLES" \
  FINAL_REGISTRY_TAG="$FINAL_REGISTRY_TAG" \
  REGISTRY_IP="$REGISTRY_IP" \
  DRIVER_CONTAINER_REPO="$DRIVER_CONTAINER_REPO" \
  DRIVER_CONTAINER_BRANCH="$DRIVER_CONTAINER_BRANCH" \
  USE_PREBUILT_CONTAINER="$USE_PREBUILT_CONTAINER" \
  USE_UPSTREAM_GPU_OPERATOR="$USE_UPSTREAM_GPU_OPERATOR" \
  USE_PRECOMPILED="$USE_PRECOMPILED" \
  DRIVER_IMAGE_NAME="$DRIVER_IMAGE_NAME" \
  NEEDS_MIRROR="$NEEDS_MIRROR" \
  INTERNAL_REGISTRY="$INTERNAL_REGISTRY" \
  PREBUILT_DRIVER_IMAGE="$PREBUILT_DRIVER_IMAGE" \
  PREBUILT_DRIVER_REPOSITORY="$PREBUILT_DRIVER_REPOSITORY" \
  'bash -s' <<'EOF'
set -e

# Derive major driver branch from version (e.g. 580.126.09 -> 580)
DRIVER_BRANCH="${NVIDIA_DRIVER_VERSION%%.*}"

# Derive driver generation from major version
if [ "$DRIVER_BRANCH" -lt 460 ]; then
  DRIVER_GENERATION="G04"
elif [ "$DRIVER_BRANCH" -le 545 ]; then
  DRIVER_GENERATION="G05"
elif [ "$DRIVER_BRANCH" -le 580 ]; then
  DRIVER_GENERATION="G06"
else
  DRIVER_GENERATION="G07"
fi
echo "Driver branch: $DRIVER_BRANCH, Driver generation: $DRIVER_GENERATION"

# Enable public cloud way to access suseconnect
sudo systemctl enable --now containerbuild-regionsrv || true

if [ "$USE_PREBUILT_CONTAINER" != "false" ]; then
  if [[ "$NEEDS_MIRROR" == "true" && "$USE_PREBUILT_CONTAINER" != "production" && "$PREBUILT_DRIVER_IMAGE" == *"$INTERNAL_REGISTRY"* ]]; then
    echo "Mirroring $PREBUILT_DRIVER_IMAGE to $REGISTRY_IP:5000/nvidia/$DRIVER_IMAGE_NAME:$FINAL_REGISTRY_TAG ..."
    # Image should already be loaded by local system when mirroring is needed
    podman push --tls-verify=false "$PREBUILT_DRIVER_IMAGE" "$REGISTRY_IP:5000/nvidia/$DRIVER_IMAGE_NAME:$FINAL_REGISTRY_TAG"
  else
    echo "Skipping driver build/push (using prebuilt driver container directly from $PREBUILT_DRIVER_IMAGE)."
  fi
else
  REPO_URL="${DRIVER_CONTAINER_REPO:-https://github.com/SUSE/BCI-dockerfile-generator.git}"
  BRANCH="$DRIVER_CONTAINER_BRANCH"

  # Determine repo checkout directory name
  REPO_NAME=$(basename "$REPO_URL" .git)
  REPO_DIR="$HOME/checkout/nvidia/$REPO_NAME"

  if [ ! -d "$REPO_DIR" ]; then
    mkdir -p ~/checkout/nvidia
    cd ~/checkout/nvidia
    git clone -b "$BRANCH" "$REPO_URL"
  else
    cd "$REPO_DIR"
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
      git fetch origin
      git switch "$BRANCH"
    fi
    git pull
  fi

  LOCAL_BUILD_TAG="nvidia/nvidia-gpu-driver:$NVIDIA_DRIVER_VERSION"

  # Check for BCI-dockerfile-generator layout (nvidia-driver-image directory)
  if [ -d "$REPO_DIR/nvidia-driver-image" ]; then
    cd "$REPO_DIR/nvidia-driver-image"

    # Reset any previous edits to ensure clean starting state
    git checkout -- . 2>/dev/null || true

    # Select Dockerfile based on driver branch and kernel page size (64kb)
    IS_64KB=false
    if uname -r | grep -q "64kb" || [ "$(getconf PAGESIZE 2>/dev/null)" = "65536" ]; then
      IS_64KB=true
    fi

    DOCKERFILE=""
    if [ "$IS_64KB" = true ] && [ -f "Dockerfile.driver-${DRIVER_BRANCH}-64kb" ]; then
      DOCKERFILE="Dockerfile.driver-${DRIVER_BRANCH}-64kb"
    elif [ -f "Dockerfile.driver-${DRIVER_BRANCH}" ]; then
      DOCKERFILE="Dockerfile.driver-${DRIVER_BRANCH}"
    elif [ "$IS_64KB" = true ] && ls Dockerfile.driver-*-64kb >/dev/null 2>&1; then
      DOCKERFILE=$(ls -1 Dockerfile.driver-*-64kb | sort -V | tail -n 1)
    elif ls Dockerfile.driver-* >/dev/null 2>&1; then
      DOCKERFILE=$(ls -1 Dockerfile.driver-* | grep -v 64kb | sort -V | tail -n 1)
    else
      DOCKERFILE="Dockerfile"
    fi

    echo "Using Dockerfile: $DOCKERFILE"

    # Check if host uses kernel-nvidia64kb (e.g. SLES for NVIDIA)
    IS_NVIDIA64KB=false
    if uname -r | grep -q "nvidia64kb" || rpm -q kernel-nvidia64kb >/dev/null 2>&1; then
      IS_NVIDIA64KB=true
    fi

    if [ "$IS_NVIDIA64KB" = true ]; then
      echo "SLES for NVIDIA detected (kernel-nvidia64kb). Adapting Dockerfile to use kernel-nvidia64kb / kernel-nvidia64kb-devel..."
      python3 - "$DOCKERFILE" <<'PY'
import sys

dockerfile_path = sys.argv[1]
with open(dockerfile_path, "r") as f:
    lines_in = f.read().splitlines()

lines_out = []
in_open_builder = False
skip_kernel = False

for line in lines_in:
    if line.startswith("FROM ") and "open-driver-builder" in line:
        in_open_builder = True
    elif line.startswith("FROM ") and in_open_builder:
        in_open_builder = False

    # 1. Install dkms with rpm --nodeps before zypper to avoid missing kernel-syms requirement
    if in_open_builder and "zypper -n" in line and "install" in line:
        lines_out.append("        rpm -ivh --nodeps /tmp/dkms-*.rpm; \\")
        lines_out.append(line)
        continue

    # Omit dkms from zypper install arguments
    if in_open_builder and "/tmp/dkms-" in line:
        continue

    if skip_kernel:
        if line.strip().startswith("fi"):
            skip_kernel = False
            lines_out.append(line)
        continue

    # 2. In open-driver-builder, replace kernel-64kb / signed kmp packages with kernel-nvidia64kb kernel-nvidia64kb-devel
    if in_open_builder and "/tmp/kernel-64kb" in line:
        lines_out.append("            kernel-nvidia64kb kernel-nvidia64kb-devel; \\")
        skip_kernel = True
        continue

    # 3. Comment out COPY lines for kernel and signed kmp packages
    if line.startswith("COPY kernel-") or line.startswith("COPY nvidia-open-driver-"):
        lines_out.append("# " + line)
        continue

    # 4. In builder stage, replace rpm install of signed kmp with true
    if "rpm --root /target -ivh" in line:
        lines_out.append("        true; \\")
        continue
    if "nvidia-open-driver-G07-signed-cuda-kmp" in line and not in_open_builder:
        continue

    # 5. Target nvidia64kb kernel in dkms autoinstall
    if "dkms autoinstall" in line:
        lines_out.append(line.replace("*-64kb", "*nvidia64kb"))
        continue

    lines_out.append(line)

with open(dockerfile_path, "w") as f:
    f.write("\n".join(lines_out) + "\n")
PY
    fi

    # Ensure host Zypp repositories and credentials are accessible during container build
    BUILD_MOUNTS=()
    sudo mkdir -p /etc/containers
    for p in /etc/SUSEConnect /etc/zypp/credentials.d /etc/zypp/repos.d /etc/zypp/services.d; do
      if [ -e "$p" ]; then
        grep -q "^$p:$p" /etc/containers/mounts.conf 2>/dev/null || echo "$p:$p" | sudo tee -a /etc/containers/mounts.conf >/dev/null
        BUILD_MOUNTS+=("-v" "$p:$p:ro")
      fi
    done

    # Ensure zypper auto-imports GPG keys and remove OBS-internal signing dependency if not present
    sed -i 's/zypper -n install/zypper -n --gpg-auto-import-keys install/g' "$DOCKERFILE"
    sed -i 's/pesign-obs-integration //g' "$DOCKERFILE"

    # Download required RPM packages referenced in #!RemoteAssetUrl comments
    echo "Downloading required RPM packages for $DOCKERFILE ..."
    while read -r prefix url rest || [ -n "$prefix" ]; do
      [ "$prefix" = "#!RemoteAssetUrl:" ] || continue
      [ -n "$url" ] || continue
      read -r first_rest _ <<< "$rest"
      if [ -n "$first_rest" ] && [[ "$first_rest" != sha256:* ]]; then
        pkg_file="$first_rest"
      else
        pkg_file="${url##*/}"
      fi

      # Skip kernel-64kb and kmp downloads when using kernel-nvidia64kb from repository
      if [ "$IS_NVIDIA64KB" = true ]; then
        if [[ "$pkg_file" == kernel-* || "$pkg_file" == nvidia-open-driver-* ]]; then
          echo "Skipping $pkg_file (using kernel-nvidia64kb from repository)."
          continue
        fi
      fi

      if [ ! -f "$pkg_file" ]; then
        echo "Downloading $pkg_file from $url ..."
        curl -fSL --retry 3 --retry-delay 2 -o "$pkg_file" "$url"
      else
        echo "$pkg_file already downloaded."
      fi
    done < "$DOCKERFILE"

    echo "Running: podman build --network=host ${BUILD_MOUNTS[*]} -f $DOCKERFILE -t $LOCAL_BUILD_TAG ."
    podman build --network=host "${BUILD_MOUNTS[@]}" -f "$DOCKERFILE" -t "$LOCAL_BUILD_TAG" .
  else
    # Fallback to legacy gpu-driver-container layout
    SLES_MAJOR="${SLES%%.*}"
    if [ -d "sle${SLES_MAJOR}" ]; then
      OS_DIR="sle${SLES_MAJOR}"
    else
      OS_DIR="sle15"
    fi

    if [[ "$BRANCH" == *"packages"* || "$BRANCH" == *"cuda"* ]]; then
      BUILD_DIR="${OS_DIR}/official-packages"
    else
      BUILD_DIR="${OS_DIR}"
    fi
    echo "Using branch: $BRANCH"
    echo "Build directory: $BUILD_DIR"

    if [ ! -d "$BUILD_DIR" ]; then
      echo "Error: Driver container build directory '$BUILD_DIR' not found in branch '$BRANCH'."
      exit 1
    fi
    cd "$REPO_DIR/$BUILD_DIR"

    # For SLES 16+, ensure Dockerfile uses BCI base image instead of legacy sle15
    if [ "${SLES_MAJOR:-15}" -ge 16 ] && [ -f Dockerfile ]; then
      sed -i "s|registry.suse.com/suse/sle15:\$SLES_VERSION|registry.suse.com/bci/bci-base:\$SLES_VERSION|g; s|registry.suse.com/suse/sle15:|registry.suse.com/bci/bci-base:|g" Dockerfile
    fi

    # Determine architecture for TARGETARCH build-arg (NVIDIA CUDA repo uses sbsa for arm64)
    HOST_ARCH=$(uname -m)
    if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
      BUILD_ARCH="sbsa"
    else
      BUILD_ARCH="amd64"
    fi

    if [ "$DRIVER_CONTAINER_BRANCH" == "cuda-combined-container" ]; then
      # Build additional images
      echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH --build-arg TARGETARCH=$BUILD_ARCH -t nvidia/driver-open:$NVIDIA_DRIVER_VERSION-sles$SLES -f Dockerfile.open"
      podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH" --build-arg TARGETARCH="$BUILD_ARCH" -t "nvidia/driver-open:$NVIDIA_DRIVER_VERSION-sles$SLES" -f Dockerfile.open
      echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH --build-arg TARGETARCH=$BUILD_ARCH -t nvidia/driver-closed:$NVIDIA_DRIVER_VERSION-sles$SLES -f Dockerfile.closed"
      podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH" --build-arg TARGETARCH="$BUILD_ARCH" -t "nvidia/driver-closed:$NVIDIA_DRIVER_VERSION-sles$SLES" -f Dockerfile.closed
    fi

    # Build the driver image
    if [ "$USE_PRECOMPILED" == "true" ]; then
      echo "Building precompiled driver image with tag: $LOCAL_BUILD_TAG"
    fi
    echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH --build-arg TARGETARCH=$BUILD_ARCH -t $LOCAL_BUILD_TAG ."
    podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH" --build-arg TARGETARCH="$BUILD_ARCH" -t "$LOCAL_BUILD_TAG" .
  fi

  # Push the image with the appropriate tag
  if [ "$USE_PRECOMPILED" == "true" ]; then
    echo "Pushing precompiled driver image as $REGISTRY_IP:5000/nvidia/$DRIVER_IMAGE_NAME:$FINAL_REGISTRY_TAG (format: branch-kernel-os)"
  else
    echo "Pushing driver image as $REGISTRY_IP:5000/nvidia/$DRIVER_IMAGE_NAME:$FINAL_REGISTRY_TAG"
  fi
  podman push --tls-verify=false "$LOCAL_BUILD_TAG" "$REGISTRY_IP:5000/nvidia/$DRIVER_IMAGE_NAME:$FINAL_REGISTRY_TAG"
fi

if [ "$USE_UPSTREAM_GPU_OPERATOR" != "true" ]; then
  if [ -n "$GPU_OPERATOR_IMAGE" ]; then
    echo "Mirroring GPU operator image $GPU_OPERATOR_IMAGE to $REGISTRY_IP:5000/nvidia/cloud-native/gpu-operator:$GPU_OPERATOR_VERSION ..."
    # If NEEDS_MIRROR is true, the image was already loaded by the local system.
    if [[ "$NEEDS_MIRROR" != "true" ]]; then
       podman pull "$GPU_OPERATOR_IMAGE"
    fi
    podman tag "$GPU_OPERATOR_IMAGE" "nvcr.io/nvidia/cloud-native/gpu-operator:$GPU_OPERATOR_VERSION"
  else
    # Clone the gpu-operator container repo
    # Determine which branch to use
    if [ -n "$GPU_OPERATOR_BRANCH" ]; then
      # User explicitly specified a branch
      BRANCH="$GPU_OPERATOR_BRANCH"
    elif [ "$USE_PRECOMPILED" == "true" ]; then
      # Use precompiled branch when USE_PRECOMPILED=true
      BRANCH=precompiled_lib_modules_mount
    else
      # Default branch
      BRANCH=suse_lib_modules
    fi
    echo "Using GPU operator branch: $BRANCH"

    if [ ! -d "$HOME/checkout/nvidia/gpu-operator" ]; then
      mkdir -p ~/checkout/nvidia
      cd ~/checkout/nvidia
      if ! git clone -b $BRANCH https://github.com/fcrozat/gpu-operator.git; then
        echo "Error: Failed to clone GPU operator repository with branch $BRANCH"
        echo "The branch may not exist yet. Please specify GPU_OPERATOR_BRANCH or use USE_UPSTREAM_GPU_OPERATOR=true"
        exit 1
      fi
      cd gpu-operator
    else
      cd ~/checkout/nvidia/gpu-operator
      # Fetch to ensure we have latest refs
      git fetch origin
      # Check if branch exists
      if ! git rev-parse --verify origin/$BRANCH >/dev/null 2>&1; then
        echo "Error: Branch $BRANCH does not exist in the repository"
        echo "Available branches:"
        git branch -r | grep -v HEAD
        echo ""
        echo "Solutions:"
        echo "  1. Set GPU_OPERATOR_BRANCH to an existing branch"
        echo "  2. Use USE_UPSTREAM_GPU_OPERATOR=true to skip custom operator build"
        echo "  3. Create the $BRANCH branch in the repository"
        exit 1
      fi
      git switch $BRANCH
      git pull
    fi

    # Build the gpu-operator image
    echo "Running: make DOCKER=podman DOCKER_BUILD_OPTIONS=\"--from registry.suse.com/bci/golang:1.25\" build-image"
    make DOCKER=podman DOCKER_BUILD_OPTIONS="--from registry.suse.com/bci/golang:1.25"  build-image
  fi

  # Push the image
  echo "Pushing image to in-cluster registry..."
  podman push --tls-verify=false "nvcr.io/nvidia/cloud-native/gpu-operator:$GPU_OPERATOR_VERSION" "$REGISTRY_IP:5000/nvidia/cloud-native/gpu-operator:$GPU_OPERATOR_VERSION"
else
  echo "Skipping custom GPU operator build (using upstream version)."
fi

EOF
then
  echo "Remote build and push failed."
  exit 1
fi

# --- Local Helm Install ---
RELEASE_NAME=gpu-operator-release
NAMESPACE=gpu-operator

patch_upstream_precompiled_driver_manifest() {
  local override_dir override_file patched_file operator_pod state_driver_manifest_path

  echo "Preparing upstream GPU Operator override so precompiled driver pods mount host /lib/modules..."
  kubectl -n "$NAMESPACE" rollout status deployment/gpu-operator --timeout=5m

  operator_pod=$(kubectl -n "$NAMESPACE" get pods -l app=gpu-operator -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$operator_pod" ]; then
    echo "Error: Failed to find the gpu-operator pod needed to extract the upstream driver manifest."
    exit 1
  fi

  if kubectl -n "$NAMESPACE" exec "$operator_pod" -- test -f /opt/gpu-operator/state-driver/0500_daemonset.yaml; then
    state_driver_manifest_path=/opt/gpu-operator/state-driver/0500_daemonset.yaml
  elif kubectl -n "$NAMESPACE" exec "$operator_pod" -- test -f /opt/gpu-operator/manifests/state-driver/0500_daemonset.yaml; then
    state_driver_manifest_path=/opt/gpu-operator/manifests/state-driver/0500_daemonset.yaml
  else
    echo "Error: Could not find state-driver/0500_daemonset.yaml in the gpu-operator pod."
    exit 1
  fi

  override_dir=$(mktemp -d)
  override_file="$override_dir/0500_daemonset.yaml"

  if ! kubectl -n "$NAMESPACE" exec "$operator_pod" -- cat "$state_driver_manifest_path" >"$override_file"; then
    echo "Error: Failed to extract $state_driver_manifest_path from the gpu-operator pod."
    rm -rf "$override_dir"
    exit 1
  fi

  if ! grep -Fq 'name: lib-modules' "$override_file"; then
    patched_file="$override_dir/0500_daemonset.patched.yaml"

    if ! awk '
      BEGIN {
        in_mount_nv = 0
        in_volume_nv = 0
        mount_done = 0
        volume_done = 0
      }

      {
        if (!mount_done && $0 == "          {{- if and .AdditionalConfigs .AdditionalConfigs.VolumeMounts }}") {
          print "          - name: lib-modules"
          print "            mountPath: /run/host/lib/modules"
          print "            readOnly: true"
          mount_done = 1
        }

        if (!volume_done && $0 == "        {{- if and .AdditionalConfigs .AdditionalConfigs.Volumes }}") {
          print "        - name: lib-modules"
          print "          hostPath:"
          print "            path: /lib/modules"
          print "            type: Directory"
          volume_done = 1
        }

        if (!volume_done && $0 == "        - name: driver-startup-probe-script") {
          print "        - name: lib-modules"
          print "          hostPath:"
          print "            path: /lib/modules"
          print "            type: Directory"
          volume_done = 1
        }

        if (!mount_done && $0 == "        startupProbe:") {
          print "          - name: lib-modules"
          print "            mountPath: /run/host/lib/modules"
          print "            readOnly: true"
          mount_done = 1
        }

        print

        if ($0 == "          - name: nv-firmware") {
          in_mount_nv = 1
        } else if (in_mount_nv && $0 ~ /^          - name:/) {
          in_mount_nv = 0
        }

        if ($0 == "        - name: nv-firmware") {
          in_volume_nv = 1
        } else if (in_volume_nv && $0 ~ /^        - name:/) {
          in_volume_nv = 0
        }

        if (!mount_done && in_mount_nv && $0 == "            mountPath: /lib/firmware") {
          print "          - name: lib-modules"
          print "            mountPath: /run/host/lib/modules"
          print "            readOnly: true"
          mount_done = 1
          in_mount_nv = 0
        }

        if (!volume_done && in_volume_nv && $0 == "            type: DirectoryOrCreate") {
          print "        - name: lib-modules"
          print "          hostPath:"
          print "            path: /lib/modules"
          print "            type: Directory"
          volume_done = 1
          in_volume_nv = 0
        }
      }

      END {
        if (!mount_done || !volume_done) {
          exit 1
        }
      }
    ' "$override_file" >"$patched_file"; then
      echo "Error: Failed to patch the upstream state-driver manifest with the /lib/modules mount."
      rm -rf "$override_dir"
      exit 1
    fi

    mv "$patched_file" "$override_file"
  fi

  kubectl -n "$NAMESPACE" create configmap gpu-operator-state-driver-override \
    --from-file=0500_daemonset.yaml="$override_file" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$NAMESPACE" patch deployment gpu-operator --type='strategic' -p="{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"volumes\": [
            {
              \"name\": \"state-driver-override\",
              \"configMap\": {
                \"name\": \"gpu-operator-state-driver-override\"
              }
            }
          ],
          \"containers\": [
            {
              \"name\": \"gpu-operator\",
              \"volumeMounts\": [
                {
                  \"name\": \"state-driver-override\",
                  \"mountPath\": \"${state_driver_manifest_path}\",
                  \"subPath\": \"0500_daemonset.yaml\",
                  \"readOnly\": true
                }
              ]
            }
          ]
        }
      }
    }
  }"

  kubectl -n "$NAMESPACE" rollout restart deployment/gpu-operator
  kubectl -n "$NAMESPACE" rollout status deployment/gpu-operator --timeout=5m

  rm -rf "$override_dir"
}

verify_upstream_precompiled_driver_override() {
  local clusterpolicy_driver_enabled clusterpolicy_use_precompiled deployment_override_mount ds_name ds_mount_path ds_volume_path ds_update_strategy

  clusterpolicy_driver_enabled=$(kubectl get clusterpolicies.nvidia.com/cluster-policy -o jsonpath='{.spec.driver.enabled}')
  if [ "$clusterpolicy_driver_enabled" != "true" ]; then
    echo "Error: ClusterPolicy spec.driver.enabled is '$clusterpolicy_driver_enabled', expected 'true'."
    exit 1
  fi

  clusterpolicy_use_precompiled=$(kubectl get clusterpolicies.nvidia.com/cluster-policy -o jsonpath='{.spec.driver.usePrecompiled}')
  if [ "$USE_PRECOMPILED" = "true" ] && [ "$clusterpolicy_use_precompiled" != "true" ]; then
    echo "Error: ClusterPolicy spec.driver.usePrecompiled is '$clusterpolicy_use_precompiled', expected 'true'."
    exit 1
  fi

  if [ "$USE_PRECOMPILED" != "true" ] && [ "$clusterpolicy_use_precompiled" != "false" ]; then
    echo "Error: ClusterPolicy spec.driver.usePrecompiled is '$clusterpolicy_use_precompiled', expected 'false'."
    exit 1
  fi

  if [ "${manifest_patched:-false}" = "true" ]; then
    if ! kubectl -n "$NAMESPACE" get configmap gpu-operator-state-driver-override >/dev/null 2>&1; then
      echo "Error: ConfigMap gpu-operator-state-driver-override was not created."
      exit 1
    fi

    deployment_override_mount=$(kubectl -n "$NAMESPACE" get deployment gpu-operator -o jsonpath="{.spec.template.spec.containers[?(@.name=='gpu-operator')].volumeMounts[?(@.name=='state-driver-override')].mountPath}")
    if [ "$deployment_override_mount" != "/opt/gpu-operator/state-driver/0500_daemonset.yaml" ] && [ "$deployment_override_mount" != "/opt/gpu-operator/manifests/state-driver/0500_daemonset.yaml" ]; then
      echo "Error: gpu-operator deployment is not mounting the overridden state-driver manifest."
      exit 1
    fi
  fi

  for _attempt in $(seq 1 60); do
    ds_name=$(kubectl -n "$NAMESPACE" get daemonsets -o jsonpath='{.items[?(@.metadata.labels.app=="nvidia-driver-daemonset")].metadata.name}')
    if [ -n "$ds_name" ]; then
      break
    fi
    sleep 5
  done

  if [ -z "$ds_name" ]; then
    echo "Error: nvidia-driver-daemonset was not created after re-enabling the driver."
    exit 1
  fi

  ds_update_strategy=$(kubectl -n "$NAMESPACE" get daemonset "$ds_name" -o jsonpath='{.spec.updateStrategy.type}')
  if [ "$ds_update_strategy" = "RollingUpdate" ]; then
    kubectl -n "$NAMESPACE" rollout status daemonset/"$ds_name" --timeout=10m
  fi

  ds_mount_path=$(kubectl -n "$NAMESPACE" get daemonset "$ds_name" -o jsonpath="{.spec.template.spec.containers[?(@.name=='nvidia-driver-ctr')].volumeMounts[?(@.name=='lib-modules')].mountPath}")
  ds_volume_path=$(kubectl -n "$NAMESPACE" get daemonset "$ds_name" -o jsonpath="{.spec.template.spec.volumes[?(@.name=='lib-modules')].hostPath.path}")

  if [ "$ds_mount_path" != "/run/host/lib/modules" ] || [ "$ds_volume_path" != "/lib/modules" ]; then
    echo "Error: nvidia-driver-daemonset is missing the expected /lib/modules host mount."
    exit 1
  fi
}

# 1. Delete nvidia.com and nfd.k8s-sigs.io CRDs, which will also delete all their custom resources
echo "Deleting nvidia.com and nfd CRDs to ensure a clean slate..."
kubectl get crd -o name | grep -E 'nvidia.com|nfd.k8s-sigs.io' | xargs -r kubectl delete

echo "Deleting cluster-wide resources..."
kubectl delete clusterrolebinding gpu-operator --ignore-not-found=true
kubectl delete clusterrole gpu-operator --ignore-not-found=true

echo "Deleting namespace '$NAMESPACE'..."
kubectl delete namespace $NAMESPACE --ignore-not-found=true

echo "Waiting for namespace '$NAMESPACE' to terminate..."
while kubectl get namespace $NAMESPACE >/dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo -e "\nNamespace '$NAMESPACE' terminated."

echo "Installing GPU Operator via Helm..."

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

if [ "$USE_HELM_PRIVATE_REGISTRY" == "true" ]; then
  if [ -z "$HELM_PRIVATE_URL" ]; then
    echo "Error: HELM_PRIVATE_URL is not set but USE_HELM_PRIVATE_REGISTRY=true (Target: $TARGET_OS)."
    exit 1
  fi
  if [ -z "$NGC_API_KEY" ]; then
    echo "Error: NGC_API_KEY is not set but USE_HELM_PRIVATE_REGISTRY=true (Target: $TARGET_OS)."
    exit 1
  fi

  # Construct full URL if it's just a base path
  if [[ "$HELM_PRIVATE_URL" != *.tgz ]]; then
    FULL_HELM_URL="${HELM_PRIVATE_URL%/}/gpu-operator-${GPU_OPERATOR_VERSION}.tgz"
  else
    FULL_HELM_URL="$HELM_PRIVATE_URL"
  fi

  echo "Fetching GPU Operator chart from URL: $FULL_HELM_URL"
  # Fetch the chart locally
  # shellcheck disable=SC2016
  if ! helm fetch "$FULL_HELM_URL" --username='$oauthtoken' --password="$NGC_API_KEY"; then
    echo "Error: Failed to fetch Helm chart from $FULL_HELM_URL"
    exit 1
  fi
  CHART_FILE=$(basename "$FULL_HELM_URL")
  HELM_CHART="./$CHART_FILE"
else
  if ! helm repo list | grep -q "^nvidia"; then
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  fi
  helm repo update
  HELM_CHART="nvidia/gpu-operator"
fi

# Create a values.yaml file
# When using precompiled drivers, set version to the branch (major) number
if [ "$USE_PRECOMPILED" == "true" ]; then
  HELM_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION%%.*}"
else
  HELM_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION}"
fi

if [ "$USE_UPSTREAM_GPU_OPERATOR" == "true" ]; then
  INITIAL_DRIVER_ENABLED=false
else
  INITIAL_DRIVER_ENABLED=true
fi

if [ "$USE_UPSTREAM_GPU_OPERATOR" == "true" ]; then
  # When using upstream, don't override operator settings
  cat <<EOF >gpu-operator-values.yaml
driver:
  enabled: ${INITIAL_DRIVER_ENABLED}
  version: ${HELM_DRIVER_VERSION}
  image: ${DRIVER_IMAGE_NAME}
  kernelModuleType: ${KERNEL_MODULE_TYPE}
  repository: ${DRIVER_REPOSITORY}
  usePrecompiled: ${USE_PRECOMPILED}
  imagePullPolicy: Always

cdi:
  enabled: true

toolkit:
  enabled: true
  imagePullPolicy: Always
  env:
    - name: CONTAINERD_SOCKET
      value: ${CONTAINERD_SOCKET}
EOF
else
  # When using patched operator, specify custom operator settings
  cat <<EOF >gpu-operator-values.yaml
driver:
  enabled: ${INITIAL_DRIVER_ENABLED}
  version: ${HELM_DRIVER_VERSION}
  image: ${DRIVER_IMAGE_NAME}
  kernelModuleType: ${KERNEL_MODULE_TYPE}
  repository: ${DRIVER_REPOSITORY}
  usePrecompiled: ${USE_PRECOMPILED}
  imagePullPolicy: Always

operator:
  repository: ${REGISTRY_IP}:5000/nvidia/cloud-native
  imagePullPolicy: Always

cdi:
  enabled: true

toolkit:
  enabled: true
  imagePullPolicy: Always
  env:
    - name: CONTAINERD_SOCKET
      value: ${CONTAINERD_SOCKET}
EOF
fi

HELM_INSTALL_ARGS=("$RELEASE_NAME" "$HELM_CHART" "-n" "$NAMESPACE" "--create-namespace" "-f" "gpu-operator-values.yaml")
if [ "$USE_HELM_PRIVATE_REGISTRY" != "true" ]; then
  HELM_INSTALL_ARGS+=("--version" "$GPU_OPERATOR_VERSION")
fi

helm install "${HELM_INSTALL_ARGS[@]}"

# Function to compare versions (e.g. v26.3.1)
# Returns 0 if $1 > $2, 1 otherwise
version_gt() {
  local v1
  v1="${1#v}"
  local v2
  v2="${2#v}"
  [ "$v1" != "$v2" ] && [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]
}

if [ "$USE_UPSTREAM_GPU_OPERATOR" == "true" ]; then
  manifest_patched=false
  if [ "$USE_PRECOMPILED" == "true" ] && version_gt "$GPU_OPERATOR_VERSION" "v26.3.0"; then
    echo "GPU_OPERATOR_VERSION is $GPU_OPERATOR_VERSION (> v26.3.0) with USE_PRECOMPILED=true; upstream operator natively mounts /run/host/lib/modules dynamically."
  else
    patch_upstream_precompiled_driver_manifest
    manifest_patched=true
  fi

  echo "Enabling the driver after applying any manifest overrides..."
  kubectl patch clusterpolicies.nvidia.com/cluster-policy --type='json' \
    -p='[{"op": "replace", "path": "/spec/driver/enabled", "value":true}]'

  verify_upstream_precompiled_driver_override
fi

rm gpu-operator-values.yaml
if [ "$USE_HELM_PRIVATE_REGISTRY" == "true" ]; then
  rm -f "$HELM_CHART"
fi
