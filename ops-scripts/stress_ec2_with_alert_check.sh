#!/bin/bash

##################################################################################
# Script Name: stress_ec2_with_alert_check.sh
# Description: This script performs a stress test on EC2 instances by simulating 
#              high CPU, then checks for CloudWatch CPU utilization 
#              alarms triggered by the stress test. The script can stress multiple 
#              instances in parallel and is capable of checking CloudWatch alarms 
#              associated with those instances after a specified wait time.
# 
# The script performs the following:
# 1. Fetches a list of EC2 instances that are in the 'running' state.
# 2. Executes stress tests to simulate high CPU utilization (above 80%) on the instances.
# 3. Waits for 5 minutes to allow alarms to trigger.
# 4. Checks for CloudWatch alarms triggered by CPU utilization surpassing 80%.
#
# Author: Hitesh Bhati
# Version: 2.7
# Date Created: 2025-01-17 
# Last Modified: 2025-01-28
# Contact: hitesh.bhati@napses.com
#
##################################################################################

# Help function
help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Perform a stress test on EC2 instances and check for CloudWatch CPU utilization alarms."
    echo
    echo "Mandatory Arguments:"
    echo "  AWS_PROFILE          AWS CLI profile to use (default: 'default')."
    echo "  AWS_REGION           AWS region where instances are located (default: 'ap-southeast-1')."
    echo
    echo "Optional Arguments:"
    echo "  -a, --alarm-name     CloudWatch alarm name to check (default: 'UI-EC2-CPU-Utilization-High')."
    echo "  -p, --parallel       Stress all instances in parallel (default: 'no')."
    echo "  -h, --help           Show this help message and exit."
    echo
    echo "Examples:"
    echo "  $0 my-aws-profile ap-southeast-1"
    echo "  $0 my-aws-profile ap-southeast-1 -a MyAlarmName -p yes"
    echo
    exit 0
}

# Default values
AWS_PROFILE=""
AWS_REGION=""
ALARM_NAME="UI-EC2-CPU-Utilization-High"
STRESS_ALL_PARALLEL="no"
IDENTITY_PATH="/home/hitesh/napses/deon/scripts/config/deon.pem"  # SSH key path
REMOTE_USER="ubuntu"  # Remote SSH user for EC2 (Ubuntu default)

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            help
            ;;
        -a|--alarm-name)
            ALARM_NAME="$2"
            shift 2
            ;;
        -p|--parallel)
            STRESS_ALL_PARALLEL="$2"
            shift 2
            ;;
        *)
            if [[ -z "$AWS_PROFILE" ]]; then
                AWS_PROFILE="$1"
            elif [[ -z "$AWS_REGION" ]]; then
                AWS_REGION="$1"
            else
                echo "Error: Unknown argument '$1'."
                help
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate mandatory arguments
if [[ -z "$AWS_PROFILE" || -z "$AWS_REGION" ]]; then
    echo "Error: AWS_PROFILE and AWS_REGION are mandatory arguments."
    help
    exit 1
fi

# Variables
INSTANCE_IDS=""  # Will store fetched instance IDs
STRESSED_INSTANCE_IDS=""  # Will store instances that were stressed
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")  # Start time for CloudWatch metrics
REPORT_FILE="stress_test_report_$(date +'%Y%m%d_%H%M%S').log"  # Report file

# Logging function
log() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" | tee -a "$REPORT_FILE"
}

# Function to fetch instance IDs
fetch_instance_ids() {
    log "Fetching instance IDs in region: $AWS_REGION"
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].InstanceId" \
        --output text)

    if [ -z "$INSTANCE_IDS" ]; then
        log "Error: No running instances found."
        exit 1
    fi
    log "Fetched instance IDs: $INSTANCE_IDS"
}

# Function to validate the instance ID
validate_instance_id() {
    local instance_id="$1"
    log "Validating instance ID: $instance_id"
    aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" &> /dev/null

    if [ $? -ne 0 ]; then
        log "Error: Instance ID $instance_id is invalid or does not exist."
        return 1
    fi
    log "Instance ID $instance_id is valid."
}

# Function to fetch CloudWatch alarms associated with an EC2 instance
get_alarms_for_instance() {
    local instance_id="$1"
    log "Fetching CloudWatch alarms associated with instance: $instance_id"
    ALARMS=$(aws cloudwatch describe-alarms \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "MetricAlarms[?Dimensions[?Name=='InstanceId' && Value=='$instance_id']].AlarmName" \
        --output text)

    if [ -z "$ALARMS" ]; then
        log "No alarms found for instance: $instance_id."
    else
        log "Found alarms: $ALARMS"
    fi
}

# Function to check if an alarm was triggered
get_alarm_triggered_history() {
    local alarm_name="$1"
    local instance_id="$2"
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "Checking CloudWatch alarm history for alarm: $alarm_name on instance: $instance_id"
    latest_timestamp=$(aws cloudwatch describe-alarm-history \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --alarm-name "$alarm_name" \
        --start-date "$START_TIME" \
        --end-date "$end_time" \
        --history-item-type "StateUpdate" \
        --query "AlarmHistoryItems[?HistorySummary=='Alarm updated from OK to ALARM'] | [0].Timestamp" \
        --output text)

    if [[ "$latest_timestamp" != "None" && "$latest_timestamp" > "$START_TIME" ]]; then
        log "Alarm triggered for instance $instance_id at $latest_timestamp."
    else
        log "No matching alarm history found for instance $instance_id."
    fi
}

# Function to run the stress test on an EC2 instance
run_stress_test() {
    local instance_id="$1"
    log "Starting stress test on instance: $instance_id"

    ssh -i "$IDENTITY_PATH" "$REMOTE_USER@$instance_id" \
        -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id $instance_id --profile $AWS_PROFILE --region $AWS_REGION" \
        -t << 'EOF'
        # Install dependencies if not present
        if ! command -v stress-ng &> /dev/null; then
            echo "Installing stress-ng..."
            sudo apt-get update -y || { echo "Failed to update package list"; exit 1; }
            sudo apt-get install -y stress-ng || { echo "Failed to install stress-ng"; exit 1; }
        fi

        # Run stress-ng commands to simulate CPU load above 80% for a sustained period
        echo "Simulating high CPU load (over 80%)..."
        
        # Increase the number of CPU stressors and use more intensive methods
        sudo stress-ng --cpu 16 --cpu-method fft --timeout 300s --metrics-brief || { echo "Failed to run stress-ng"; exit 1; }
        
        # Ensure a sustained CPU load for 5 minutes or more
        sudo stress-ng --cpu 16 --cpu-method matrixprod --timeout 300s --metrics-brief || { echo "Failed to run stress-ng"; exit 1; }

EOF

    if [ $? -ne 0 ]; then
        log "Error: Stress test failed on instance $instance_id."
        return 1
    fi
    log "Stress test completed on instance $instance_id."
    STRESSED_INSTANCE_IDS="$STRESSED_INSTANCE_IDS $instance_id"  # Add to stressed instances list
}


# Main function
main() {
    log "Starting script execution."
    fetch_instance_ids

    if [[ "$STRESS_ALL_PARALLEL" == "yes" ]]; then
        log "Stressing all instances in parallel."
        for INSTANCE_ID in $INSTANCE_IDS; do
            if validate_instance_id "$INSTANCE_ID"; then
                run_stress_test "$INSTANCE_ID" &
            fi
        done
        # Wait for all background processes to complete
        wait
    else
        log "Stressing only one instance."
        INSTANCE_ID=$(echo "$INSTANCE_IDS" | head -n 1)  # Take the first instance from the list
        if validate_instance_id "$INSTANCE_ID"; then
            run_stress_test "$INSTANCE_ID"
        fi
    fi

    log "Stress tests completed. Checking CloudWatch alarms..."
    
    # Check alarms for all stressed instances
    for INSTANCE_ID in $STRESSED_INSTANCE_IDS; do
        log "Checking alarms for instance: $INSTANCE_ID"
        get_alarms_for_instance "$INSTANCE_ID"

        if [ -n "$ALARMS" ]; then
            for ALARM_NAME in $ALARMS; do
                sleep 5m
                get_alarm_triggered_history "$ALARM_NAME" "$INSTANCE_ID"
            done
        fi
    done

    log "Script execution completed. Report saved to $REPORT_FILE."
}

# Execute the main function
main
