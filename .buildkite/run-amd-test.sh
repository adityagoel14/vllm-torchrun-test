# This script runs test inside the corresponding ROCm docker container.
set -ex

# Print ROCm version
echo "--- ROCm info"
#rocminfo

# cleanup older docker images
cleanup_docker() {
  # Get Docker's root directory
  docker_root=$(docker info -f '{{.DockerRootDir}}')
  if [ -z "$docker_root" ]; then
    echo "Failed to determine Docker root directory."
    exit 1
  fi
  echo "Docker root directory: $docker_root"
  # Check disk usage of the filesystem where Docker's root directory is located
  disk_usage=$(df "$docker_root" | tail -1 | awk '{print $5}' | sed 's/%//')
  # Define the threshold
  threshold=70
  if [ "$disk_usage" -gt "$threshold" ]; then
    echo "Disk usage is above $threshold%. Cleaning up Docker images and volumes..."
    # Remove dangling images (those that are not tagged and not used by any container)
    docker image prune -f
    # Remove unused volumes
    docker volume prune -f
    echo "Docker images and volumes cleanup completed."
  else
    echo "Disk usage is below $threshold%. No cleanup needed."
  fi
}

# Call the cleanup docker function
cleanup_docker

echo "--- Checking for ROCR_VISIBLE_DEVICES"

if [ -z "${ROCR_VISIBLE_DEVICES}" ]; then
    echo "ROCR_VISIBLE_DEVICES is not set."
else
    echo "ROCR_VISIBLE_DEVICES is set to: ${ROCR_VISIBLE_DEVICES}"
fi

# echo "--- Resetting GPUs"

# echo "reset" > /opt/amdgpu/etc/gpu_state

# while true; do
#         sleep 3
#         if grep -q clean /opt/amdgpu/etc/gpu_state; then
#                 echo "GPUs state is \"clean\""
#                 break
#         fi
# done

IFS=',' read -ra GPU_IDS <<< "$ROCR_VISIBLE_DEVICES"
# Loop through each GPU ID specified in the environment variable
for i in "${GPU_IDS[@]}"; do
    # Reset each specified GPU
    rocm-smi --gpureset -d $i
    echo "Reset GPU ID $i"
done

echo "--- Pulling container" 

image_name="rocmshared/vllm-ci:${BUILDKITE_COMMIT}"
container_name="rocm_${BUILDKITE_COMMIT}_$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 10; echo)"

docker pull ${image_name}

remove_docker_container() {
   docker rm -f ${container_name} || docker image rm -f ${image_name} || true
}
trap remove_docker_container EXIT

echo "--- Verifying HF_TOKEN" 

if [ -z "${HF_TOKEN}" ]; then
    echo "HF_TOKEN is not set"
else
    echo "HF_TOKEN is set"
fi

echo "--- Running container"

docker run \
        --device /dev/kfd --device /dev/dri \
        --network host \
        --rm \
        -e HF_TOKEN \
        -e ROCR_VISIBLE_DEVICES \
        --name ${container_name} \
        ${image_name} \
        /bin/bash -c "${@}"
