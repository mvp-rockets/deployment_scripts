#!/bin/bash

##################################################################################
# Script Name: trigger_and_verify_cloudwatch_alarms.sh
# Description: This script manually triggers CloudWatch alarms associated with 
#              running EC2 instances in a specific region, and verifies whether 
#              the alarms were triggered successfully.
# 
# The script performs the following steps:
# 1. Fetches a list of running EC2 instances in the specified region.
# 2. Retrieves the CloudWatch alarms associated with each EC2 instance.
# 3. Manually triggers each alarm by setting the state to 'ALARM'.
# 4. Verifies if the alarm was triggered by checking CloudWatch alarm history.
# 5. Logs all actions and results to a log file for reference.
#
# Author: Hitesh Bhati
# Version: 1.2
# Date Created: 2025-01-12
# Last Modified: 2025-01-28
# Contact: hitesh.bhati@napses.com

# Help function
help() {
    echo "Usage: $0 --aws-profile <AWS_PROFILE> --region <AWS_REGION>"
    echo "Manually trigger CloudWatch alarms associated with running EC2 instances and verify their triggering."
    echo
    echo "Mandatory Arguments:"
    echo "  --aws-profile   AWS CLI profile to use."
    echo "  --region        AWS region where instances are located."
    echo
    echo "Example:"
    echo "  $0 --aws-profile 474888828713_AdministratorAccess --region ap-southeast-1"
    echo
    exit 0
}

# Function to log messages with timestamp
log() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" | tee -a "$LOG_FILE"
}

# Function to log errors in red color
log_error() {
    local message="$1"
    echo -e "\e[31m[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $message\e[0m" | tee -a "$LOG_FILE"
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

# Log file
LOG_FILE="cloudwatch_alarm_trigger_$(date +'%Y%m%d_%H%M%S').log"
touch "$LOG_FILE"

# Script start time
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log "Script start time: $START_TIME"

# Get all running instances
log "Fetching running instances in region: $AWS_REGION"
INSTANCE_IDS=$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

if [[ -z "$INSTANCE_IDS" ]]; then
    log_error "No running instances found."
    exit 1
fi
log "Found running instances: $INSTANCE_IDS"

# Iterate through each instance and trigger associated alarms
for INSTANCE_ID in $INSTANCE_IDS; do
    log "Processing instance: $INSTANCE_ID"

    # Get associated alarms for the instance
    ALARM_NAMES=$(aws cloudwatch describe-alarms \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "MetricAlarms[?Dimensions[?Name=='InstanceId' && Value=='$INSTANCE_ID']].AlarmName" \
        --output text)

    if [[ -z "$ALARM_NAMES" ]]; then
        log "No CloudWatch alarms found for instance: $INSTANCE_ID"
        continue
    fi

    log "Found alarms for instance $INSTANCE_ID: $ALARM_NAMES"

    # Trigger each alarm
    for ALARM_NAME in $ALARM_NAMES; do
        log "Triggering alarm: $ALARM_NAME"
        aws cloudwatch set-alarm-state \
            --alarm-name "$ALARM_NAME" \
            --state-value ALARM \
            --state-reason "Manually setting alarm state for testing" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION"

        if [[ $? -ne 0 ]]; then
            log_error "Failed to trigger alarm: $ALARM_NAME"
            continue
        fi

        log "Successfully triggered alarm: $ALARM_NAME"

        # Verify if the alarm was triggered
        END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        log "Verifying alarm triggering for: $ALARM_NAME"
        LAST_TRIGGERED_TIME=$(aws cloudwatch describe-alarm-history \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --alarm-name "$ALARM_NAME" \
            --start-date "$START_TIME" \
            --end-date "$END_TIME" \
            --history-item-type "StateUpdate" \
            --query "AlarmHistoryItems[?HistorySummary=='Alarm updated from OK to ALARM'] | [0].Timestamp" \
            --output text)

        if [[ -z "$LAST_TRIGGERED_TIME" ]]; then
            log_error "Alarm $ALARM_NAME was not triggered."
        else
            log "Alarm $ALARM_NAME was last triggered at: $LAST_TRIGGERED_TIME"
            if [[ "$LAST_TRIGGERED_TIME" > "$START_TIME" ]]; then
                log "Verification successful: Alarm $ALARM_NAME was triggered after the script started."
            else
                log_error "Verification failed: Alarm $ALARM_NAME was not triggered after the script started."
            fi
        fi
    done
done

log "Script execution completed. Logs saved to: $LOG_FILE"