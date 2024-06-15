#!/bin/bash

function execute_test {
    id=$1
    gpus=$2

    gpu_list=$(python3 .buildkite/amd-gpu-scheduler.py assign $gpus) 
    # Remove [] for env variable
    formatted_gpu_list=$(echo "$gpu_list" | jq -r '. | @csv' | tr -d '"')

    echo "Adding env variable HIP_VISIBLE_DEVICES=${formatted_gpu_list}"

    # TO DO: don't redirect errors 

    # Start a new Buildkite agent and pass in env variable to subprocess
    HIP_VISIBLE_DEVICES="${formatted_gpu_list}" buildkite-agent start --acquire-job=$id > /dev/null 2>&1
    
    # After agents terminates free the GPUs it was using
    python3 .buildkite/amd-gpu-scheduler.py release "$gpu_list"
    echo "GPUs released: $gpu_list"
}

function is_job_still_scheduled {
    id=$1
    job_state=$(curl https://graphql.buildkite.com/v1 \
        -H "Authorization: Bearer bkua_8b379ac0f6a511cc7715bbd48b02c938a6c26e77" \
        -H "Content-Type: application/json" \
        -d '{
            "query": "{ job(uuid: \"'"$id"'\") { ... on JobTypeCommand { state } } }",
            "variables": "{ }"
        }' | jq -r '.data.job.state')

    if [ "$job_state" == "SCHEDULED" ]; then
        return 0  
    else
        return 1  
    fi
}

cleanup() {
    echo "Cleaning up GPU state file..."
    rm -f /tmp/gpu_state.json
    rm -f /tmp/gpu_lock
    echo "Cleanup complete. Exiting."
}

trap cleanup EXIT

echo "--- Checking Dependences"

sudo apt-get install jq
pip install FileLock

echo "--- Fetching Jobs" 

jobs=$(curl https://graphql.buildkite.com/v1 \
    -H "Authorization: Bearer bkua_8b379ac0f6a511cc7715bbd48b02c938a6c26e77" \
    -H "Content-Type: application/json" \
    -d '{
        "query": "{ build(slug: \"amd-11/torchrun-test-final/'"${BUILDKITE_BUILD_NUMBER}"'\") { jobs(first: 100, state: SCHEDULED) { edges { node { ... on JobTypeCommand { uuid label priority { number } } } } } } }",
        "variables": "{ }"
    }' | jq -r '.data.build.jobs.edges | sort_by(.node.priority.number | -.)[] | .node')

# Convert into bash array
mapfile -t jobs_array < <(echo "$jobs" | jq -c '.data.build.jobs.edges | map(.node) | sort_by(.priority.number) | reverse[]')

# Iterate through each job
for job in "${jobs_array[@]}"; do

    job_label=$(echo "$job" | jq -r '.label')
    job_id=$(echo "$job" | jq -r '.uuid')
    job_gpus=$(echo "$job" | jq -r '.priority.number')

    echo -e "Job -> ${job_label}\nID -> ${job_id}\nGPUs -> ${job_gpus}"

    # Check if priority is higher than 8 (GPUs on the machine)
    if [ "$job_gpus" -gt 8 ]; then
        echo "Skipping job requiring more than 8 GPUs -> $job_label"
        continue
    fi

    # Check if job has been taken by a different agent
    if ! is_job_still_scheduled $job_id; then
        echo "Skipping job as it is no longer scheduled -> $job_label"
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
    execute_test $job_id $job_gpus &
    sleep 10 

done