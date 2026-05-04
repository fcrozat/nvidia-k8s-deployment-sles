#!/bin/bash
# upgrade.sh - Mirror a specific NVIDIA driver version to the local cluster registry

set -e

# Load private configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
  source "$SCRIPT_DIR/config.sh"
else
  echo "Error: config.sh not found. Copy config.sh.example to config.sh and fill in your values."
  exit 1
fi

# --- Configuration & Discovery ---
TARGET_KEY="${TARGET_OS:-$DEFAULT_TARGET}"
TARGET_KEY="${TARGET_KEY//./_}"

host_var="HOST_${TARGET_KEY}"
user_var="USER_${TARGET_KEY}"
distro_var="K8S_DISTRO_${TARGET_KEY}"
mirror_var="NEEDS_MIRROR_${TARGET_KEY}"

TARGET_HOST="${TARGET_HOST:-${!host_var}}"
TARGET_USER="${TARGET_USER:-${!user_var}}"
K8S_DISTRO="${K8S_DISTRO:-${!distro_var}}"
NEEDS_MIRROR="${NEEDS_MIRROR:-${!mirror_var:-false}}"
USE_PREBUILT_CONTAINER="${USE_PREBUILT_CONTAINER:-true}"
USE_PRECOMPILED="${USE_PRECOMPILED:-false}"

if [ -z "$NVIDIA_DRIVER_VERSION" ]; then
    echo "Error: NVIDIA_DRIVER_VERSION environment variable must be set."
    echo "Example: NVIDIA_DRIVER_VERSION=580.126.09 ./upgrade.sh"
    exit 1
fi

# Detect SLES version on remote host
SLES=$(ssh "$TARGET_USER@$TARGET_HOST" 'source /etc/os-release && echo $VERSION_ID')
echo "Detected SLES version on remote: $SLES"

KUBECONFIG_PATH="$PWD/${K8S_DISTRO}-sles${SLES}.yaml"
if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "Error: Kubeconfig not found at $KUBECONFIG_PATH. Please run deploy.sh first."
    exit 1
fi
export KUBECONFIG=$KUBECONFIG_PATH

# Discover Registry IP
REGISTRY_IP=$(kubectl -n local-registry get service docker-registry -o jsonpath='{.spec.clusterIP}')
if [ -z "$REGISTRY_IP" ]; then
    echo "Error: Could not find local-registry ClusterIP."
    exit 1
fi
echo "Local Registry found at: $REGISTRY_IP"

# Detect kernel version if using precompiled drivers
if [ "$USE_PRECOMPILED" == "true" ]; then
  echo "Detecting kernel version on remote host for precompiled drivers..."
  KERNEL_VERSION=$(ssh "$TARGET_USER@$TARGET_HOST" 'uname -r')
  if [ -z "$KERNEL_VERSION" ]; then
    echo "Error: Failed to detect kernel version. Required for USE_PRECOMPILED=true"
    exit 1
  fi
  echo "Detected kernel version: $KERNEL_VERSION"
  DRIVER_BRANCH="${NVIDIA_DRIVER_VERSION%%.*}"
  FINAL_REGISTRY_TAG="${DRIVER_BRANCH}-${KERNEL_VERSION}-sles${SLES}"
  HELM_DRIVER_VERSION="$DRIVER_BRANCH"
else
  FINAL_REGISTRY_TAG="${NVIDIA_DRIVER_VERSION}-sles${SLES}"
  HELM_DRIVER_VERSION="$NVIDIA_DRIVER_VERSION"
fi

LOCAL_IMAGE_NAME="${REGISTRY_IP}:5000/nvidia/driver:${FINAL_REGISTRY_TAG}"

# --- Check if image exists in local registry ---
echo "Checking if $LOCAL_IMAGE_NAME already exists in local registry..."
if ssh "$TARGET_USER@$TARGET_HOST" "podman pull --tls-verify=false $LOCAL_IMAGE_NAME" >/dev/null 2>&1; then
    echo "Image $LOCAL_IMAGE_NAME already exists in the local registry. Skipping push."
else
    echo "Image not found. Proceeding with mirroring..."

    # Determine source repository
    if [ "$USE_PREBUILT_CONTAINER" = "true" ]; then
        if [ -z "$DRIVER_REPOSITORY" ]; then
             # Default to a known stable path if not provided
            DRIVER_REPOSITORY="$DEFAULT_UPGRADE_DRIVER_REPOSITORY"
        fi
        
        SOURCE_IMAGE="${DRIVER_REPOSITORY}/driver:${FINAL_REGISTRY_TAG}"
        
        echo "Mirroring $SOURCE_IMAGE to $LOCAL_IMAGE_NAME"
        
        # 1. Pull on local machine (if needed) or directly on remote
        if [[ "$NEEDS_MIRROR" == "true" ]]; then
            echo "Working via local bridge (target needs mirroring)..."
            if ! podman pull "$SOURCE_IMAGE"; then
                 echo "Warning: Failed to pull $SOURCE_IMAGE locally, trying to find it on remote host instead..."
            else
                 podman save "$SOURCE_IMAGE" | ssh "$TARGET_USER@$TARGET_HOST" "podman load"
            fi
        else
            ssh "$TARGET_USER@$TARGET_HOST" "podman pull $SOURCE_IMAGE"
        fi

        # 2. Tag and Push to local registry from the remote host
        # First ensure the image exists on the remote (it might have been there already)
        ssh "$TARGET_USER@$TARGET_HOST" "podman tag $SOURCE_IMAGE $LOCAL_IMAGE_NAME || podman tag \$(podman images --format '{{.Repository}}:{{.Tag}}' | grep $NVIDIA_DRIVER_VERSION | head -n 1) $LOCAL_IMAGE_NAME"
        ssh "$TARGET_USER@$TARGET_HOST" "podman push --tls-verify=false $LOCAL_IMAGE_NAME"
    else
        echo "Error: Manual build path not implemented in upgrade.sh. Use deploy.sh for builds."
        exit 1
    fi
fi

# --- Patch ClusterPolicy ---
if [ "$USE_PRECOMPILED" == "true" ]; then
  echo "Patching ClusterPolicy to use precompiled driver version $HELM_DRIVER_VERSION (branch) with usePrecompiled=true..."
  kubectl patch clusterpolicies.nvidia.com/cluster-policy --type='json' \
    -p="[{\"op\": \"replace\", \"path\": \"/spec/driver/version\", \"value\":\"$HELM_DRIVER_VERSION\"},{\"op\": \"replace\", \"path\": \"/spec/driver/usePrecompiled\", \"value\":true}]"
else
  echo "Patching ClusterPolicy to use version $HELM_DRIVER_VERSION..."
  kubectl patch clusterpolicies.nvidia.com/cluster-policy --type='json' \
    -p="[{\"op\": \"replace\", \"path\": \"/spec/driver/version\", \"value\":\"$HELM_DRIVER_VERSION\"}]"
fi

echo "Upgrade triggered. Monitor pods with: kubectl get pods -n gpu-operator -w"
