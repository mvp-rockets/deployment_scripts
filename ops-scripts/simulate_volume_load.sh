#!/bin/bash

##################################################################################
# Script Name: simulate_volume_load.sh
# Description: This script connects to EC2 instances in a specified AWS region, 
#              simulates a disk load by creating a temporary file to fill up 
#              the disk to 93% capacity, and then monitors the disk usage before 
#              and after the operation. The simulation can be executed on one or 
#              all instances in parallel.
#
# Arguments:
# - --aws-profile: AWS CLI profile to use for accessing AWS resources (required).
# - --region: AWS region where the EC2 instances are located (required).
# - --parallel: Optionally, run the disk load simulation on all instances in parallel.
#
# Author: [Your Name/Your Company]
# Version: 1.0
# Date Created: [Date]
# Last Modified: [Date]
# Contact: [Your Contact Information]
#
# Usage Example:
#   ./simulate_volume_load.sh --aws-profile 474888828713_AdministratorAccess --region ap-southeast-1
#
# License: [Your License Information, e.g., MIT License]
##################################################################################

# Help function
help() {
    echo "Usage: $0 --aws-profile <AWS_PROFILE> --region <AWS_REGION> [--parallel]"
    echo "This script simulates a disk load on EC2 instances by creating a temporary file to simulate load."
    echo "You can run the simulation on one instance or all instances in parallel."
    echo
    echo "Mandatory Arguments:"
    echo "  --aws-profile   AWS CLI profile to use."
    echo "  --region        AWS region where the EC2 instances are located."
    echo
    echo "Optional Arguments:"
    echo "  --parallel      Run the disk load simulation on all instances in parallel."
    echo
    echo "Example:"
    echo "  $0 --aws-profile 474888828713_AdministratorAccess --region ap-southeast-1"
    echo "  $0 --aws-profile 474888828713_AdministratorAccess --region ap-southeast-1 --parallel"
    echo
    exit 0
}

# Function to log messages with timestamp (to both console and log file)
log() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Function to log errors in red color (to both console and log file)
log_error() {
    local message="$1"
    echo -e "\e[31m[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $message\e[0m"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $message" >> "$LOG_FILE"
}

# Function to fetch all EC2 instance IDs in the specified region
fetch_instance_ids() {
    local aws_profile="$1"
    local aws_region="$2"
    instance_ids=$(aws ec2 describe-instances \
        --profile "$aws_profile" \
        --region "$aws_region" \
        --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].InstanceId" \
        --output text)

    echo "$instance_ids"
}

# Validate and parse command-line arguments
if [[ $# -eq 0 ]]; then
    help
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --aws-profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL=true
            shift
            ;;
        --help)
            help
            ;;
        *)
            log_error "Unknown argument: $1"
            help
            exit 1
            ;;
    esac
done

# Validate mandatory arguments
if [[ -z "$AWS_PROFILE" || -z "$AWS_REGION" ]]; then
    log_error "Both --aws-profile and --region are mandatory arguments."
    help
    exit 1
fi

# Default variables
IDENTITY_PATH="/home/hitesh/napses/deon/scripts/config/deon.pem"  # SSH key path
REMOTE_USER="ubuntu"  # Remote SSH user for EC2 (Ubuntu default)
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")  # Start time for CloudWatch metrics (optional for alarm checking)
LOG_FILE="volume_simulation.log"  # Log file name

# Initialize the log file
echo "Script execution started at $(date)" > "$LOG_FILE"

# Fetch the EC2 instances
log "Fetching EC2 instances in region: $AWS_REGION"
INSTANCE_IDS=$(fetch_instance_ids "$AWS_PROFILE" "$AWS_REGION")

if [[ -z "$INSTANCE_IDS" ]]; then
    log_error "No running EC2 instances found in region $AWS_REGION."
    exit 1
fi

log "Found EC2 instances: $INSTANCE_IDS"

# Function to simulate the disk load on an individual instance
simulate_disk_load() {
    local instance_id="$1"

    log "Connecting to instance $instance_id and starting disk load simulation..."

    ssh -i "$IDENTITY_PATH" "$REMOTE_USER@$instance_id" \
        -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id $instance_id --profile $AWS_PROFILE --region $AWS_REGION" << 'EOF'

    # Decorative Header
    echo "=============================================================="
    echo "Starting disk load simulation on EC2 instance..."
    echo "=============================================================="

    # Step 1: Show current disk usage in human-readable format
    echo "Step 1: Checking current disk usage..."
    df -h /
    echo "=============================================================="

    # Step 2: Execute df command and store total and available space into variables
    df_output=$(df /)  # Get the disk usage for the root volume
    total_space=$(echo "$df_output" | awk 'NR==2 {print $2}')  # Total space in 1K blocks
    available_space=$(echo "$df_output" | awk 'NR==2 {print $4}')  # Available space in 1K blocks

    # Convert from 1K blocks to bytes for easier calculations
    total_space_bytes=$((total_space * 1024))  # Total space in bytes
    available_space_bytes=$((available_space * 1024))  # Available space in bytes

    # Step 3: Calculate the desired output file size to bring volume usage to 93%
    desired_file_size_bytes=$((available_space_bytes * 93 / 100))

    # Make sure we don’t exceed 90% of total space
    max_file_size_bytes=$((total_space_bytes * 90 / 100))

    # Use the minimum of the calculated size and the 90% of total space
    if [ $desired_file_size_bytes -gt $max_file_size_bytes ]; then
        desired_file_size_bytes=$max_file_size_bytes
    fi

    # Convert the file size back to MB for the dd command (1MB = 1024*1024 bytes)
    desired_file_size_mb=$((desired_file_size_bytes / 1024 / 1024))

    # Step 4: Show the calculation result
    echo "Step 4: Calculating the size of the temporary file..."
    echo "Desired file size to bring disk usage to 93%: ${desired_file_size_mb}MB"
    echo "=============================================================="

    # Step 5: Execute dd command to create the file of the desired size
    echo "Step 5: Creating a temporary file with the calculated size..."
    dd if=/dev/zero of=/tmp/tempfile bs=1M count=$desired_file_size_mb status=progress
    echo "Temporary file created. Size: ${desired_file_size_mb}MB"
    echo "=============================================================="

    # Step 6: Show disk usage again after the temporary file is created
    echo "Step 6: Checking disk usage after creating the temporary file..."
    df -h /
    echo "=============================================================="

    # Step 7: Remove the temporary file to free up space
    echo "Step 7: Removing the temporary file to free up space..."
    rm /tmp/tempfile
    echo "Temporary file removed."
    echo "=============================================================="

    # Step 8: Show disk usage again after the temporary file is removed
    echo "Step 8: Checking disk usage after removing the temporary file..."
    df -h /
    echo "=============================================================="

    echo "Disk load simulation complete."

EOF
}

# Run the disk load simulation
if [[ "$PARALLEL" == true ]]; then
    log "Running the disk load simulation on all instances in parallel..."
    for INSTANCE_ID in $INSTANCE_IDS; do
        simulate_disk_load "$INSTANCE_ID" &
    done
    wait  # Wait for all background jobs to finish
else
    log "Running the disk load simulation on a single instance ($INSTANCE_ID)..."
    # Default to the first instance if running sequentially
    FIRST_INSTANCE_ID=$(echo "$INSTANCE_IDS" | head -n 1)
    simulate_disk_load "$FIRST_INSTANCE_ID"
fi

log "Script execution completed at $(date)."
