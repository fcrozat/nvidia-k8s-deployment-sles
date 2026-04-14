#!/bin/bash -x
#
# need to configure ec2 instance with policy allowing kubectl remote control
#

# Load private configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
  source "$SCRIPT_DIR/config.sh"
else
  echo "Error: config.sh not found. Copy config.sh.example to config.sh and fill in your values."
  exit 1
fi

# Defaults (can be overridden by env vars)
# TARGET_OS selects a host configuration from config.sh (e.g. 15.7, 16.0, onprem)
TARGET_KEY="${TARGET_OS:-$DEFAULT_TARGET}"
TARGET_KEY="${TARGET_KEY//./_}"  # Replace dots for valid variable names

host_var="HOST_${TARGET_KEY}"
user_var="USER_${TARGET_KEY}"
distro_var="K8S_DISTRO_${TARGET_KEY}"
mirror_var="NEEDS_MIRROR_${TARGET_KEY}"

if [ -z "${!host_var}" ]; then
  echo "Unknown TARGET_OS: $TARGET_OS (no HOST_${TARGET_KEY} defined in config.sh)"
  exit 1
fi

TARGET_HOST="${TARGET_HOST:-${!host_var}}"
TARGET_USER="${TARGET_USER:-${!user_var}}"
K8S_DISTRO="${K8S_DISTRO:-${!distro_var}}"
NEEDS_MIRROR="${NEEDS_MIRROR:-${!mirror_var:-false}}"
USE_PREBUILT_CONTAINER="${USE_PREBUILT_CONTAINER:-false}"
USE_UPSTREAM_GPU_OPERATOR="${USE_UPSTREAM_GPU_OPERATOR:-false}"
KERNEL_MODULE_TYPE="${KERNEL_MODULE_TYPE:-auto}"
USE_PRECOMPILED="${USE_PRECOMPILED:-false}"
GPU_OPERATOR_BRANCH="${GPU_OPERATOR_BRANCH:-}"  # Optional override for GPU operator branch
GPU_OPERATOR_IMAGE="${GPU_OPERATOR_IMAGE:-}"  # Optional override for GPU operator image

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
  if ! command -v $cmd > /dev/null 2>&1; then
    echo "Error: $cmd could not be found. Please install it."
    exit 1
  fi
done

# --- Remote Dependency Checks ---
# Install required packages on the remote host if they are not already present.
ssh $TARGET_USER@$TARGET_HOST "bash -s" << 'EOF'
  for pkg in git-core podman make; do
    if ! rpm -q $pkg > /dev/null 2>&1; then
      echo "Installing remote package: $pkg"
      sudo zypper in -y $pkg
    fi
  done

  # nvidia-container-toolkit must NOT be installed on the host as it conflicts with the GPU Operator
  if rpm -q nvidia-container-toolkit > /dev/null 2>&1; then
    echo "Removing nvidia-container-toolkit from host (conflicts with GPU Operator)..."
    sudo zypper rm -y nvidia-container-toolkit
  fi
EOF

# --- Cluster Setup (K3s or RKE2) ---
if [ "$K8S_DISTRO" == "k3s" ]; then
    echo "Checking k3s status on remote host..."
    # Check if k3s service is active on the remote machine
    if ! ssh $TARGET_USER@$TARGET_HOST "sudo systemctl is-active --quiet k3s"; then
      echo "k3s not found or not active on remote host. Installing k3s..."
      # Use the official install script
      ssh $TARGET_USER@$TARGET_HOST "curl -sfL https://get.k3s.io | sh -"
      echo "k3s installed."
    else
      echo "k3s is already installed and active on remote host."
    fi
    REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
    REGISTRY_FILE="/etc/rancher/k3s/registries.yaml"
    SERVICE_NAME="k3s"
    CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
elif [ "$K8S_DISTRO" == "rke2" ]; then
    echo "Using existing RKE2 instance..."
    REMOTE_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
    REGISTRY_FILE="/etc/rancher/rke2/registries.yaml"
    SERVICE_NAME="rke2-server" # Assuming server node
    # RKE2 usually uses this socket path as well (symlinked or direct)
    CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
else
    echo "Unknown K8S_DISTRO: $K8S_DISTRO"
    exit 1
fi

# SLES version was already detected at the beginning of the script

# Fetch the kubeconfig from the remote node and update it for local access
KUBECONFIG_PATH="$PWD/${K8S_DISTRO}-sles${SLES}.yaml"
echo "Fetching kubeconfig from remote host..."
ssh $TARGET_USER@$TARGET_HOST "sudo cat $REMOTE_KUBECONFIG" > $KUBECONFIG_PATH
if [ $? -ne 0 ]; then
    echo "Failed to fetch kubeconfig from remote host."
    exit 1
fi
sed -i "s/127.0.0.1/$TARGET_HOST/g" $KUBECONFIG_PATH
# Configure insecure-skip-tls-verify since the hostname won't match the cert
sed -i 's/certificate-authority-data:.*/insecure-skip-tls-verify: true/g' $KUBECONFIG_PATH
export KUBECONFIG=$KUBECONFIG_PATH
echo "Kubeconfig saved to $KUBECONFIG"


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

echo "Restarting CoreDNS to apply the new configuration..."
# Detect CoreDNS deployment name
if kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
    COREDNS_DEPLOYMENT="coredns"
elif kubectl -n kube-system get deployment rke2-coredns-rke2-coredns >/dev/null 2>&1; then
    COREDNS_DEPLOYMENT="rke2-coredns-rke2-coredns"
else
    COREDNS_DEPLOYMENT=$(kubectl -n kube-system get deployment -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
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
CONFIG_CHECK=$(ssh $TARGET_USER@$TARGET_HOST "grep -q '$REGISTRY_IP:5000' $REGISTRY_FILE 2>/dev/null && grep -q '$INTERNAL_REGISTRY' $REGISTRY_FILE 2>/dev/null && echo 'CONFIGURED'")

if [ "$CONFIG_CHECK" == "CONFIGURED" ]; then
    echo "Cluster already configured for insecure registry."
else
    echo "Configuring node to trust the insecure registry..."
    ssh $TARGET_USER@$TARGET_HOST "bash -s" << EOF
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
    until kubectl get nodes &> /dev/null; do
      echo -n "."
      sleep 5
    done
    echo -e "\nKubernetes API is ready."
fi


# --- Remote Container Build and Push ---
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-580.126.09}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.10.1}"
DRIVER_CONTAINER_BRANCH="${DRIVER_CONTAINER_BRANCH:-sles15-refresh}"
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
        else
            DEFAULT_INTERNAL_REGISTRY="$INTERNAL_DRIVER_REGISTRY_15SP7"
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
  DRIVER_CONTAINER_BRANCH="$DRIVER_CONTAINER_BRANCH" \
  USE_PREBUILT_CONTAINER="$USE_PREBUILT_CONTAINER" \
  USE_UPSTREAM_GPU_OPERATOR="$USE_UPSTREAM_GPU_OPERATOR" \
  USE_PRECOMPILED="$USE_PRECOMPILED" \
  DRIVER_IMAGE_NAME="$DRIVER_IMAGE_NAME" \
  NEEDS_MIRROR="$NEEDS_MIRROR" \
  INTERNAL_REGISTRY="$INTERNAL_REGISTRY" \
  PREBUILT_DRIVER_IMAGE="$PREBUILT_DRIVER_IMAGE" \
  PREBUILT_DRIVER_REPOSITORY="$PREBUILT_DRIVER_REPOSITORY" \
  'bash -s' << 'EOF'
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
  BRANCH="$DRIVER_CONTAINER_BRANCH"

  # Determine build directory based on branch
  if [[ "$BRANCH" == *"packages"* || "$BRANCH" == *"cuda"* ]]; then
    BUILD_DIR="sle15/official-packages"
  else
    BUILD_DIR="sle15"
  fi
  echo "Using branch: $BRANCH"
  echo "Build directory: $BUILD_DIR"

  # Clone the driver container repo
  if [ ! -d "$HOME/checkout/nvidia/gpu-driver-container" ]; then
    mkdir -p ~/checkout/nvidia
    cd ~/checkout/nvidia
    git clone -b $BRANCH https://github.com/fcrozat/gpu-driver-container.git
  else
    cd ~/checkout/nvidia/gpu-driver-container
    # Check if we need to switch branches
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        git fetch origin
        git switch $BRANCH
    fi
    git pull
  fi
  cd ~/checkout/nvidia/gpu-driver-container/$BUILD_DIR

  # Set the local build tag (used before pushing to registry)
  LOCAL_BUILD_TAG="nvidia/nvidia-gpu-driver:$NVIDIA_DRIVER_VERSION"

  if [ "$DRIVER_CONTAINER_BRANCH" == "cuda-combined-container" ]; then
    # Build additional images
    echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH -t nvidia/driver-open:$NVIDIA_DRIVER_VERSION-sles$SLES -f Dockerfile.open"
    podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH"  -t "nvidia/driver-open:$NVIDIA_DRIVER_VERSION-sles$SLES" -f Dockerfile.open
    echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH -t nvidia/driver-closed:$NVIDIA_DRIVER_VERSION-sles$SLES -f Dockerfile.closed"
    podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH"  -t "nvidia/driver-closed:$NVIDIA_DRIVER_VERSION-sles$SLES" -f Dockerfile.closed
  fi

  # Build the driver image
  if [ "$USE_PRECOMPILED" == "true" ]; then
    echo "Building precompiled driver image with tag: $LOCAL_BUILD_TAG"
  fi
  echo "Running: podman build --build-arg DRIVER_VERSION=$NVIDIA_DRIVER_VERSION --build-arg SLES_VERSION=$SLES --build-arg DRIVER_BRANCH=$DRIVER_BRANCH -t $LOCAL_BUILD_TAG ."
  podman build --build-arg DRIVER_VERSION="$NVIDIA_DRIVER_VERSION" --build-arg SLES_VERSION="$SLES" --build-arg DRIVER_BRANCH="$DRIVER_BRANCH"  -t "$LOCAL_BUILD_TAG" .

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

  if ! kubectl -n "$NAMESPACE" exec "$operator_pod" -- cat "$state_driver_manifest_path" > "$override_file"; then
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
    ' "$override_file" > "$patched_file"; then
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
  local clusterpolicy_driver_enabled clusterpolicy_use_precompiled deployment_override_mount ds_name ds_mount_path ds_volume_path ds_update_strategy attempt

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

  if ! kubectl -n "$NAMESPACE" get configmap gpu-operator-state-driver-override > /dev/null 2>&1; then
    echo "Error: ConfigMap gpu-operator-state-driver-override was not created."
    exit 1
  fi

  deployment_override_mount=$(kubectl -n "$NAMESPACE" get deployment gpu-operator -o jsonpath="{.spec.template.spec.containers[?(@.name=='gpu-operator')].volumeMounts[?(@.name=='state-driver-override')].mountPath}")
  if [ "$deployment_override_mount" != "/opt/gpu-operator/state-driver/0500_daemonset.yaml" ] && [ "$deployment_override_mount" != "/opt/gpu-operator/manifests/state-driver/0500_daemonset.yaml" ]; then
    echo "Error: gpu-operator deployment is not mounting the overridden state-driver manifest."
    exit 1
  fi

  for attempt in $(seq 1 60); do
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
while kubectl get namespace $NAMESPACE > /dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo -e "\nNamespace '$NAMESPACE' terminated."

echo "Installing GPU Operator via Helm..."

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

if ! helm repo list | grep -q "^nvidia"; then
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
fi
helm repo update

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
  cat << EOF > gpu-operator-values.yaml
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
  cat << EOF > gpu-operator-values.yaml
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

helm install $RELEASE_NAME nvidia/gpu-operator -n $NAMESPACE --create-namespace \
    --version=$GPU_OPERATOR_VERSION \
    -f gpu-operator-values.yaml

if [ "$USE_UPSTREAM_GPU_OPERATOR" == "true" ]; then
  patch_upstream_precompiled_driver_manifest

  echo "Enabling the driver after applying the upstream manifest override..."
  kubectl patch clusterpolicies.nvidia.com/cluster-policy --type='json' \
    -p='[{"op": "replace", "path": "/spec/driver/enabled", "value":true}]'

  verify_upstream_precompiled_driver_override
fi

rm gpu-operator-values.yaml
