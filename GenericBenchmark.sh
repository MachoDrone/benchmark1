#!/bin/bash

# Files to store temporary data
CONTAINER_ID_FILE="/tmp/nosana_container_id.txt"
OUTPUT_FILE="/tmp/nosana_output.txt"
BENCHMARK_FILE="/tmp/benchmark.json"
PODMAN_CONTAINER="podman"  # Confirmed Podman container name
BENCHMARK_URL="https://github.com/MachoDrone/benchmark1/raw/main/benchmark.json"

# Function to clean up on exit
cleanup() {
    echo "Stopping background processes and cleaning up..."
    kill $NOSANA_PID $NVIDIA_PID $LOGS_PID 2>/dev/null
    rm -f "$CONTAINER_ID_FILE" "$OUTPUT_FILE" "$BENCHMARK_FILE" "$OUTPUT_FILE.logs"
    exit 0
}

# Trap Ctrl+C or script exit to clean up
trap cleanup INT TERM EXIT

# Function to prompt user with y/n/c
prompt_user() {
    while true; do
        read -p "$1 (y/n/c): " choice
        case $choice in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            [Cc]*) echo "Cancelled by user."; exit 1 ;;
            *) echo "Please enter y, n, or c." ;;
        esac
    done
}

# Check and install dependencies (Node.js/npm and wget)
check_dependencies() {
    # Check for npx (Node.js/npm)
    NPX_PATH=$(which npx)
    if [ -z "$NPX_PATH" ]; then
        echo "Error: npx not found (Node.js/npm required)."
        if prompt_user "Install Node.js and npm?"; then
            sudo apt update
            sudo apt install -y nodejs npm || {
                echo "Failed to install Node.js/npm. Please install manually."
                exit 1
            }
            NPX_PATH=$(which npx)
            [ -z "$NPX_PATH" ] && { echo "npx still not found after installation."; exit 1; }
            echo "Node.js and npm installed successfully."
        else
            echo "Node.js/npm not installed. Exiting."
            exit 1
        fi
    fi

    # Check for wget
    if ! command -v wget >/dev/null 2>&1; then
        echo "Error: wget not found."
        if prompt_user "Install wget?"; then
            sudo apt update
            sudo apt install -y wget || {
                echo "Failed to install wget. Please install manually."
                exit 1
            }
            echo "wget installed successfully."
        else
            echo "wget not installed. Exiting."
            exit 1
        fi
    fi
}

# Run dependency checks
check_dependencies

# Download benchmark.json locally
echo "Downloading $BENCHMARK_URL to $BENCHMARK_FILE..."
wget -q -O "$BENCHMARK_FILE" "$BENCHMARK_URL" || {
    echo "Failed to download $BENCHMARK_URL"
    exit 1
}

# Step 1: Run Nosana CLI with local benchmark.json and capture container ID
echo "Starting Nosana job with $BENCHMARK_FILE..."
echo "y" | sudo "$NPX_PATH" @nosana/cli node run "$BENCHMARK_FILE" 2>&1 | tee "$OUTPUT_FILE" &
NOSANA_PID=$!
# Wait briefly to let the command start
sleep 2
# Extract container ID (try grep first, then fallback to podman inside Docker)
CONTAINER_ID=$(grep -oP 'Container ID: \K\S+' "$OUTPUT_FILE" || docker exec $PODMAN_CONTAINER podman ps -lq)
if [ -z "$CONTAINER_ID" ]; then
    echo "No container ID found in output. Checking running containers..."
    CONTAINER_ID=$(docker exec $PODMAN_CONTAINER podman ps -a --format "{{.ID}}" | head -n 1)
fi
echo "Container ID: $CONTAINER_ID" > "$CONTAINER_ID_FILE"
echo "Debug: Nosana output saved to $OUTPUT_FILE"

# Step 2: Run podman logs in the background to capture progress
if [ -n "$CONTAINER_ID" ]; then
    echo "Starting podman logs for container $CONTAINER_ID..."
    nohup docker exec $PODMAN_CONTAINER podman logs -f "$CONTAINER_ID" > "$OUTPUT_FILE.logs" 2>/dev/null &
    LOGS_PID=$!
    sleep 5  # Give logs time to start
    if ! ps -p $LOGS_PID > /dev/null; then
        echo "Error: Podman logs process ($LOGS_PID) failed to start or died."
        echo "Check 'docker exec $PODMAN_CONTAINER podman ps -a' for container status."
    fi
else
    echo "No container ID found, skipping logs..."
    echo "Debug: Check if Nosana uses Podman inside Docker or run 'docker exec $PODMAN_CONTAINER podman ps -a' manually."
fi

# Step 3: Run nvidia-smi with status and progress % appended, reformatted into two lines
echo "Starting nvidia-smi with progress..."
(while true; do 
    # Gather NVIDIA data
    NVIDIA_DATA=$(nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,power.draw,power.limit,pstate,temperature.gpu,fan.speed,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks.current.graphics,clocks.max.graphics --format=csv,noheader,nounits)
    # Gather CPU and RAM data
    CPU_UTIL=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)
    RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
    RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    # Get latest status and progress % from logs
    if [ -f "$OUTPUT_FILE.logs" ] && [ -s "$OUTPUT_FILE.logs" ]; then
        # Extract progress percentage with broader pattern matching
        PROGRESS_PCT=$(tail -n 100 "$OUTPUT_FILE.logs" | grep -oP '"progress":"[0-9]+\.[0-9]+%"' | tail -n 1 | cut -d'"' -f4)
        if [ -z "$PROGRESS_PCT" ]; then
            # Broader search for any percentage (e.g., "8.3%", "10.5%")
            PROGRESS_PCT=$(tail -n 100 "$OUTPUT_FILE.logs" | grep -oP '[0-9]+\.[0-9]+%' | tail -n 1)
            PROGRESS_PCT=${PROGRESS_PCT:-"N/A"}
        fi
        # Extract last meaningful status line, excluding progress lines
        STATUS=$(tail -n 100 "$OUTPUT_FILE.logs" | grep -v "^$" | grep -v "progress" | tail -n 1)
        STATUS=${STATUS:-"N/A"}
        # Truncate long status messages
        if [ ${#STATUS} -gt 40 ]; then
            STATUS="${STATUS:0:37}..."
        fi
        # Combine status and percentage
        if [ "$PROGRESS_PCT" = "N/A" ]; then
            PROGRESS="$STATUS"
            # Check for failure reason if no progress after significant time
            if grep -q "Error: GPU is unfit for benchmarking" "$OUTPUT_FILE.logs"; then
                PROGRESS="Failed: Insufficient VRAM"
            fi
        else
            PROGRESS="$STATUS ($PROGRESS_PCT)"
        fi
    else
        PROGRESS="Waiting for logs..."
        echo "Debug: $OUTPUT_FILE.logs is missing or empty."
    fi
    
    # Format output into two lines, using ANSI escape codes for color (fallback to plain text if TERM is dumb)
    if [ "$TERM" != "dumb" ] && tput setaf 2 >/dev/null 2>&1 && tput sgr0 >/dev/null 2>&1; then
        COLOR_START="\033[32m"  # Green
        COLOR_END="\033[0m"     # Reset
    else
        COLOR_START=""
        COLOR_END=""
    fi
    echo "$NVIDIA_DATA" | awk -F', ' -v cpu="$CPU_UTIL" -v ram_used="$RAM_USED" -v ram_total="$RAM_TOTAL" -v prog="$PROGRESS" -v cstart="$COLOR_START" -v cend="$COLOR_END" '{
        vram_percent = ($3 / $4) * 100
        hw_throttle = ($11 == "Active") ? "Active" : "Not Active"
        sw_throttle = ($12 == "Active") ? "Active" : "Not Active"
        printf "%s[id:%s    %s   vRAM: %4d / %5d (%.2f%%)   GPU_util: %3s%%   Power: %3.0f / %3.0f W   perf_state: %s\n", cstart, $1, $2, $3, $4, vram_percent, $5, $6, $7, $8
        printf "GPUtemp: %3s°C   Fan: %3s%%   HW-throttle: %-10s   SW-throttle: %-10s] -- CPU_util: %2s%%   RAM: %5s / %5sMiB\nMAXTarget: 84°C   GPU T.Limit Temp 83°C   Current Clock %4s / %4s MHz   Progress: %s%s\n\n", $9, $10, hw_throttle, sw_throttle, cpu, ram_used, ram_total, $13, $14, prog, cend
    }'
    sleep 5
done) &
NVIDIA_PID=$!

# Wait for all background processes to complete
wait $NOSANA_PID $NVIDIA_PID $LOGS_PID
