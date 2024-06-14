#!/bin/bash

function execute_test {
    id=$1
    gpus=$2

    gpu_list=$(python3 .buildkite/amd-gpu-scheduler.py assign $gpus)

    # if [ -z "$gpu_list" ]; then
    #   echo "Not enough GPUs available."
    #   return 0
    # fi
    
    echo "Adding env variable HIP_VISIBLE_DEVICES=${gpu_list}"
    HIP_VISIBLE_DEVICES=$gpu_list buildkite-agent start --acquire-job=$id --enable-environment-variable-allowlist --allowed-environment-variables="HIP_VISIBLE_DEVICES"
    AGENT_PID=$!

    wait $AGENT_PID

    python3 .buildkite/amd-gpu-scheduler.py release "$gpu_list"
    echo "GPUs released: $gpu_list"
}

cleanup() {
    echo "Cleaning up GPU state file..."
    rm -f /tmp/gpu_state.json
    echo "Cleanup complete. Exiting."
}

trap cleanup EXIT

sudo apt-get install jq
pip install FileLock

while true; do
    job=$(curl https://graphql.buildkite.com/v1 \
    -H "Authorization: Bearer bkua_8b379ac0f6a511cc7715bbd48b02c938a6c26e77" \
    -H "Content-Type: application/json" \
    -d '{
        "query": "{ build(slug: \"amd-11/torchrun-test-final/'"${BUILDKITE_BUILD_NUMBER}"'\") { jobs(first: 1, state: SCHEDULED) { edges { node { ... on JobTypeCommand { id label priority { number } } } } } } }",
        "variables": "{ }"
    }' | jq -r '.data.build.jobs.edges[] | .node')

    # Check if the response is empty
    if [ -z "$job" ]; then
        echo "No more Available Jobs" 
        exit 0
    fi

    # Scheduling job
    job_label=$(echo "$job" | jq -r '.label')
    job_id=$(echo "$job" | jq -r '.id')
    job_gpus=$(echo "$job" | jq -r '.priority.number')
    echo "Job: ${job_label}"
    if ! python3 .buildkite/amd-gpu-scheduler.py check $job_gpus; then
        echo "Waiting for $job_gpus GPUs to become available..."
        while ! python3 .buildkite/amd-gpu-scheduler.py check $job_gpus; do
            sleep 10
        done
    fi

    execute_test $job_id $job_gpus &
    sleep 10 

done