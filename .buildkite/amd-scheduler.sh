#!/bin/bash

function execute_test {
    label="$1"
    id=$2
    gpus=$3

    gpu_list=$(python3 .buildkite/amd-gpu-scheduler.py assign $gpus) 

    # Remove [] for env variable
    formatted_gpu_list=$(echo "$gpu_list" | jq -r '. | @csv' | tr -d '"')

    echo "Running ${label} - Allocating GPUs: ${formatted_gpu_list}"

    # Start a new Buildkite agent and pass in env variable to subprocess
    ROCR_VISIBLE_DEVICES="${formatted_gpu_list}" buildkite-agent start --acquire-job=$id --queue amd-test > /dev/null #2>&1
    
    # After agents terminates free the GPUs it was using
    python3 .buildkite/amd-gpu-scheduler.py release "$gpu_list"

    echo "Finishing ${label} - Releasing GPUs: $formatted_gpu_list"
}

cleanup() {
    echo "Cleaning up state files..."
    rm -f /tmp/gpu_state.json
    rm -f /tmp/gpu_lock
    rm -f /tmp/gpu_ids.json
    echo "Cleanup complete. Exiting."
}

trap cleanup EXIT

echo "--- Resetting GPUs"

echo "reset" > /opt/amdgpu/etc/gpu_state

while true; do
        sleep 3
        if grep -q clean /opt/amdgpu/etc/gpu_state; then
                echo "GPUs state is \"clean\""
                break
        fi
done

echo "--- Fetching GPUs" 

rocm-smi --showuniqueid --json > /tmp/gpu_ids.json

echo "--- Checking Dependences"

sudo apt-get install jq
pip install FileLock

echo "--- Fetching Jobs" 

jobs=$(curl -s -S https://graphql.buildkite.com/v1 \
    -H "Authorization: Bearer ${BUIDLKITE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "query": "{ build(slug: \"amd-13/test/'"${BUILDKITE_BUILD_NUMBER}"'\") { jobs(first: 100, state: SCHEDULED, agentQueryRules: \"queue=amd-test\") { edges { node { ... on JobTypeCommand { uuid label priority { number } } } } } } }",
        "variables": "{ }"
    }')

# Convert into bash array
mapfile -t jobs_array < <(echo "$jobs" | jq -c '.data.build.jobs.edges | map(.node) | sort_by(.priority.number) | reverse[]')

# Iterate through each job
for job in "${jobs_array[@]}"; do

    job_label=$(echo "$job" | jq -r '.label')
    job_id=$(echo "$job" | jq -r '.uuid')
    job_gpus=$(echo "$job" | jq -r '.priority.number')


    # Check if priority is higher than 8 (GPUs on the machine) or less than 1
    if [ "$job_gpus" -lt 1 ] || [ "$job_gpus" -gt 8 ]; then
        echo "Skipping ${job_label} - Invalid # of GPUs (${job_gpus})"
        continue
    fi

    # Check if job has been taken by a different agent
    job_state=$(curl -s -S https://graphql.buildkite.com/v1 \
        -H "Authorization: Bearer ${BUILDKITE_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "query": "{ job(uuid: \"'"$job_id"'\") { ... on JobTypeCommand { state } } }",
            "variables": "{ }"
        }' | jq -r '.data.job.state')
    
    if [ "$job_state" != "SCHEDULED" ]; then
        echo "Skipping ${job_label} - Already running"
        continue
    fi

    # Check is there are sufficient GPUs available
    if ! python3 .buildkite/amd-gpu-scheduler.py check $job_gpus; then
        echo "Waiting for $job_gpus GPUs to become available..."
        while ! python3 .buildkite/amd-gpu-scheduler.py check $job_gpus; do
            sleep 10
        done
    fi

    # Run test
    execute_test "$job_label" $job_id $job_gpus &
    sleep 30 

done

wait

echo "All jobs are done."