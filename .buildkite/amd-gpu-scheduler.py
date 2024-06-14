import sys
import json
import time
from filelock import FileLock

lock_path = "/tmp/gpu_lock"
gpu_state_path = "/tmp/gpu_state.json"

def load_state():
    try:
        with open(gpu_state_path, 'r') as file:
            return json.load(file)
    except FileNotFoundError:
        return {
            "total_gpus": 8,
            "available_gpus": list(range(8)),
            "in_use_gpus": []
        }

def save_state(state):
    with open(gpu_state_path, 'w') as file:
        json.dump(state, file)

def assign_gpus(required_gpus):
    with FileLock(lock_path):
        state = load_state()
        if required_gpus <= len(state["available_gpus"]):
            assigned = state["available_gpus"][:required_gpus]
            state["available_gpus"] = state["available_gpus"][required_gpus:]
            state["in_use_gpus"] += assigned
            save_state(state)
            return assigned
        return []

def release_gpus(gpu_ids):
    with FileLock(lock_path):
        state = load_state()
        state["available_gpus"] += gpu_ids
        for gpu in gpu_ids:
            state["in_use_gpus"].remove(gpu)
        state["available_gpus"].sort()
        save_state(state)

def check_available_gpus(required_gpus):
    with FileLock(lock_path):
        state = load_state()
        return len(state["available_gpus"]) >= required_gpus

def main():
    action = sys.argv[1]
    if action == "assign":
        required_gpus = int(sys.argv[2])
        gpus_assigned = assign_gpus(required_gpus)
        print(json.dumps(gpus_assigned))
    elif action == "release":
        gpu_ids = json.loads(sys.argv[2])
        release_gpus(gpu_ids)
    elif action == "check":
        required_gpus = int(sys.argv[2])
        available = check_available_gpus(required_gpus)
        if available:
            sys.exit(0)  
        else:
            sys.exit(1)

if __name__ == "__main__":
    main()